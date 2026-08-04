defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessmentTest.Adapter do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  @commit "0123456789abcdef0123456789abcdef01234567"

  def install(overrides \\ %{}) do
    Process.put(__MODULE__, %{events: [], overrides: overrides})
    __MODULE__
  end

  def events, do: state().events

  def change(overrides) do
    Process.put(__MODULE__, %{state() | overrides: Map.merge(state().overrides, overrides)})
  end

  @impl true
  def prepare(request), do: respond(:prepare, request)

  @impl true
  def revalidate(request), do: respond(:revalidate, request)

  defp respond(operation, request) do
    current = state()
    Process.put(__MODULE__, %{current | events: current.events ++ [{operation, request}]})

    case Map.get(current.overrides, operation, %{}) do
      {:error, reason} ->
        {:error, reason}

      overrides when is_map(overrides) ->
        {:ok,
         Map.merge(
           %{
             repository_provider: request.repository_provider,
             repository_id: request.repository_id,
             root: request.selected_root,
             commit: @commit
           },
           overrides
         )}
    end
  end

  defp state, do: Process.get(__MODULE__, %{events: [], overrides: %{}})
end

defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessmentTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    BindingStore,
    RepositoryAssessment,
    RepositoryBindingPreparation
  }

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentTest.Adapter

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @changed_commit String.duplicate("d", 40)

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-assessment-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device assessment project",
        repository_fingerprint: "device-repository-fingerprint",
        status: "connected"
      })

    :ok = BindingStore.reset()
    Adapter.install()

    account = account_fixture()
    workspace = workspace_fixture(account)
    hosted_project = registered_project(workspace)
    worker = reachable_worker(device_workspace.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: now,
      store_path: store_path,
      worker: worker
    }
  end

  test "the hosted owner persists one minimized pending assessment and confirmation record",
       context do
    assert {:ok, preparation} = prepare_hosted(context)

    assert {:ok, assessment} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               preparation,
               now: context.now
             )

    assert assessment.state == RepositoryAssessment.pending_state()
    assert assessment.project_id == context.hosted_project.id
    assert assessment.repository_provider == preparation.repository_provider
    assert assessment.repository_id == preparation.repository_id
    assert assessment.root == preparation.root
    assert assessment.commit == preparation.commit
    assert assessment.scanner_contract_digest == @scanner_digest
    assert assessment.disclosure_digest == @disclosure_digest
    assert DateTime.diff(assessment.boundary_confirmed_at, preparation.issued_at) == 0

    assert Repo.get!(RepositoryAssessment, assessment.id) == assessment

    assert {:ok, ^assessment} =
             AssessmentStore.fetch(
               hosted_authority(context),
               context.hosted_project.id,
               assessment.id
             )

    assert AssessmentStore.count(hosted_authority(context), context.hosted_project.id) == 1

    inspected = inspect(assessment)
    refute inspected =~ "/Users/"
    refute inspected =~ "credential"
    refute inspected =~ "remote_url"
    refute inspected =~ "raw_diagnostic"
  end

  test "the device owner persists only in DETS and the value survives restart", context do
    assert {:ok, preparation} = prepare_device(context)
    hosted_count = Repo.aggregate(RepositoryAssessment, :count)

    assert {:ok, assessment} =
             RepositoryAssessments.start_assessment(
               device_authority(context),
               context.device_project.id,
               preparation,
               now: context.now
             )

    assert assessment.state == "pending_scan"
    assert Repo.aggregate(RepositoryAssessment, :count) == hosted_count
    assert Devices.repository_assessment_count(context.device_project.id) == 1

    stop_supervised!(Local)
    start_supervised!({Local, path: context.store_path})

    assert {:ok, workspace} = Devices.get_workspace()

    assert {:ok, ^assessment} =
             AssessmentStore.fetch(
               {:device, workspace},
               context.device_project.id,
               assessment.id
             )

    assert Repo.aggregate(RepositoryAssessment, :count) == hosted_count
  end

  test "hosted non-owner, cross-project, inactive, and wrong-store starts fail before persistence",
       context do
    other_account = account_fixture()
    other_workspace = workspace_fixture(other_account)
    other_project = registered_project(other_workspace)

    assert {:ok, non_owner_preparation} = prepare_hosted(context)

    assert {:error, :unauthorized} =
             RepositoryAssessments.start_assessment(
               {:hosted, other_account.id},
               context.hosted_project.id,
               non_owner_preparation,
               now: context.now
             )

    assert {:error, :unauthorized} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               other_project.id,
               non_owner_preparation,
               now: context.now
             )

    assert {:ok, inactive_preparation} = prepare_hosted(context)

    context.hosted_project
    |> Ecto.Changeset.change(lifecycle_state: "archived")
    |> Repo.update!()

    assert {:error, :unauthorized} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               inactive_preparation,
               now: context.now
             )

    assert Repo.aggregate(RepositoryAssessment, :count) == 0

    assert {:error, :not_found} =
             AssessmentStore.fetch(
               hosted_authority(context),
               other_project.id,
               Ecto.UUID.generate()
             )
  end

  test "device authority is isolated to the current owning workspace and exact project",
       context do
    assert {:ok, preparation} = prepare_device(context)
    foreign_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

    assert {:error, :unauthorized} =
             RepositoryAssessments.start_assessment(
               {:device, foreign_workspace},
               context.device_project.id,
               preparation,
               now: context.now
             )

    assert {:error, :unauthorized} =
             RepositoryAssessments.start_assessment(
               device_authority(context),
               Ecto.UUID.generate(),
               preparation,
               now: context.now
             )

    assert Devices.repository_assessment_count(context.device_project.id) == 0
    assert Repo.aggregate(RepositoryAssessment, :count) == 0
  end

  test "hosted and device authorities cannot cross storage destinations", context do
    assert {:ok, hosted_preparation} = prepare_hosted(context)

    assert {:error, :unauthorized} =
             RepositoryAssessments.start_assessment(
               device_authority(context),
               context.hosted_project.id,
               hosted_preparation,
               now: context.now
             )

    assert {:ok, hosted_assessment} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               hosted_preparation,
               now: context.now
             )

    assert {:error, :not_found} =
             AssessmentStore.fetch(
               device_authority(context),
               context.hosted_project.id,
               hosted_assessment.id
             )

    assert {:ok, device_preparation} = prepare_device(context)

    assert {:error, :unauthorized} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.device_project.id,
               device_preparation,
               now: context.now
             )

    assert {:ok, device_assessment} =
             RepositoryAssessments.start_assessment(
               device_authority(context),
               context.device_project.id,
               device_preparation,
               now: context.now
             )

    assert {:error, :not_found} =
             AssessmentStore.fetch(
               hosted_authority(context),
               context.device_project.id,
               device_assessment.id
             )

    assert Repo.aggregate(RepositoryAssessment, :count) == 1
    assert Devices.repository_assessment_count(context.device_project.id) == 1
  end

  test "the assessment preserves Task 7 valid 64-character commits and long relative roots",
       context do
    root = String.duplicate("a", 300)
    commit = String.duplicate("c", 64)

    assert {:ok, preparation} =
             RepositoryBindingPreparation.new(%{
               project_id: context.hosted_project.id,
               repository_provider: context.hosted_project.repository_provider,
               repository_id: context.hosted_project.canonical_repository_id,
               root: root,
               commit: commit,
               scanner_contract_digest: @scanner_digest,
               disclosure_digest: @disclosure_digest,
               worker_ref: context.worker.id,
               nonce: Ecto.UUID.generate(),
               issued_at: context.now,
               expires_at: DateTime.add(context.now, 120, :second)
             })

    assert {:ok, assessment} = RepositoryAssessment.pending(preparation, context.now)
    assert assessment.root == root
    assert byte_size(assessment.root) > 255
    assert assessment.commit == commit
  end

  test "stale, expired, tampered, and replayed bindings persist nothing", context do
    assert {:ok, stale} = prepare_hosted(context)
    Adapter.change(%{revalidate: %{commit: @changed_commit}})

    assert {:error, :stale} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               stale,
               now: context.now
             )

    assert {:error, :unknown_or_replayed} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               stale,
               now: context.now
             )

    Adapter.install()
    assert {:ok, expired} = prepare_hosted(context, ttl_seconds: 1)

    assert {:error, :expired} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               expired,
               now: DateTime.add(context.now, 1, :second)
             )

    Adapter.install()
    assert {:ok, exact} = prepare_hosted(context)
    tampered = %{exact | commit: @changed_commit}

    assert {:error, :unknown_or_replayed} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               tampered,
               now: context.now
             )

    assert Repo.aggregate(RepositoryAssessment, :count) == 0
  end

  test "a successful binding is single use and creates exactly one assessment", context do
    assert {:ok, preparation} = prepare_hosted(context)

    assert {:ok, _assessment} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               preparation,
               now: context.now
             )

    assert {:error, :unknown_or_replayed} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               preparation,
               now: context.now
             )

    assert Repo.aggregate(RepositoryAssessment, :count) == 1
  end

  test "the device store rejects unknown fields and cross-project values", context do
    assert {:ok, preparation} = prepare_device(context)
    assert {:ok, assessment} = RepositoryAssessment.pending(preparation, context.now)
    value = RepositoryAssessment.to_value(assessment)

    # Intern the atom so the allowlisted key set does the rejecting. Without
    # this the refusal depends on whether another module happened to define
    # `:absolute_path`, which made this test pass for the wrong reason.
    _interned = :absolute_path

    assert {:error, :invalid_assessment} =
             Devices.put_repository_assessment(
               context.device_project.id,
               assessment.id,
               Map.put(value, "absolute_path", "/private/repository")
             )

    assert {:error, :invalid_assessment} =
             Devices.put_repository_assessment(
               context.device_project.id,
               assessment.id,
               Map.put(value, "project_id", Ecto.UUID.generate())
             )

    assert {:error, :invalid_assessment} =
             Devices.put_repository_assessment(
               context.device_project.id,
               assessment.id,
               Map.put(value, "repository_id", "another-repository")
             )

    assert Devices.repository_assessment_count(context.device_project.id) == 0
  end

  test "start issues only metadata revalidation and leaves a repository unchanged", context do
    repository = git_fixture()
    on_exit(fn -> File.rm_rf!(Path.dirname(repository)) end)
    before = git_snapshot(repository)

    assert {:ok, preparation} = prepare_hosted(context)

    assert {:ok, assessment} =
             RepositoryAssessments.start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               preparation,
               now: context.now
             )

    assert Enum.map(Adapter.events(), &elem(&1, 0)) == [:prepare, :revalidate]
    refute Enum.any?(Adapter.events(), fn {operation, _request} -> operation == :scan end)
    assert git_snapshot(repository) == before
    assert assessment.state == "pending_scan"
  end

  test "the migrations expose authoritative binding and terminal-state constraints" do
    columns =
      Repo.query!("""
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_name = 'repository_assessments'
      """).rows
      |> Map.new(fn [name, type] -> {name, type} end)

    assert columns["project_id"] == "uuid"
    assert columns["worker_ref"] == "uuid"
    assert columns["root"] == "text"
    assert columns["boundary_confirmed_at"] == "timestamp without time zone"
    assert columns["scan_protocol_version"] == "integer"
    assert columns["scan_limits"] == "jsonb"
    assert columns["findings"] == "ARRAY"
    assert columns["terminal_at"] == "timestamp without time zone"

    constraints =
      Repo.query!("""
      SELECT constraint_name
      FROM information_schema.table_constraints
      WHERE table_name = 'repository_assessments'
      """).rows
      |> Enum.map(&hd/1)

    refute "repository_assessments_pending_state" in constraints
    assert "repository_assessments_state" in constraints
    assert "repository_assessments_scan_contract" in constraints
    assert "repository_assessments_terminal_shape" in constraints
    assert "repository_assessments_failure_code" in constraints
    assert "repository_assessments_commit_shape" in constraints
    assert "repository_assessments_digest_shape" in constraints
  end

  defp prepare_hosted(context, opts \\ []) do
    prepare(
      hosted_authority(context),
      context.hosted_project.id,
      context,
      opts
    )
  end

  defp prepare_device(context) do
    prepare(device_authority(context), context.device_project.id, context, [])
  end

  defp prepare(authority, project_id, context, opts) do
    RepositoryAssessments.prepare_binding(
      authority,
      project_id,
      %{
        device_workspace_id: context.device_workspace.id,
        worker_ref: context.worker.id,
        selection_ref: "assessment-#{System.unique_integer([:positive])}",
        selected_root: ".",
        scanner_contract_digest: @scanner_digest,
        disclosure_digest: @disclosure_digest,
        confirmed_disclosure_digest: @disclosure_digest
      },
      Keyword.merge([adapter: Adapter, now: context.now], opts)
    )
  end

  defp hosted_authority(context), do: {:hosted, context.account.id}
  defp device_authority(context), do: {:device, context.device_workspace}

  defp reachable_worker(device_workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end

  defp git_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "assessment-start-repository-#{System.unique_integer([:positive])}"
      )

    repository = Path.join(base, "repository")
    File.mkdir_p!(repository)
    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.email", "test@example.com"])
    git!(repository, ["config", "user.name", "Test"])
    File.write!(Path.join(repository, "README.md"), "unchanged\n")
    git!(repository, ["add", "README.md"])
    git!(repository, ["commit", "--quiet", "-m", "fixture"])
    repository
  end

  defp git_snapshot(repository) do
    %{
      head: git!(repository, ["rev-parse", "HEAD"]),
      status: git!(repository, ["status", "--porcelain=v1", "--untracked-files=all"])
    }
  end

  defp git!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
