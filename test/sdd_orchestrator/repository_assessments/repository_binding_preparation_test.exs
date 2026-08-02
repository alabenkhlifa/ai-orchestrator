defmodule SddOrchestrator.RepositoryAssessments.RepositoryBindingPreparationTest.Adapter do
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

defmodule SddOrchestrator.RepositoryAssessments.RepositoryBindingPreparationTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  alias SddOrchestrator.RepositoryAssessments.{
    BindingStore,
    RepositoryBindingPreparation,
    WorkerRepositoryMetadata
  }

  alias SddOrchestrator.RepositoryAssessments.RepositoryBindingPreparationTest.Adapter

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit "0123456789abcdef0123456789abcdef01234567"

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-binding-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()
    :ok = BindingStore.reset()
    Adapter.install()

    account = account_fixture()
    workspace = workspace_fixture(account)
    hosted_project = registered_project(workspace)
    worker = reachable_worker(device_workspace.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      account: account,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: now,
      worker: worker
    }
  end

  test "the value accepts only minimized fields and normalizes root and commit", context do
    attrs = preparation_attrs(context)

    assert {:ok, preparation} = RepositoryBindingPreparation.new(attrs)
    assert preparation.root == "apps/api"
    assert preparation.commit == @commit

    assert Map.keys(Map.from_struct(preparation)) |> Enum.sort() ==
             RepositoryBindingPreparation.fields() |> Enum.sort()

    inspected = inspect(preparation)
    refute inspected =~ context.device_workspace.id
    refute inspected =~ "/Users/"
    refute inspected =~ "credential"
    refute inspected =~ "remote"
    refute inspected =~ "content"

    assert {:error, :invalid_preparation} =
             attrs
             |> Map.put(:absolute_path, "/private/repository")
             |> RepositoryBindingPreparation.new()

    assert {:ok, %{root: "."}} =
             attrs |> Map.put(:root, "././") |> RepositoryBindingPreparation.new()
  end

  test "an owner prepares and consumes one exact binding once without durable writes", context do
    hosted_count = Repo.aggregate(Project, :count)
    device_projects = Devices.list_projects()

    assert {:ok, preparation} = prepare_hosted(context)
    assert preparation.project_id == context.hosted_project.id
    assert preparation.repository_provider == context.hosted_project.repository_provider
    assert preparation.repository_id == context.hosted_project.canonical_repository_id
    assert preparation.root == "."
    assert preparation.commit == @commit
    assert BindingStore.count() == 1

    assert [{:prepare, request}] = Adapter.events()

    assert Map.keys(request) |> Enum.sort() ==
             [
               :device_workspace_id,
               :disclosure_digest,
               :project_id,
               :repository_id,
               :repository_provider,
               :scanner_contract_digest,
               :selected_root,
               :selection_ref,
               :worker_ref
             ]

    refute Map.has_key?(request, :credential)
    refute Map.has_key?(request, :repository_path)

    assert {:ok, ^preparation} = consume_hosted(context, preparation)
    assert [{:prepare, _}, {:revalidate, _}] = Adapter.events()
    assert BindingStore.count() == 0
    assert Repo.aggregate(Project, :count) == hosted_count
    assert Devices.list_projects() == device_projects

    assert {:error, :unknown_or_replayed} = consume_hosted(context, preparation)
    assert length(Adapter.events()) == 2
  end

  test "a missing or changed disclosure confirmation issues no metadata command", context do
    attrs =
      binding_attrs(context) |> Map.put(:confirmed_disclosure_digest, String.duplicate("c", 64))

    assert {:error, :processing_boundary_confirmation_required} =
             RepositoryAssessments.prepare_binding(
               {:hosted, context.account.id},
               context.hosted_project.id,
               attrs,
               adapter: Adapter,
               now: context.now
             )

    assert Adapter.events() == []

    assert {:error, :invalid_request} =
             RepositoryAssessments.prepare_binding(
               {:hosted, context.account.id},
               context.hosted_project.id,
               binding_attrs(context, %{selection_ref: "/Users/owner/repository"}),
               adapter: Adapter,
               now: context.now
             )

    assert Adapter.events() == []

    assert {:error, :invalid_request} =
             RepositoryAssessments.prepare_binding(
               {:hosted, context.account.id},
               context.hosted_project.id,
               Map.delete(binding_attrs(context), :confirmed_disclosure_digest),
               adapter: Adapter,
               now: context.now
             )

    assert Adapter.events() == []
  end

  test "unknown, malformed, non-owner, and cross-project access fail closed", context do
    other_account = account_fixture()
    other_workspace = workspace_fixture(other_account)
    other_project = registered_project(other_workspace)

    for {account_id, project_id} <- [
          {other_account.id, context.hosted_project.id},
          {context.account.id, other_project.id},
          {context.account.id, Ecto.UUID.generate()},
          {context.account.id, "not-a-project"}
        ] do
      assert {:error, :unauthorized} =
               RepositoryAssessments.prepare_binding(
                 {:hosted, account_id},
                 project_id,
                 binding_attrs(context),
                 adapter: Adapter,
                 now: context.now
               )
    end

    assert Adapter.events() == []

    assert {:ok, preparation} = prepare_hosted(context)
    assert {:error, :unauthorized} = consume_hosted(context, preparation, other_project.id)
    assert length(Adapter.events()) == 1
  end

  test "device authority must be the current owning workspace and creates no hosted copy",
       context do
    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device repository",
        repository_fingerprint: "local-repo-fingerprint",
        status: "connected"
      })

    hosted_count = Repo.aggregate(Project, :count)
    device_count = length(Devices.list_projects())

    assert {:ok, preparation} =
             RepositoryAssessments.prepare_binding(
               {:device, context.device_workspace},
               device_project.id,
               binding_attrs(context),
               adapter: Adapter,
               now: context.now
             )

    assert preparation.repository_provider == "local"
    assert preparation.repository_id == "local-repo-fingerprint"
    assert Repo.aggregate(Project, :count) == hosted_count
    assert length(Devices.list_projects()) == device_count

    foreign_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

    assert {:error, :unauthorized} =
             RepositoryAssessments.prepare_binding(
               {:device, foreign_workspace},
               device_project.id,
               binding_attrs(context),
               adapter: Adapter,
               now: context.now
             )

    foreign_worker = reachable_worker(foreign_workspace.id)

    assert {:error, :unauthorized} =
             RepositoryAssessments.prepare_binding(
               {:device, context.device_workspace},
               device_project.id,
               binding_attrs(context, %{
                 device_workspace_id: foreign_workspace.id,
                 worker_ref: foreign_worker.id
               }),
               adapter: Adapter,
               now: context.now
             )
  end

  test "cross-workspace, unknown, stale, and unavailable workers never reach the adapter",
       context do
    foreign_workspace_id = Ecto.UUID.generate()
    foreign_worker = reachable_worker(foreign_workspace_id)

    assert {:error, :unauthorized} =
             RepositoryAssessments.prepare_binding(
               {:hosted, context.account.id},
               context.hosted_project.id,
               binding_attrs(context, %{
                 device_workspace_id: context.device_workspace.id,
                 worker_ref: foreign_worker.id
               }),
               adapter: Adapter,
               now: context.now
             )

    assert {:error, :unauthorized} =
             RepositoryAssessments.prepare_binding(
               {:hosted, context.account.id},
               context.hosted_project.id,
               binding_attrs(context, %{worker_ref: Ecto.UUID.generate()}),
               adapter: Adapter,
               now: context.now
             )

    stale_worker = reachable_worker(context.device_workspace.id)

    assert {:error, :worker_unavailable} =
             RepositoryAssessments.prepare_binding(
               {:hosted, context.account.id},
               context.hosted_project.id,
               binding_attrs(context, %{worker_ref: stale_worker.id}),
               adapter: Adapter,
               now: DateTime.add(context.now, 120, :second)
             )

    assert Adapter.events() == []
  end

  test "identity, root, and malformed worker responses fail closed", context do
    cases = [
      %{prepare: %{repository_id: "other-repository"}},
      %{prepare: %{root: "../outside"}},
      %{prepare: %{commit: "short"}},
      %{prepare: %{raw_diagnostic: "secret"}}
    ]

    for overrides <- cases do
      Adapter.install(overrides)

      assert {:error, reason} = prepare_hosted(context)
      assert reason in [:repository_mismatch, :root_mismatch, :invalid_worker_response]
    end
  end

  test "expiry, a changed commit, and worker failure burn the preparation", context do
    assert {:ok, expired} = prepare_hosted(context, ttl_seconds: 1)

    assert {:error, :expired} =
             consume_hosted(context, expired, context.hosted_project.id,
               now: DateTime.add(context.now, 1, :second)
             )

    assert {:error, :unknown_or_replayed} = consume_hosted(context, expired)

    Adapter.install()
    assert {:ok, changed} = prepare_hosted(context)
    Adapter.change(%{revalidate: %{commit: String.duplicate("d", 40)}})
    assert {:error, :stale} = consume_hosted(context, changed)
    assert {:error, :unknown_or_replayed} = consume_hosted(context, changed)

    Adapter.install()
    assert {:ok, unavailable} = prepare_hosted(context)
    Adapter.change(%{revalidate: {:error, :worker_unavailable}})
    assert {:error, :stale} = consume_hosted(context, unavailable)
    assert {:error, :unknown_or_replayed} = consume_hosted(context, unavailable)
  end

  test "losing the transient store invalidates every preparation", context do
    assert {:ok, preparation} = prepare_hosted(context)
    old_pid = Process.whereis(BindingStore)
    GenServer.stop(old_pid)

    assert eventually(fn ->
             is_pid(Process.whereis(BindingStore)) and Process.whereis(BindingStore) != old_pid
           end)

    assert {:error, :unknown_or_replayed} = consume_hosted(context, preparation)
  end

  test "worker-local metadata proves identity, root, exact commit, and repository non-mutation" do
    %{base: base, repository: repository, commit: commit} = git_fixture()
    on_exit(fn -> File.rm_rf!(base) end)

    before = git_snapshot(repository)

    matcher = fn path, %{repository_provider: "github", repository_id: "101"} ->
      {:ok, path == repository}
    end

    assert {:ok, result} =
             WorkerRepositoryMetadata.inspect(
               repository,
               "./apps/api",
               %{repository_provider: "github", repository_id: "101"},
               matcher
             )

    assert result == %{
             repository_provider: "github",
             repository_id: "101",
             root: "apps/api",
             commit: commit
           }

    refute inspect(result) =~ repository
    assert git_snapshot(repository) == before

    assert {:error, :repository_mismatch} =
             WorkerRepositoryMetadata.inspect(
               repository,
               ".",
               %{repository_provider: "github", repository_id: "other"},
               fn _path, _identity -> {:ok, false} end
             )

    outside = Path.join(base, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(repository, "escape"))
    before_escape_check = git_snapshot(repository)

    assert {:error, :root_escape} =
             WorkerRepositoryMetadata.inspect(
               repository,
               "escape",
               %{repository_provider: "github", repository_id: "101"},
               matcher
             )

    assert git_snapshot(repository) == before_escape_check
  end

  defp prepare_hosted(context, opts \\ []) do
    RepositoryAssessments.prepare_binding(
      {:hosted, context.account.id},
      context.hosted_project.id,
      binding_attrs(context),
      Keyword.merge([adapter: Adapter, now: context.now], opts)
    )
  end

  defp consume_hosted(context, preparation, project_id \\ nil, opts \\ []) do
    RepositoryAssessments.consume_binding(
      {:hosted, context.account.id},
      project_id || context.hosted_project.id,
      preparation,
      Keyword.merge([now: context.now], opts)
    )
  end

  defp binding_attrs(context, overrides \\ %{}) do
    Map.merge(
      %{
        device_workspace_id: context.device_workspace.id,
        worker_ref: context.worker.id,
        selection_ref: "selection-#{System.unique_integer([:positive])}",
        selected_root: ".",
        scanner_contract_digest: @scanner_digest,
        disclosure_digest: @disclosure_digest,
        confirmed_disclosure_digest: @disclosure_digest
      },
      overrides
    )
  end

  defp preparation_attrs(context) do
    %{
      project_id: context.hosted_project.id,
      repository_provider: "github",
      repository_id: "101",
      root: "./apps/api",
      commit: String.upcase(@commit),
      scanner_contract_digest: @scanner_digest,
      disclosure_digest: @disclosure_digest,
      worker_ref: context.worker.id,
      nonce: Ecto.UUID.generate(),
      issued_at: context.now,
      expires_at: DateTime.add(context.now, 120, :second)
    }
  end

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
      Path.join(System.tmp_dir!(), "repository-metadata-#{System.unique_integer([:positive])}")

    repository = Path.join(base, "repository")
    File.mkdir_p!(Path.join(repository, "apps/api"))
    git!(repository, ["init"])
    git!(repository, ["config", "user.email", "task7@example.invalid"])
    git!(repository, ["config", "user.name", "Task 7"])
    File.write!(Path.join(repository, "README.md"), "fixture\n")
    File.write!(Path.join(repository, "apps/api/mix.exs"), "fixture\n")
    git!(repository, ["add", "README.md", "apps/api/mix.exs"])
    git!(repository, ["commit", "-m", "fixture"])
    %{base: base, repository: repository, commit: git!(repository, ["rev-parse", "HEAD"])}
  end

  defp git_snapshot(repository) do
    %{
      commit: git!(repository, ["rev-parse", "HEAD"]),
      tree: git!(repository, ["rev-parse", "HEAD^{tree}"]),
      status: git!(repository, ["status", "--porcelain=v1", "--untracked-files=all"])
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
