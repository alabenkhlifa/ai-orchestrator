defmodule SddOrchestrator.RepositoryInitialization.HandoffTest do
  @moduledoc """
  Task 6 proof (AC-13): a completed handoff consumes the portable repository
  identity, creates the on-device project and its complete authoritative
  first specification revision (matching `SpecificationRenderer.render/1`),
  and updates `Result` to `onboarding_handoff_state == "completed"` exactly
  once. Replaying `Handoff.complete/4` on an already-completed result is a
  pure no-op (no second project, no second specification). A failure before
  any onboarding side effect (an unpublished target with no root commit)
  leaves `Result` unchanged at `"pending"` with no project or specification
  created — "no repository specification copy" / no partial success.

  Builds its fixture by running the real Task 4 -> Task 5 pipeline first
  (confirmed plan -> `StagingBuilder.start_run` -> `Publisher.publish`),
  copying `PublisherTest`'s own private helpers of the same shape (that
  file's own fixture, not this task's to modify) rather than sharing them
  across test files, matching that file's own precedent.

  Like `PublisherTest`/`StagingBuilderTest`, this mutates the global
  `Application.put_env(:sdd_orchestrator, :initialization_staging_root,
  ...)` key, so it stays `async: false`. The device store is also a
  singleton GenServer not started in test, so each test starts its own
  isolated instance on a unique path (mirrors `LocalOnboardingLiveTest`).
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.{Handoff, Publisher, SpecificationRenderer}
  alias SddOrchestrator.RepositoryInitialization.StagingBuilder
  alias SddOrchestrator.SpecificationStore

  setup do
    store_path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)
    start_supervised!({Local, path: store_path})
    {:ok, workspace} = Devices.establish_workspace()

    base = Path.join(System.tmp_dir!(), "sdd-handoff-#{System.unique_integer([:positive])}")
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

      File.rm_rf!(base)
    end)

    %{workspace: workspace, target: target}
  end

  describe "full success" do
    test "creates the device project and the complete first specification revision, and updates Result",
         %{workspace: workspace, target: target} do
      {result, plan} = build_published_result(workspace, target)

      assert {:ok, updated} = Handoff.complete(result, plan, workspace, target)

      assert updated.onboarding_handoff_state == "completed"
      assert is_binary(updated.project_id)
      assert updated.specification_id == result.id

      assert [project] = Devices.list_projects()
      assert project.id == updated.project_id
      assert project.storage_mode == "device"

      assert {:ok, %{specification: specification, revision: revision}} =
               SpecificationStore.get_current(workspace, project.id, updated.specification_id)

      assert specification.id == updated.specification_id

      expected = SpecificationRenderer.render(plan)
      assert revision.requirements_document == expected.requirements
      assert revision.design_document == expected.design
      assert revision.tasks_document == expected.tasks
    end
  end

  describe "idempotent replay" do
    test "never creates a second project or specification", %{
      workspace: workspace,
      target: target
    } do
      {result, plan} = build_published_result(workspace, target)

      assert {:ok, first} = Handoff.complete(result, plan, workspace, target)
      assert {:ok, second} = Handoff.complete(first, plan, workspace, target)

      assert second.project_id == first.project_id
      assert second.specification_id == first.specification_id
      assert length(Devices.list_projects()) == 1
    end
  end

  describe "failure partway" do
    test "a repository-identity failure leaves Result pending with no project or specification created",
         %{workspace: workspace, target: target} do
      {result, plan} = build_published_result(workspace, target)

      # A directory that was never published through `Publisher` has no root
      # commit yet, so the very first pipeline step (portable repository
      # identity) fails before any onboarding attempt, project, or
      # specification is ever created.
      unpublished = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(unpublished) end)

      assert {:error, :repository_identity_failed, unchanged} =
               Handoff.complete(result, plan, workspace, unpublished)

      assert unchanged.onboarding_handoff_state == "pending"
      assert unchanged.project_id == nil
      assert unchanged.specification_id == nil
      assert Devices.list_projects() == []
    end
  end

  # ---- fixtures ----

  defp build_published_result(workspace, target, opts \\ []) do
    run = build_completed_run(workspace, opts)
    plan = fetch_plan(run)
    assert {:ok, result} = Publisher.publish(run, plan, target)
    {result, plan}
  end

  defp build_completed_run(workspace, opts) do
    kit_choice = Keyword.get(opts, :kit_choice, "declined")
    plan = confirmed_plan_fixture(workspace, kit_choice: kit_choice)

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

  defp confirmed_plan_fixture(workspace, opts) do
    kit_choice = Keyword.get(opts, :kit_choice, "declined")

    plan = ready_plan_fixture(workspace)
    {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, kit_choice)
    {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
    {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)
    {:ok, plan} = RepositoryInitialization.confirm_plan(plan, snapshot)
    plan
  end

  # Duplicated from `PublisherTest`'s own private helper of the same shape
  # (Task 5's own proof file, not this task's to modify) rather than sharing
  # it across test files, matching that file's own precedent — with a real
  # workspace id, since this task's pipeline needs a real, established device
  # workspace (unlike Task 5's own arbitrary random-UUID workspace).
  defp ready_plan_fixture(workspace) do
    {:ok, plan} =
      RepositoryInitialization.create_plan(%{
        device_workspace_id: workspace.id,
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

  defp empty_dir_fixture do
    dir = Path.join(System.tmp_dir!(), "sdd_handoff_dir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_ri_handoff_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
