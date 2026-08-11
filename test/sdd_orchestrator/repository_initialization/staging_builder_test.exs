defmodule SddOrchestrator.RepositoryInitialization.StagingBuilderTest do
  @moduledoc """
  Task 4 proof (tasks.md's own proof line): "Focused plan-staleness, agent
  separation, capability denial, path escape, undeclared output, package
  tamper, no-network, no-hook, selected and declined kit, progress,
  cancellation, and mutation-negative tests pass."

  No `AgentAdapter` test double is used here (unlike Tasks 1-3): per
  `progress.md`'s "Task 4 preflight" entry, `StagingBuilder` never routes
  through `Delivery.AgentAdapter` or `InitializationDispatch.dispatch/2` —
  everything below exercises real temp-directory filesystem behavior, the
  same idiom `Delivery.Worker.Workspace`'s own tests already use.
  """
  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.{Plan, Run, StagingBuilder, StagingWorkspace}
  alias SddOrchestrator.RepositoryKits.RepositoryKitPackage

  setup do
    base = Path.join(System.tmp_dir!(), "sdd-staging-build-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    File.mkdir_p!(root)

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

    %{base: base, root: root}
  end

  describe "start_run/4 — plan readiness and staleness" do
    test "refuses a plan that hasn't reached ready" do
      plan = plan_fixture()

      assert {:error, :plan_not_ready} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())
    end

    test "refuses a ready plan that was never confirmed" do
      plan = ready_plan_fixture()

      assert {:error, :plan_not_confirmed} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())
    end

    test "refuses :plan_changed when a bound field changed outside the invalidation path" do
      plan = confirmed_plan_fixture()

      # `Plan`'s own changesets always clear `confirmed_at`/`confirmation_digest`
      # together with any bound-field change (`set_kit_choice/2`), and
      # `answer_field/3` refuses to touch a plan whose `current_field` is no
      # longer `technical_foundation` — so this stale state cannot be reached
      # honestly through the public API. It is constructed directly with
      # `Repo.update_all/2` to simulate a bound field changing without going
      # through that invalidation path, proving `start_run/4` re-derives
      # rather than trusts the stored `confirmation_digest`.
      from(p in Plan, where: p.id == ^plan.id)
      |> Repo.update_all(set: [technical_foundation: %{"language" => "rust"}])

      assert {:error, :plan_changed} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())
    end

    test "succeeds and completes with a genuinely confirmed, unchanged plan" do
      plan = confirmed_plan_fixture()

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert run.state == "completed"
      assert run.plan_id == plan.id
      assert run.finished_at != nil
    end
  end

  describe "start_run/4 — agent separation and capability denial" do
    test "a plan_discovery-only connection is refused :capability_grant_denied" do
      plan = confirmed_plan_fixture()

      assert {:error, :capability_grant_denied} =
               StagingBuilder.start_run(plan, worker_id(), ["plan_discovery"], idempotency_key())
    end

    test "a connection that negotiated neither grant is refused" do
      plan = confirmed_plan_fixture()

      assert {:error, :capability_grant_denied} =
               StagingBuilder.start_run(plan, worker_id(), [], idempotency_key())
    end

    test "a staging_write connection is authorized" do
      plan = confirmed_plan_fixture()

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert run.state == "completed"
    end
  end

  describe "start_run/4 — idempotency" do
    test "retrying with the same idempotency key returns the same run without a second build" do
      plan = confirmed_plan_fixture()
      key = idempotency_key()

      assert {:ok, first} = StagingBuilder.start_run(plan, worker_id(), ["staging_write"], key)
      assert {:ok, second} = StagingBuilder.start_run(plan, worker_id(), ["staging_write"], key)

      assert first.id == second.id
      assert Repo.aggregate(from(r in Run, where: r.idempotency_key == ^key), :count) == 1
    end
  end

  describe "kit choice — selected and declined" do
    test "included vendors the kit's declared files under the staging directory" do
      package = publish_package_fixture()
      plan = confirmed_plan_fixture(kit_choice: "included")

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert run.state == "completed"
      assert run.kit_choice == "included"
      assert run.kit_package_digest == package.digest

      assert list_staged_files(run) ==
               Enum.sort(["README.md", "SKILL.md", "scripts/check.sh", "templates/empty.md"])
    end

    test "declined produces only the skeleton README and Git metadata" do
      plan = confirmed_plan_fixture(kit_choice: "declined")

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert run.state == "completed"
      assert run.kit_choice == "declined"
      assert run.kit_package_digest == nil
      assert list_staged_files(run) == ["README.md"]

      {:ok, staging} = StagingWorkspace.staging_path(run)
      assert File.dir?(Path.join(staging, ".git"))
    end
  end

  describe "undeclared output" do
    test "the staged tree contains exactly the skeleton plus the kit's declared files" do
      publish_package_fixture()
      plan = confirmed_plan_fixture(kit_choice: "included")

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert list_staged_files(run) ==
               Enum.sort(["README.md", "SKILL.md", "scripts/check.sh", "templates/empty.md"])
    end
  end

  describe "kit vendoring — path escape" do
    test "refuses a kit file manifest entry with an escaping path and cleans up" do
      evil_content = "evil"

      files = [
        %{
          "path" => "../../etc/passwd",
          "content" => Base.encode64(evil_content),
          "sha256" => sha256_hex(evil_content),
          "size" => byte_size(evil_content),
          "executable" => false
        }
      ]

      malicious_kit_package_fixture(files)
      plan = confirmed_plan_fixture(kit_choice: "included")
      run = pending_run_fixture(plan)

      assert {:error, :kit_path_invalid, result} = StagingBuilder.build(run, plan)
      assert result.state == "failed"
      assert result.failure_reason == "kit_path_invalid"
      refute staging_dir_exists?(result)
    end
  end

  describe "kit vendoring — package tamper" do
    test "refuses a file whose recorded sha256 does not match its actual content" do
      real_content = "# skill\n"

      files = [
        %{
          "path" => "SKILL.md",
          "content" => Base.encode64(real_content),
          "sha256" => sha256_hex("not the real content"),
          "size" => byte_size(real_content),
          "executable" => false
        }
      ]

      malicious_kit_package_fixture(files)
      plan = confirmed_plan_fixture(kit_choice: "included")
      run = pending_run_fixture(plan)

      assert {:error, :kit_file_tampered, result} = StagingBuilder.build(run, plan)
      assert result.state == "failed"
      refute staging_dir_exists?(result)
    end

    test "refuses the whole run when the chosen package is no longer in the catalog" do
      publish_package_fixture()
      plan = confirmed_plan_fixture(kit_choice: "included")

      # The run row is created first, while the package still exists (as it
      # would in the real `start_run/4` flow — the row's own
      # `kit_package_id` is a foreign key). The package is then removed to
      # simulate it disappearing from the catalog in the window between run
      # creation and `build/2`'s own kit-vendoring step, which is exactly the
      # race `fetch_verified_package/1` re-checks against.
      run = pending_run_fixture(plan)
      Repo.delete_all(RepositoryKitPackage)

      assert {:error, :kit_package_unavailable, result} = StagingBuilder.build(run, plan)
      assert result.state == "failed"
      refute staging_dir_exists?(result)
    end
  end

  describe "no-network and no-hook (structural)" do
    test "the module never references an HTTP client" do
      source = File.read!(source_path())

      refute source =~ "Req."
      refute source =~ "Finch"
      refute source =~ "HTTPoison"
      refute source =~ ":httpc"
      refute source =~ ":gun"
    end

    test "every subprocess command issued is this module's own fixed git command" do
      source = File.read!(source_path())

      refute source =~ "Port.open"
      refute source =~ ":os.cmd"

      invocations = Regex.scan(~r/System\.cmd\(\s*"([^"]+)"/, source)
      assert invocations != []
      assert Enum.all?(invocations, fn [_match, executable] -> executable == "git" end)
    end

    test "a kit's executable script is vendored with its permission bit but never invoked" do
      publish_package_fixture()
      plan = confirmed_plan_fixture(kit_choice: "included")

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      {:ok, staging} = StagingWorkspace.staging_path(run)
      script = Path.join(staging, "scripts/check.sh")

      assert File.regular?(script)
      assert Bitwise.band(File.stat!(script).mode, 0o111) != 0
      assert File.read!(script) == "#!/bin/sh\necho ok\n"
    end
  end

  describe "progress" do
    test "accumulates ordered typed events as the build proceeds" do
      publish_package_fixture()
      plan = confirmed_plan_fixture(kit_choice: "included")

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert Enum.map(run.progress, & &1["type"]) == [
               "progress",
               "progress",
               "evidence",
               "progress"
             ]

      assert Enum.map(run.progress, & &1["payload"]["step"]) == [
               "staging_prepared",
               "skeleton_written",
               "kit_vendored",
               "git_initialized"
             ]

      assert Enum.all?(run.progress, &is_binary(&1["occurred_at"]))
    end

    test "accumulates only the skeleton and Git events when the kit is declined" do
      plan = confirmed_plan_fixture(kit_choice: "declined")

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert Enum.map(run.progress, & &1["payload"]["step"]) == [
               "staging_prepared",
               "skeleton_written",
               "git_initialized"
             ]
    end
  end

  describe "cancellation" do
    test "canceling a pending run stops the next build with no staging directory left behind" do
      plan = confirmed_plan_fixture(kit_choice: "declined")
      run = pending_run_fixture(plan)

      assert {:ok, canceled_request} = StagingBuilder.cancel_run(run)
      assert {:ok, result} = StagingBuilder.build(canceled_request, plan)

      assert result.state == "canceled"
      assert result.finished_at != nil
      refute staging_dir_exists?(result)
    end

    test "a cancellation requested between the two checkpoints stops before Git setup" do
      plan = confirmed_plan_fixture(kit_choice: "declined")
      run = pending_run_fixture(plan)

      assert {:ok, result} =
               StagingBuilder.build(run, plan,
                 after_kit_vendored: fn -> StagingBuilder.cancel_run(run) end
               )

      assert result.state == "canceled"
      refute staging_dir_exists?(result)

      # The skeleton step ran before cancellation was requested, but Git
      # setup never did — proving the checkpoint actually landed between the
      # two, not merely at the very start.
      steps = Enum.map(result.progress, & &1["payload"]["step"])
      assert "skeleton_written" in steps
      refute "git_initialized" in steps
    end

    test "a run still pending is unaffected until build runs" do
      plan = confirmed_plan_fixture(kit_choice: "declined")
      run = pending_run_fixture(plan)

      assert {:ok, canceled_request} = StagingBuilder.cancel_run(run)
      assert canceled_request.state == "pending"
      assert canceled_request.cancel_requested_at != nil
    end
  end

  describe "mutation-negative" do
    test "nothing is ever written outside the run's own staging directory" do
      publish_package_fixture()
      plan = confirmed_plan_fixture(kit_choice: "included")

      assert {:ok, run} =
               StagingBuilder.start_run(plan, worker_id(), ["staging_write"], idempotency_key())

      assert run.state == "completed"

      {:ok, root} = StagingWorkspace.root()
      assert File.ls!(root) == [run.id]
    end
  end

  ## Fixtures and helpers

  defp source_path do
    Path.join([
      File.cwd!(),
      "lib",
      "sdd_orchestrator",
      "repository_initialization",
      "staging_builder.ex"
    ])
  end

  defp worker_id, do: Ecto.UUID.generate()
  defp idempotency_key, do: WorkerProtocol.generate_id()

  defp sha256_hex(content),
    do: content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp staging_dir_exists?(run) do
    case StagingWorkspace.staging_path(run) do
      {:ok, path} -> File.exists?(path)
      {:error, _reason} -> false
    end
  end

  defp list_staged_files(run) do
    {:ok, staging} = StagingWorkspace.staging_path(run)

    [staging, "**", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, staging))
    |> Enum.sort()
  end

  # A run created directly through `Run.create_changeset/2` (the same public
  # surface `StagingBuilder`'s own `create_run/4` uses) without invoking
  # `build/3` — the seam Tasks with cancellation-before-start and
  # build-failure scenarios need to control exactly when `build/3` runs.
  defp pending_run_fixture(plan) do
    %Run{}
    |> Run.create_changeset(%{
      plan_id: plan.id,
      device_workspace_id: plan.device_workspace_id,
      worker_id: worker_id(),
      dispatch_id: WorkerProtocol.generate_id(),
      idempotency_key: idempotency_key(),
      state: "pending",
      kit_choice: plan.kit_choice,
      kit_package_id: plan.kit_package_id,
      kit_package_digest: plan.kit_package_digest
    })
    |> Repo.insert!()
  end

  # `RepositoryKits.publish_package/2` validates every file path at publish
  # time and would refuse an escaping or tampered manifest outright, so a
  # malicious manifest is inserted directly with `Ecto.Changeset.cast/3`
  # (bypassing that Elixir-level validation, not any database constraint) —
  # proving `StagingBuilder` itself re-validates rather than trusts the
  # catalog it reads from.
  defp malicious_kit_package_fixture(files) do
    manifest = %{"files" => files}

    attrs = %{
      id: Ecto.UUID.generate(),
      source: "https://github.com/example/malicious-kit",
      publisher: "example-org",
      version: "1.0.0",
      digest: RepositoryKitPackage.digest_of(manifest),
      license: "MIT",
      provenance: %{
        "ref_type" => "commit",
        "ref" => String.duplicate("a", 40),
        "repository" => "example/malicious-kit"
      },
      file_manifest: manifest,
      supported_adapters: ["claude_code"]
    }

    %RepositoryKitPackage{}
    |> Ecto.Changeset.cast(attrs, [
      :id,
      :source,
      :publisher,
      :version,
      :digest,
      :license,
      :provenance,
      :file_manifest,
      :supported_adapters
    ])
    |> Repo.insert!()
  end

  defp confirmed_plan_fixture(opts \\ []) do
    kit_choice = Keyword.get(opts, :kit_choice, "declined")

    plan = ready_plan_fixture()
    {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, kit_choice)
    {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
    {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)
    {:ok, plan} = RepositoryInitialization.confirm_plan(plan, plan.device_workspace_id, snapshot)
    plan
  end

  # Duplicated from `RepositoryInitializationTest`'s own private helper of
  # the same shape (Task 2/3's own proof file, not this task's to modify)
  # rather than sharing it across test files — a small, one-shot fixture
  # helper, not a refactor worth forcing across specs/16's task boundaries.
  defp ready_plan_fixture(attrs_overrides \\ %{}) do
    {:ok, plan} = RepositoryInitialization.create_plan(base_plan_attrs(attrs_overrides))

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

  defp plan_fixture(attrs_overrides \\ %{}) do
    {:ok, plan} = RepositoryInitialization.create_plan(base_plan_attrs(attrs_overrides))
    plan
  end

  defp base_plan_attrs(overrides) do
    Map.merge(
      %{
        device_workspace_id: Ecto.UUID.generate(),
        target_reference: WorkerProtocol.generate_id(),
        eligibility: "empty_directory"
      },
      overrides
    )
  end
end
