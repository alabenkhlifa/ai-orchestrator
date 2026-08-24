defmodule SddOrchestrator.Portability.HostedLocalRepositoryConnectionTest do
  @moduledoc """
  Task 1 proof for the first-connection authority gate.

  A hosted project created normally has no `PackageProvenance`, so the
  restore-gated entry can never reach it. This gate is the first path to a
  binding for such a project, and it must refuse every authority, provider,
  identity, and availability failure without touching the binding set or the
  repository on disk.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures, only: [workspace_fixture: 1]

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{Pairing, PortableRepositoryIdentity, WorkerDiscovery}

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBinding,
    HostedLocalRepositoryConnection,
    RepositoryReconnection
  }

  alias SddOrchestrator.Projects.Project

  setup do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)

    root = git_root()
    on_exit(fn -> File.rm_rf!(root) end)

    repository = init_repo!(Path.join(root, "repository"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    project = local_project_fixture(personal_workspace, repository_id)

    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    worker = available_worker_fixture(device_workspace)

    %{
      account: account,
      personal_workspace: personal_workspace,
      project: project,
      repository: repository,
      repository_id: repository_id,
      root: root,
      device_workspace: device_workspace,
      worker: worker
    }
  end

  test "connects a project the restore-gated entry can never reach", context do
    assert {:error, :not_found} =
             RepositoryReconnection.required(
               context.personal_workspace,
               context.project.id
             )

    validated_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, result} = connect(context, validated_at: validated_at)

    assert result.project_id == context.project.id
    assert result.state == :connected
    assert result.outcome == :created
    assert result.last_validated_at == validated_at

    binding = Repo.get!(HostedLocalRepositoryBinding, context.project.id)
    assert binding.worker_id == context.worker.id
    assert binding.last_validated_at == validated_at
  end

  test "returns only the minimized routing result and proves with the held identity",
       context do
    parent = self()

    matcher = fn received_id ->
      send(parent, {:matcher_called, received_id})
      PortableRepositoryIdentity.match(context.repository, received_id)
    end

    assert {:ok, result} = connect(context, matcher: matcher)

    held_id = context.repository_id
    assert_receive {:matcher_called, ^held_id}

    assert result |> Map.keys() |> Enum.sort() ==
             [:last_validated_at, :outcome, :project_id, :state]

    rendered = inspect(result)
    refute rendered =~ context.repository
    refute rendered =~ context.repository_id
    refute rendered =~ context.worker.id
  end

  test "refuses a project owned by another personal workspace", context do
    foreign_workspace = account_fixture() |> workspace_fixture()

    assert {:error, :not_found} =
             connect(%{context | personal_workspace: foreign_workspace})

    assert {:error, :not_found} =
             connect(%{context | project: %Project{id: Ecto.UUID.generate()}})

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "refuses a project that is not a hosted local-repository project", context do
    github_project = github_project_fixture(context.personal_workspace)

    assert {:error, :invalid_project_provider} =
             connect(%{context | project: github_project})

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "refuses a project held only under a legacy workspace-scoped identifier",
       context do
    legacy_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert PortableRepositoryIdentity.legacy_identifier?(legacy_id)

    legacy_project = local_project_fixture(context.personal_workspace, legacy_id)

    assert {:error, :legacy_repository_identity} =
             connect(%{context | project: legacy_project})

    malformed_project = local_project_fixture(context.personal_workspace, "not-an-identity")

    assert {:error, :invalid_repository_identity} =
             connect(%{context | project: malformed_project})

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "refuses a machine that proves a different repository", context do
    other = init_repo!(Path.join(context.root, "other-repository"))

    matcher = fn received_id -> PortableRepositoryIdentity.match(other, received_id) end

    assert {:error, :repository_mismatch} = connect(context, matcher: matcher)

    empty = Path.join(context.root, "not-a-repository")
    File.mkdir_p!(empty)
    empty_matcher = fn received_id -> PortableRepositoryIdentity.match(empty, received_id) end

    assert {:error, :repository_unavailable} = connect(context, matcher: empty_matcher)

    assert {:error, :worker_validation_failed} =
             connect(context, matcher: fn _received_id -> raise "worker exploded" end)

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "refuses an unauthorized, revoked, or unreachable worker without asking it",
       context do
    parent = self()

    matcher = fn _received_id ->
      send(parent, :matcher_called)
      {:ok, true}
    end

    foreign_device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

    assert {:error, :unauthorized_worker} =
             connect(
               %{context | device_workspace: foreign_device_workspace},
               matcher: matcher
             )

    assert {:error, :unauthorized_worker} =
             connect(
               %{context | worker: %{context.worker | id: Ecto.UUID.generate()}},
               matcher: matcher
             )

    assert {:ok, revoked} = Pairing.revoke_worker(context.worker)

    assert {:error, :unauthorized_worker} =
             connect(%{context | worker: revoked}, matcher: matcher)

    unreachable_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    unreachable = paired_worker_fixture(unreachable_workspace)

    assert {:error, :worker_unavailable} =
             connect(
               %{
                 context
                 | device_workspace: unreachable_workspace,
                   worker: unreachable
               },
               matcher: matcher
             )

    stale_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    stale_worker = available_worker_fixture(stale_workspace)

    stale_at =
      DateTime.utc_now()
      |> DateTime.add(WorkerDiscovery.staleness_seconds() + 1, :second)
      |> DateTime.truncate(:second)

    assert {:error, :worker_unavailable} =
             connect(
               %{context | device_workspace: stale_workspace, worker: stale_worker},
               matcher: matcher,
               validated_at: stale_at
             )

    refute_receive :matcher_called
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "no refusal changes the binding set or the repository on disk", context do
    before_repository = git_snapshot(context.repository)

    assert {:ok, _result} = connect(context)
    before_binding = Repo.get!(HostedLocalRepositoryBinding, context.project.id)

    foreign_workspace = account_fixture() |> workspace_fixture()
    other = init_repo!(Path.join(context.root, "replacement-candidate"))
    unreachable_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

    refusals = [
      fn -> connect(%{context | personal_workspace: foreign_workspace}) end,
      fn -> connect(%{context | project: github_project_fixture(context.personal_workspace)}) end,
      fn ->
        connect(context, matcher: fn id -> PortableRepositoryIdentity.match(other, id) end)
      end,
      fn ->
        connect(%{
          context
          | device_workspace: unreachable_workspace,
            worker: paired_worker_fixture(unreachable_workspace)
        })
      end,
      fn -> connect(%{context | worker: %{context.worker | id: Ecto.UUID.generate()}}) end
    ]

    for refusal <- refusals do
      assert {:error, _reason} = refusal.()
    end

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1
    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id) == before_binding
    assert git_snapshot(context.repository) == before_repository
  end

  defp connect(context, opts \\ []) do
    {matcher, opts} =
      Keyword.pop_lazy(opts, :matcher, fn ->
        fn received_id -> PortableRepositoryIdentity.match(context.repository, received_id) end
      end)

    HostedLocalRepositoryConnection.connect(
      context.personal_workspace,
      context.project.id,
      context.device_workspace,
      context.worker.id,
      matcher,
      opts
    )
  end

  defp local_project_fixture(personal_workspace, repository_id) do
    %Project{}
    |> Project.changeset(%{
      name: "local-project-#{System.unique_integer([:positive])}",
      workspace_id: personal_workspace.id,
      storage_mode: "hosted",
      repository_provider: "local",
      canonical_repository_id: repository_id
    })
    |> Repo.insert!()
  end

  defp github_project_fixture(personal_workspace) do
    %Project{}
    |> Project.changeset(%{
      name: "github-project-#{System.unique_integer([:positive])}",
      workspace_id: personal_workspace.id,
      storage_mode: "hosted",
      repository_provider: "github",
      canonical_repository_id: "github:#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp available_worker_fixture(device_workspace) do
    worker = paired_worker_fixture(device_workspace)
    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end

  defp paired_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    worker
  end

  defp git_root do
    Path.join(
      System.tmp_dir!(),
      "sdd_hosted_local_connection_#{System.unique_integer([:positive])}"
    )
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "first-connection@example.test"])
    git!(path, ["config", "user.name", "First Connection"])
    File.write!(Path.join(path, "README.md"), "unchanged #{Path.basename(path)}")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-q", "-m", "initial"])
    path
  end

  defp git_snapshot(path) do
    %{
      head: git!(path, ["rev-parse", "HEAD"]),
      branches: git!(path, ["branch", "--format=%(refname)"]),
      remotes: git!(path, ["remote", "-v"]),
      status: git!(path, ["status", "--porcelain=v1"]),
      config: git!(path, ["config", "--local", "--list"])
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
