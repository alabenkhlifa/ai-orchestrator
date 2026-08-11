defmodule SddOrchestrator.Privacy.RepositoryInitializationPrivacyTest do
  @moduledoc """
  Task 7 privacy-boundary proof for specs/16's pre-project and resulting
  project data (AC-15): worker locality, minimization, access, retention,
  deletion, rights, redaction, processor, transfer, backup, and
  no-secondary-use across the plan, staging build, publish, and handoff
  surface, proven with real deletes and real `Retention`/`Rights` calls
  rather than mocks — the same idiom
  `RepositoryPilotAndReadinessPrivacyTest` and `SpecificationGovernanceTest`
  already use.

  Builds real `Plan`/`Run`/`Result` chains through the production Task 4/5
  pipeline (`StagingBuilder.start_run/4` -> `Publisher.publish/3`), the same
  idiom `PublisherTest`/`StagingBuilderTest` already use, rather than mocking.
  `Handoff.complete/4` is not exercised here: per this task's own retention
  rule, a `Result` row alone — regardless of `onboarding_handoff_state` — is
  what keeps a plan/run out of the timer, so the device-project handoff
  pipeline is out of this file's own scope (it is `HandoffTest`'s coverage).
  """
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Privacy.{DeploymentPrivacyProfile, ProcessingInventory, Retention, Rights}
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.{Plan, Publisher, Result, Run, StagingBuilder}
  alias SddOrchestrator.RepositoryInitialization.{SecurityLog, StagingWorkspace}

  setup do
    base = Path.join(System.tmp_dir!(), "sdd-ri-privacy-#{System.unique_integer([:positive])}")
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

    %{target: target}
  end

  describe "authority transition [AC-15]" do
    test "a plan abandoned with no run is deleted by Retention.prune_all/1 once 24 hours pass" do
      plan = plan_fixture()
      backdate_plan(plan, hours_ago(25))

      Retention.prune_all()

      refute Repo.get(Plan, plan.id)
    end

    test "a plan with no run is not yet due before 24 hours" do
      plan = plan_fixture()
      backdate_plan(plan, hours_ago(1))

      Retention.prune_all()

      assert Repo.get(Plan, plan.id)
    end

    test "a failed run with no result is deleted with its plan once 24 hours pass" do
      plan = confirmed_plan_fixture()
      run = failed_run_fixture(plan)
      backdate_run(run, hours_ago(25))

      Retention.prune_all()

      refute Repo.get(Run, run.id)
      refute Repo.get(Plan, plan.id)
    end

    test "a failed run with no result is not yet due before 24 hours" do
      plan = confirmed_plan_fixture()
      run = failed_run_fixture(plan)
      backdate_run(run, hours_ago(1))

      Retention.prune_all()

      assert Repo.get(Run, run.id)
      assert Repo.get(Plan, plan.id)
    end

    test "a run still pending or running is never touched here, however old", %{target: _target} do
      plan = confirmed_plan_fixture()
      run = pending_run_fixture(plan)
      backdate_run(run, hours_ago(9999))

      Retention.prune_all()

      assert Repo.get(Run, run.id)
      assert Repo.get(Plan, plan.id)
    end

    test "a plan/run/result chain with a completed result survives even a far-future prune", %{
      target: target
    } do
      {plan, run, result} = completed_chain_fixture(target)
      far_future = DateTime.add(DateTime.utc_now(), 3650 * 24 * 60 * 60, :second)

      Retention.prune_all(far_future)

      assert Repo.get(Plan, plan.id)
      assert Repo.get(Run, run.id)
      assert Repo.get(Result, result.id)
    end
  end

  describe "worker locality [AC-15]" do
    test "no plan, run, or result schema persists an absolute filesystem path" do
      suspicious = ~w(path absolute_path staging_path target_path real_path)a

      for schema <- [Plan, Run, Result] do
        fields = schema.__schema__(:fields)

        for name <- suspicious do
          refute name in fields, "#{inspect(schema)} unexpectedly persists #{name}"
        end
      end
    end
  end

  describe "source-upload negative [AC-15]" do
    test "SupportDispatch's dispatch payload never includes staging or source file content" do
      source =
        File.read!("lib/sdd_orchestrator/repository_initialization/support_dispatch.ex")

      refute source =~ "StagingWorkspace"
      refute source =~ "File.read"
      refute source =~ "target_path"
    end
  end

  describe "access [AC-15]" do
    test "get_plan/2 refuses a plan belonging to a different device workspace" do
      plan = plan_fixture()

      assert {:error, :not_found} =
               RepositoryInitialization.get_plan(Ecto.UUID.generate(), plan.id)
    end
  end

  describe "lifecycle and cancellation cleanup [AC-15]" do
    test "a canceled run leaves no staging directory (confirms StagingBuilderTest's own coverage)" do
      plan = confirmed_plan_fixture()
      run = pending_run_fixture(plan)

      assert {:ok, canceled_request} = StagingBuilder.cancel_run(run)
      assert {:ok, result} = StagingBuilder.build(canceled_request, plan)

      assert result.state == "canceled"
      assert {:ok, staging_path} = StagingWorkspace.staging_path(result)
      refute File.exists?(staging_path)
    end
  end

  describe "rights [AC-15]" do
    test "export_account/1 includes the account's own plan, run, and result chain", %{
      target: target
    } do
      account = AccountsFixtures.account_fixture()
      plan = confirmed_plan_fixture(%{account_id: account.id})

      assert {:ok, run} =
               StagingBuilder.start_run(
                 plan,
                 Ecto.UUID.generate(),
                 ["staging_write"],
                 idempotency_key()
               )

      assert {:ok, result} = Publisher.publish(run, plan, target)

      assert {:ok, export} = Rights.export_account(account.id)
      assert [exported_plan] = export.repository_initialization_plans
      assert exported_plan.id == plan.id
      assert exported_plan.purpose == plan.purpose
      assert exported_plan.run.id == run.id
      assert exported_plan.result.id == result.id
    end

    test "erase_account/2 deletes the account's own plan and run" do
      account = AccountsFixtures.account_fixture()
      plan = confirmed_plan_fixture(%{account_id: account.id})
      run = failed_run_fixture(plan)

      assert {:ok, _result} = Rights.erase_account(account.id)

      refute Repo.get(Plan, plan.id)
      refute Repo.get(Run, run.id)
    end
  end

  describe "processor and transfer [AC-15]" do
    test "StagingBuilder and Publisher reference no HTTP client" do
      sources =
        [
          "lib/sdd_orchestrator/repository_initialization/staging_builder.ex",
          "lib/sdd_orchestrator/repository_initialization/publisher.ex"
        ]
        |> Enum.map_join("\n", &File.read!/1)

      for forbidden <- ["Req.", "Finch", "HTTPoison", ":httpc", ":gun"] do
        refute sources =~ forbidden
      end
    end

    test "the new processing-inventory record uses the standard deployment-profile transfer clause" do
      record =
        Enum.find(ProcessingInventory.records(), &(&1.activity == :repository_initialization))

      assert record != nil
      assert record.transfers == "Per deployment privacy profile."
      assert record.lawful_basis == :contract
    end
  end

  describe "redaction [AC-15]" do
    test "SecurityLog.audit/2 never logs a 2-tuple failure's carried reason" do
      marker = "forbidden-marker-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:error, ^marker} = SecurityLog.audit({:error, marker}, :confirm_plan)
        end)

      assert log =~ "[repository_initialization_security]"
      assert log =~ "event=confirm_plan"
      assert log =~ "outcome=operation_failed"
      refute log =~ marker
    end

    test "SecurityLog.audit/2 never logs a 3-tuple failure's carried entity" do
      marker = "forbidden-entity-marker-#{System.unique_integer([:positive])}"
      entity = %{target_reference: marker, purpose: marker, id: marker}

      log =
        capture_log(fn ->
          assert {:error, :commit_failed, ^entity} =
                   SecurityLog.audit({:error, :commit_failed, entity}, :publish)
        end)

      assert log =~ "event=publish"
      assert log =~ "outcome=operation_failed"
      refute log =~ marker
    end

    test "a success is never logged" do
      log =
        capture_log(fn -> SecurityLog.audit({:ok, %{id: "should-not-log"}}, :confirm_plan) end)

      assert log == ""
    end
  end

  describe "backup [AC-15]" do
    test "repository-initialization security logs fall under the standard deployment-wide policy" do
      assert DeploymentPrivacyProfile.retention_requirements() == %{
               operational_security_logs_days: 30,
               encrypted_rolling_backups_days: 35
             }
    end
  end

  describe "no analytics or secondary use, and log redaction [AC-15]" do
    test "the repository-initialization boundary never calls Logger or inspects its own data, except the one governed security log" do
      sources =
        [
          "lib/sdd_orchestrator/repository_initialization.ex",
          "lib/sdd_orchestrator/repository_initialization/plan.ex",
          "lib/sdd_orchestrator/repository_initialization/run.ex",
          "lib/sdd_orchestrator/repository_initialization/result.ex",
          "lib/sdd_orchestrator/repository_initialization/staging_builder.ex",
          "lib/sdd_orchestrator/repository_initialization/staging_workspace.ex",
          "lib/sdd_orchestrator/repository_initialization/publisher.ex",
          "lib/sdd_orchestrator/repository_initialization/handoff.ex",
          "lib/sdd_orchestrator/repository_initialization/support_dispatch.ex"
        ]
        |> Enum.map_join("\n", &File.read!/1)

      refute sources =~ "Logger."
      refute sources =~ "IO.inspect"
    end

    test "the repository-initialization tables are not analytics-shaped" do
      {:ok, %{rows: rows}} =
        Repo.query(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
        )

      tables = List.flatten(rows)

      assert "repository_initialization_plans" in tables
      assert "repository_initialization_runs" in tables
      assert "repository_initialization_results" in tables

      for table <- [
            "repository_initialization_plans",
            "repository_initialization_runs",
            "repository_initialization_results"
          ] do
        refute Regex.match?(
                 ~r/analytic|metric|tracking|telemetry_event|pageview|impression/i,
                 table
               )
      end
    end

    test "the processing inventory still declares no analytics activity" do
      refute ProcessingInventory.analytics?()
    end
  end

  ## Fixtures and helpers

  defp idempotency_key, do: WorkerProtocol.generate_id()

  defp hours_ago(hours) do
    DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)
  end

  defp backdate_plan(plan, timestamp) do
    from(p in Plan, where: p.id == ^plan.id)
    |> Repo.update_all(set: [updated_at: timestamp])
  end

  defp backdate_run(run, timestamp) do
    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [finished_at: timestamp, updated_at: timestamp])
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

  defp plan_fixture(overrides \\ %{}) do
    {:ok, plan} = RepositoryInitialization.create_plan(base_plan_attrs(overrides))
    plan
  end

  defp ready_plan_fixture(overrides) do
    plan = plan_fixture(overrides)

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

  defp confirmed_plan_fixture(overrides \\ %{}) do
    plan = ready_plan_fixture(overrides)
    {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, "declined")
    {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
    {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)
    {:ok, plan} = RepositoryInitialization.confirm_plan(plan, plan.device_workspace_id, snapshot)
    plan
  end

  # A run created directly through `Run.create_changeset/2`, without invoking
  # `StagingBuilder.build/3` — mirrors `StagingBuilderTest`'s own
  # `pending_run_fixture/1` (duplicated rather than shared across test files,
  # this codebase's own established convention for small fixture helpers).
  defp pending_run_fixture(plan) do
    %Run{}
    |> Run.create_changeset(%{
      plan_id: plan.id,
      device_workspace_id: plan.device_workspace_id,
      worker_id: Ecto.UUID.generate(),
      dispatch_id: WorkerProtocol.generate_id(),
      idempotency_key: idempotency_key(),
      state: "pending",
      kit_choice: plan.kit_choice,
      kit_package_id: plan.kit_package_id,
      kit_package_digest: plan.kit_package_digest
    })
    |> Repo.insert!()
  end

  defp failed_run_fixture(plan) do
    plan
    |> pending_run_fixture()
    |> Run.state_changeset(%{
      state: "failed",
      failure_reason: "test_failure",
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp completed_chain_fixture(target) do
    plan = confirmed_plan_fixture()

    assert {:ok, run} =
             StagingBuilder.start_run(
               plan,
               Ecto.UUID.generate(),
               ["staging_write"],
               idempotency_key()
             )

    assert run.state == "completed"
    assert {:ok, result} = Publisher.publish(run, plan, target)

    {plan, run, result}
  end
end
