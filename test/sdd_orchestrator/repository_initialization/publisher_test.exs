defmodule SddOrchestrator.RepositoryInitialization.PublisherTest do
  @moduledoc """
  Task 5 proof (tasks.md's own proof line): "Focused target-race, new-commit,
  symlink, permission, check failure, tree mismatch, Git hook negative,
  root-commit uniqueness, replay, publication failure, user-data
  preservation, evidence, and browser tests pass."

  Like `StagingBuilderTest` (Task 4), `Publisher` never routes through
  `Delivery.AgentAdapter` — everything below exercises real temp-directory
  filesystem and real `git` behavior. `target_path` is always a plain
  function argument here, matching `Publisher`'s own moduledoc: no live
  caller resolves it from `Plan.target_reference` yet.
  """
  # `async: false`: this module and `StagingBuilderTest` both mutate the same
  # global `Application.put_env(:sdd_orchestrator, :initialization_staging_root,
  # ...)` key in `setup`/`on_exit`, which races when either runs concurrently
  # with the other (or with itself) under ExUnit's async scheduler.
  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.{Publisher, Result, Run, StagingBuilder}
  alias SddOrchestrator.RepositoryInitialization.StagingWorkspace

  setup do
    base = Path.join(System.tmp_dir!(), "sdd-publish-#{System.unique_integer([:positive])}")
    root = Path.join(base, "staging-root")
    target = Path.join(base, "target")
    File.mkdir_p!(root)
    File.mkdir_p!(target)

    previous = Application.fetch_env(:sdd_orchestrator, :initialization_staging_root)
    Application.put_env(:sdd_orchestrator, :initialization_staging_root, root)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:sdd_orchestrator, :initialization_staging_root, value)

        :error ->
          Application.delete_env(:sdd_orchestrator, :initialization_staging_root)
      end

      restore_permissions(target)
      File.rm_rf!(base)
    end)

    %{target: target}
  end

  describe "target-race" do
    test "refuses when the target becomes non-empty and leaves the stray file untouched", %{
      target: target
    } do
      run = build_completed_run()
      plan = fetch_plan(run)

      stray = Path.join(target, "do-not-delete.txt")
      File.write!(stray, "user data")

      assert {:error, :non_empty_directory, failed} = Publisher.publish(run, plan, target)
      assert failed.state == "failed"
      assert failed.failure_reason == "non_empty_directory"

      # User-data preservation: the stray file is never touched or removed.
      assert File.read!(stray) == "user data"
      assert File.ls!(target) == ["do-not-delete.txt"]
      assert Repo.get_by(Result, run_id: run.id) == nil
    end
  end

  describe "new-commit" do
    test "refuses when the target gained a commit since eligibility was recorded", %{
      target: target
    } do
      run = build_completed_run()
      plan = fetch_plan(run)

      git!(target, ["init", "--quiet", "."])
      File.write!(Path.join(target, "a.txt"), "a")
      git!(target, ["add", "-A"])
      git!(target, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "x"])

      assert {:error, :mature_repository, failed} = Publisher.publish(run, plan, target)
      assert failed.failure_reason == "mature_repository"
      assert Repo.get_by(Result, run_id: run.id) == nil
    end

    test "refuses when the target's eligibility identity changed (still eligible, but not the same kind)",
         %{target: target} do
      run = build_completed_run()
      plan = fetch_plan(run)
      assert plan.eligibility == "empty_directory"

      git!(target, ["init", "--quiet", "."])

      assert {:error, :target_changed, failed} = Publisher.publish(run, plan, target)
      assert failed.failure_reason == "target_changed"
    end
  end

  describe "symlink" do
    test "refuses when the target path itself has become a symlink", %{target: target} do
      run = build_completed_run()
      plan = fetch_plan(run)

      real_dir = target <> "-real"
      File.rename!(target, real_dir)
      File.ln_s!(real_dir, target)

      assert {:error, :target_symlinked, failed} = Publisher.publish(run, plan, target)
      assert failed.failure_reason == "target_symlinked"
    after
      File.rm(target)
    end
  end

  describe "permission" do
    test "refuses when the target left its writable permission boundary", %{target: target} do
      run = build_completed_run()
      plan = fetch_plan(run)

      File.chmod!(target, 0o555)

      assert {:error, :target_permission_changed, failed} = Publisher.publish(run, plan, target)
      assert failed.failure_reason == "target_permission_changed"
    end
  end

  describe "check failure (trivial satisfaction)" do
    test "records empty check evidence as passed since no checks are configured today", %{
      target: target
    } do
      run = build_completed_run()
      plan = fetch_plan(run)

      assert {:ok, %Result{check_evidence: []}} = Publisher.publish(run, plan, target)

      updated_run = Repo.get!(Run, run.id)
      evidence = Enum.find(updated_run.progress, &(&1["type"] == "evidence"))
      assert evidence["payload"] == %{"step" => "checks_passed", "checks" => []}
    end
  end

  describe "tree mismatch" do
    test "binds tree_digest to the exact git tree of the created commit", %{target: target} do
      run = build_completed_run()
      plan = fetch_plan(run)

      assert {:ok, result} = Publisher.publish(run, plan, target)

      expected_tree = git!(target, ["rev-parse", "HEAD^{tree}"]) |> String.trim()
      assert result.tree_digest == expected_tree
    end

    test "a declined-kit build and an included-kit build produce different trees", %{
      target: target
    } do
      publish_package_fixture()

      declined_run = build_completed_run(kit_choice: "declined")
      included_run = build_completed_run(kit_choice: "included")

      declined_target = target <> "-declined"
      included_target = target <> "-included"
      File.mkdir_p!(declined_target)
      File.mkdir_p!(included_target)

      assert {:ok, declined_result} =
               Publisher.publish(declined_run, fetch_plan(declined_run), declined_target)

      assert {:ok, included_result} =
               Publisher.publish(included_run, fetch_plan(included_run), included_target)

      refute declined_result.tree_digest == included_result.tree_digest
    end
  end

  describe "Git hook negative" do
    test "a hook placed in the disabled hooks directory never runs during commit", %{
      target: target
    } do
      run = build_completed_run()
      plan = fetch_plan(run)

      {:ok, staging} = StagingWorkspace.staging_path(run)
      marker = Path.join(staging, "hook-ran.txt")
      hooks_dir = Path.join([staging, ".git", "hooks-disabled"])
      File.mkdir_p!(hooks_dir)

      hook_path = Path.join(hooks_dir, "pre-commit")
      File.write!(hook_path, "#!/bin/sh\necho ran > #{marker}\n")
      File.chmod!(hook_path, 0o755)

      assert {:ok, _result} = Publisher.publish(run, plan, target)
      refute File.exists?(marker)
    end
  end

  describe "root-commit uniqueness" do
    test "calling publish twice never creates a second root commit", %{target: target} do
      run = build_completed_run()
      plan = fetch_plan(run)

      assert {:ok, first} = Publisher.publish(run, plan, target)
      assert {:ok, second} = Publisher.publish(run, plan, target)

      assert first.id == second.id
      assert first.commit_sha == second.commit_sha

      roots =
        target
        |> git!(["rev-list", "--max-parents=0", "HEAD"])
        |> String.split("\n", trim: true)

      assert length(roots) == 1
    end

    test "reuses an already-existing staging commit instead of creating another one", %{
      target: target
    } do
      run = build_completed_run()
      plan = fetch_plan(run)

      {:ok, staging} = StagingWorkspace.staging_path(run)
      git!(staging, ["add", "-A"])
      git!(staging, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "x"])
      pre_existing_sha = git!(staging, ["rev-parse", "HEAD"]) |> String.trim()

      assert {:ok, result} = Publisher.publish(run, plan, target)
      assert result.commit_sha == pre_existing_sha
    end
  end

  describe "replay" do
    test "a repeat call returns the same result without touching staging or target again", %{
      target: target
    } do
      run = build_completed_run()
      plan = fetch_plan(run)

      assert {:ok, first} = Publisher.publish(run, plan, target)
      refute File.dir?(elem(StagingWorkspace.staging_path(run), 1))

      assert {:ok, second} = Publisher.publish(run, plan, target)
      assert first.id == second.id
    end
  end

  describe "publication failure" do
    test "a transfer failure marks the run failed, rolls back partial content, and leaves no result",
         %{target: target} do
      run = build_completed_run()
      plan = fetch_plan(run)

      {:ok, staging} = StagingWorkspace.staging_path(run)
      git!(staging, ["add", "-A"])
      git!(staging, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "x"])

      readme = Path.join(staging, "README.md")
      File.chmod!(readme, 0o000)

      on_exit(fn -> File.chmod(readme, 0o644) end)

      assert {:error, :publish_failed, failed} = Publisher.publish(run, plan, target)
      assert failed.state == "failed"
      assert failed.failure_reason == "publish_failed"

      assert File.ls!(target) == []
      assert Repo.get_by(Result, run_id: run.id) == nil
      # Staging is left in place (already committed) so a retry can resume.
      assert File.dir?(staging)
    end
  end

  describe "run not ready" do
    test "refuses a run whose staging directory no longer exists", %{target: target} do
      run = build_completed_run()
      plan = fetch_plan(run)

      {:ok, staging} = StagingWorkspace.staging_path(run)
      File.rm_rf!(staging)

      assert {:error, :run_not_ready, ^run} = Publisher.publish(run, plan, target)
    end
  end

  ## Fixtures and helpers

  defp build_completed_run(opts \\ []) do
    kit_choice = Keyword.get(opts, :kit_choice, "declined")
    plan = confirmed_plan_fixture(kit_choice: kit_choice)

    assert {:ok, run} =
             StagingBuilder.start_run(
               plan,
               Ecto.UUID.generate(),
               ["staging_write"],
               idempotency_key()
             )

    assert run.state == "completed"
    run
  end

  defp fetch_plan(run) do
    {:ok, plan} = RepositoryInitialization.get_plan(run.plan_id)
    plan
  end

  defp idempotency_key, do: WorkerProtocol.generate_id()

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    output
  end

  defp restore_permissions(target), do: File.chmod(target, 0o755)

  defp confirmed_plan_fixture(opts) do
    kit_choice = Keyword.get(opts, :kit_choice, "declined")

    plan = ready_plan_fixture()
    {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, kit_choice)
    {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
    {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)
    {:ok, plan} = RepositoryInitialization.confirm_plan(plan, snapshot)
    plan
  end

  # Duplicated from `StagingBuilderTest`'s own private helper of the same
  # shape (Task 4's own proof file, not this task's to modify) rather than
  # sharing it across test files, matching that file's own precedent.
  defp ready_plan_fixture do
    {:ok, plan} =
      RepositoryInitialization.create_plan(%{
        device_workspace_id: Ecto.UUID.generate(),
        target_reference: WorkerProtocol.generate_id(),
        eligibility: "empty_directory"
      })

    {:ok, plan} = RepositoryInitialization.answer_field(plan, "purpose", "A CLI tool")
    {:ok, plan} = RepositoryInitialization.answer_field(plan, "users", "Founders")
    {:ok, plan} = RepositoryInitialization.answer_field(plan, "first_outcome", "First release")
    {:ok, plan} = RepositoryInitialization.answer_field(plan, "constraints", "None yet")

    {:ok, plan} =
      RepositoryInitialization.answer_field(plan, "technical_foundation", %{
        "language" => "elixir"
      })

    plan
  end
end
