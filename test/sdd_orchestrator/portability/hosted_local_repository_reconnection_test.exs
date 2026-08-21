defmodule SddOrchestrator.Portability.HostedLocalRepositoryReconnectionTest do
  @moduledoc """
  Task 27 proof for explicit dual-authority hosted local-repository reconnection.
  """

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{Pairing, PortableRepositoryIdentity, WorkerDiscovery}

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBinding,
    HostedLocalRepositoryReconnection,
    HostedRestore,
    PackageProvenance,
    PackageSection,
    ProjectPackage,
    RepositoryReconnection,
    RestoreDecision
  }

  alias SddOrchestrator.Projects.{Project, RepositoryConnection}

  setup do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    worker = available_worker(device_workspace.id)
    root = git_root()
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      account: account,
      personal_workspace: personal_workspace,
      device_workspace: device_workspace,
      worker: worker.worker,
      credential: worker.credential,
      root: root
    }
  end

  test "connects and idempotently retains one exact minimized hosted binding", context do
    repository = init_repo!(Path.join(context.root, "exact"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    project = restore_hosted(context.personal_workspace, package(repository_id), "hosted-local")
    {:ok, request} = RepositoryReconnection.required(context.personal_workspace, project.id)
    before = Repo.get!(Project, project.id)
    validated_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok,
            %{
              project_id: project_id,
              repository_provider: "local",
              repository_id: ^repository_id,
              status: :connected
            } = result} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               &PortableRepositoryIdentity.match(repository, &1),
               validated_at: validated_at
             )

    assert project_id == project.id

    binding = Repo.get!(HostedLocalRepositoryBinding, project.id)
    assert binding.worker_id == context.worker.id
    assert binding.last_validated_at == validated_at
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1

    assert {:ok, ^result} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               &PortableRepositoryIdentity.match(repository, &1),
               validated_at: DateTime.add(validated_at, 1, :second)
             )

    retained = Repo.get!(HostedLocalRepositoryBinding, project.id)
    assert retained.worker_id == binding.worker_id
    assert retained.last_validated_at == DateTime.add(validated_at, 1, :second)
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1

    assert Repo.get!(Project, project.id) == before
    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "requires separate owning personal-workspace and selected device-workspace authority",
       context do
    repository = init_repo!(Path.join(context.root, "dual-authority"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)

    project =
      restore_hosted(
        context.personal_workspace,
        package(repository_id),
        "hosted-local-authority"
      )

    {:ok, request} = RepositoryReconnection.required(context.personal_workspace, project.id)
    foreign_personal_workspace = account_fixture() |> workspace_fixture()
    foreign_device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    matcher = &PortableRepositoryIdentity.match(repository, &1)

    assert {:error, :not_found} =
             HostedLocalRepositoryReconnection.connect(
               foreign_personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               matcher
             )

    assert {:error, :authorization_required} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               foreign_device_workspace,
               request,
               context.credential,
               matcher
             )

    assert {:error, :invalid_request} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               %{request | repository_id: portable_identifier()},
               context.credential,
               matcher
             )

    assert {:error, :invalid_request} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               %{request | method: :github_authorization},
               context.credential,
               matcher
             )

    assert Repo.get(HostedLocalRepositoryBinding, project.id) == nil
  end

  test "failed replacement preserves the old worker until exact replacement proof", context do
    repository = init_repo!(Path.join(context.root, "replacement"))
    different = init_repo!(Path.join(context.root, "replacement-different"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)

    project =
      restore_hosted(
        context.personal_workspace,
        package(repository_id),
        "hosted-local-replacement"
      )

    {:ok, request} = RepositoryReconnection.required(context.personal_workspace, project.id)
    matcher = &PortableRepositoryIdentity.match(repository, &1)

    assert {:ok, %{status: :connected}} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               matcher
             )

    original = Repo.get!(HostedLocalRepositoryBinding, project.id)
    replacement = available_worker(context.device_workspace.id)

    assert {:error, :repository_mismatch} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               replacement.credential,
               &PortableRepositoryIdentity.match(different, &1)
             )

    assert_binding_worker(project.id, original.worker_id)

    assert {:error, :authorization_required} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               "invalid-credential",
               matcher
             )

    assert_binding_worker(project.id, original.worker_id)

    unavailable = paired_worker(context.device_workspace.id)

    assert {:error, :worker_unavailable} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               unavailable.credential,
               matcher
             )

    assert_binding_worker(project.id, original.worker_id)

    assert {:ok, %{status: :connected}} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               replacement.credential,
               matcher
             )

    assert_binding_worker(project.id, replacement.worker.id)
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1
  end

  test "temporary unavailability is derived and revocation removes the binding", context do
    repository = init_repo!(Path.join(context.root, "availability"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)

    project =
      restore_hosted(
        context.personal_workspace,
        package(repository_id),
        "hosted-local-availability"
      )

    {:ok, request} = RepositoryReconnection.required(context.personal_workspace, project.id)
    validated_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, %{status: :connected}} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               &PortableRepositoryIdentity.match(repository, &1),
               validated_at: validated_at
             )

    assert {:ok,
            %{
              project_id: project_id,
              state: :connected,
              last_validated_at: ^validated_at
            }} =
             HostedLocalRepositoryReconnection.connection_state(
               context.personal_workspace,
               project.id,
               now: validated_at
             )

    assert project_id == project.id
    before = Repo.get!(HostedLocalRepositoryBinding, project.id)

    unavailable_at =
      DateTime.add(validated_at, WorkerDiscovery.staleness_seconds() + 1, :second)

    assert {:ok,
            %{
              state: :temporarily_unavailable,
              last_validated_at: ^validated_at
            }} =
             HostedLocalRepositoryReconnection.connection_state(
               context.personal_workspace,
               project.id,
               now: unavailable_at
             )

    assert Repo.get!(HostedLocalRepositoryBinding, project.id) == before

    assert {:ok, _revoked} = Pairing.revoke_worker(context.worker)

    assert {:ok, %{state: :disconnected, last_validated_at: nil}} =
             HostedLocalRepositoryReconnection.connection_state(
               context.personal_workspace,
               project.id
             )

    assert Repo.get(HostedLocalRepositoryBinding, project.id) == nil

    assert {:error, :authorization_required} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               fn _repository_id -> {:ok, true} end
             )
  end

  test "explicit disconnect is owner-scoped and idempotent", context do
    repository = init_repo!(Path.join(context.root, "disconnect"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)

    project =
      restore_hosted(
        context.personal_workspace,
        package(repository_id),
        "hosted-local-disconnect"
      )

    {:ok, request} = RepositoryReconnection.required(context.personal_workspace, project.id)

    assert {:ok, %{status: :connected}} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               &PortableRepositoryIdentity.match(repository, &1)
             )

    foreign_personal_workspace = account_fixture() |> workspace_fixture()

    assert {:error, :not_found} =
             HostedLocalRepositoryReconnection.disconnect(
               foreign_personal_workspace,
               project.id
             )

    assert Repo.get(HostedLocalRepositoryBinding, project.id)

    assert {:ok, :disconnected} =
             HostedLocalRepositoryReconnection.disconnect(
               context.personal_workspace,
               project.id
             )

    assert {:ok, :disconnected} =
             HostedLocalRepositoryReconnection.disconnect(
               context.personal_workspace,
               project.id
             )

    assert Repo.get(HostedLocalRepositoryBinding, project.id) == nil
  end

  test "malformed and legacy project identities never reach the worker matcher", context do
    malformed_project =
      restored_project_fixture(context.personal_workspace, "local-repo:v1:invalid")

    {:ok, malformed_request} =
      RepositoryReconnection.required(context.personal_workspace, malformed_project.id)

    legacy = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    legacy_project = restored_project_fixture(context.personal_workspace, legacy)

    {:ok, legacy_request} =
      RepositoryReconnection.required(context.personal_workspace, legacy_project.id)

    parent = self()

    matcher = fn _repository_id ->
      send(parent, :matcher_called)
      {:ok, true}
    end

    assert {:error, :invalid_repository_identity} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               malformed_request,
               context.credential,
               matcher
             )

    assert {:error, :legacy_repository_identity} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               legacy_request,
               context.credential,
               matcher
             )

    refute_received :matcher_called
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "repository and worker failures preserve Git and create no implicit association",
       context do
    repository = init_repo!(Path.join(context.root, "unchanged"))
    git!(repository, ["remote", "add", "origin", "https://example.test/original.git"])
    before = git_snapshot(repository)
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)

    project =
      restore_hosted(
        context.personal_workspace,
        package(repository_id),
        "hosted-local-nonmutation"
      )

    {:ok, request} = RepositoryReconnection.required(context.personal_workspace, project.id)

    assert {:error, :repository_unavailable} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               fn ^repository_id -> {:error, :inaccessible} end
             )

    assert {:error, :worker_validation_failed} =
             HostedLocalRepositoryReconnection.connect(
               context.personal_workspace,
               context.device_workspace,
               request,
               context.credential,
               fn ^repository_id -> {:error, :transport_failure} end
             )

    assert Repo.get(HostedLocalRepositoryBinding, project.id) == nil
    assert git_snapshot(repository) == before
    assert Repo.get!(Project, project.id).canonical_repository_id == repository_id
    assert Repo.aggregate(RepositoryConnection, :count) == 0

    request_fields = request |> Map.from_struct() |> Map.keys()
    refute :path in request_fields
    refute :credential in request_fields
    refute :workspace_id in request_fields
    refute inspect(request) =~ repository
    refute inspect(request) =~ context.credential
  end

  defp restore_hosted(personal_workspace, package, idempotency_key) do
    {:ok, %{project: project}} =
      HostedRestore.restore(personal_workspace, package, decision(package),
        idempotency_key: idempotency_key
      )

    project
  end

  defp package(repository_id) do
    %ProjectPackage{
      project: %PackageSection{
        name: :project,
        version: 1,
        content: %{
          "id" => Ecto.UUID.generate(),
          "name" => "Hosted local #{System.unique_integer([:positive])}"
        }
      },
      repository: %PackageSection{
        name: :repository,
        version: 1,
        content: %{"provider" => "local", "repository_id" => repository_id}
      },
      specifications: %PackageSection{name: :specifications, version: 1, content: []}
    }
  end

  defp decision(package) do
    %RestoreDecision{
      project_id: package.project.content["id"],
      display_name: package.project.content["name"],
      repository_provider: "local",
      repository_id: package.repository.content["repository_id"],
      checked_boundaries: [:hosted]
    }
  end

  defp restored_project_fixture(personal_workspace, repository_id) do
    project =
      %Project{}
      |> Project.restore_changeset(%{
        id: Ecto.UUID.generate(),
        name: "Legacy hosted #{System.unique_integer([:positive])}",
        workspace_id: personal_workspace.id,
        storage_mode: "hosted",
        repository_provider: "local",
        canonical_repository_id: repository_id
      })
      |> Repo.insert!()

    %PackageProvenance{}
    |> PackageProvenance.create_changeset(%{
      project_id: project.id,
      payload_schema_version: 1,
      restored_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    project
  end

  defp available_worker(workspace_id) do
    pair = paired_worker(workspace_id)
    {:ok, worker} = Pairing.mark_seen(pair.worker)
    %{pair | worker: worker}
  end

  defp paired_worker(workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    %{worker: worker, credential: credential}
  end

  defp assert_binding_worker(project_id, worker_id) do
    assert Repo.get!(HostedLocalRepositoryBinding, project_id).worker_id == worker_id
  end

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end

  defp git_root do
    Path.join(
      System.tmp_dir!(),
      "sdd_hosted_local_reconnection_#{System.unique_integer([:positive])}"
    )
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "hosted-local@example.test"])
    git!(path, ["config", "user.name", "Hosted Local"])
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
