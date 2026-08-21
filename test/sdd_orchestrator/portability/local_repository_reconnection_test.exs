defmodule SddOrchestrator.Portability.LocalRepositoryReconnectionTest do
  @moduledoc """
  Task 21 proof for shared exact worker validation and device-authoritative local
  repository reconnection.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices

  alias SddOrchestrator.Devices.{
    DeviceStore.Local,
    LocalRepositoryValidation,
    Pairing,
    PortableRepositoryIdentity
  }

  alias SddOrchestrator.Devices.LocalRepositoryValidation.Result

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    HostedLocalRepositoryBinding,
    LocalRepositoryReconnection,
    PackageSection,
    ProjectPackage,
    RepositoryReconnection,
    RestoreDecision
  }

  alias SddOrchestrator.Projects.{Project, RepositoryConnection}

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})

    {:ok, authority} = Devices.establish_workspace()
    %{worker: worker, credential: credential} = available_worker(authority.id)
    root = git_root()
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      authority: authority,
      worker: worker,
      credential: credential,
      root: root
    }
  end

  test "shared validation returns only the exact minimized worker result", context do
    repository = init_repo!(Path.join(context.root, "repository"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    parent = self()

    matcher = fn received_id ->
      send(parent, {:matched_identifier, received_id})
      PortableRepositoryIdentity.match(repository, received_id)
    end

    assert {:ok,
            %Result{
              worker_id: worker_id,
              repository_id: ^repository_id,
              validated_at: validated_at
            } = result} =
             LocalRepositoryValidation.validate(
               context.authority,
               context.credential,
               repository_id,
               matcher
             )

    assert worker_id == context.worker.id
    assert %DateTime{} = validated_at
    assert_receive {:matched_identifier, ^repository_id}

    assert result |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [:repository_id, :validated_at, :worker_id]

    refute inspect(result) =~ repository_id
    refute inspect(result) =~ worker_id
    refute Map.has_key?(Map.from_struct(result), :path)
    refute Map.has_key?(Map.from_struct(result), :credential)
    refute Map.has_key?(Map.from_struct(result), :workspace_id)
  end

  test "shared validation rejects malformed, legacy, mismatch, and worker failures", context do
    matcher = fn _repository_id ->
      send(self(), :matcher_called)
      {:ok, true}
    end

    assert {:error, :invalid_repository_identity} =
             LocalRepositoryValidation.validate(
               context.authority,
               context.credential,
               "local-repo:v1:invalid",
               matcher
             )

    legacy = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:error, :legacy_repository_identity} =
             LocalRepositoryValidation.validate(
               context.authority,
               context.credential,
               legacy,
               matcher
             )

    refute_received :matcher_called

    repository_id = portable_identifier()

    assert {:error, :repository_mismatch} =
             LocalRepositoryValidation.validate(
               context.authority,
               context.credential,
               repository_id,
               fn ^repository_id -> {:ok, false} end
             )

    assert {:error, :repository_unavailable} =
             LocalRepositoryValidation.validate(
               context.authority,
               context.credential,
               repository_id,
               fn ^repository_id -> {:error, :inaccessible} end
             )

    assert {:error, :worker_validation_failed} =
             LocalRepositoryValidation.validate(
               context.authority,
               context.credential,
               repository_id,
               fn ^repository_id -> raise "worker transport failed" end
             )
  end

  test "shared validation requires the current active reachable workspace-bound worker",
       context do
    repository_id = portable_identifier()
    matcher = fn ^repository_id -> {:ok, true} end

    assert {:error, :authorization_required} =
             LocalRepositoryValidation.validate(
               context.authority,
               "invalid-credential",
               repository_id,
               matcher
             )

    foreign_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    %{credential: foreign_credential} = available_worker(foreign_workspace.id)

    assert {:error, :authorization_required} =
             LocalRepositoryValidation.validate(
               context.authority,
               foreign_credential,
               repository_id,
               matcher
             )

    %{credential: unavailable_credential} = paired_worker(context.authority.id)

    assert {:error, :worker_unavailable} =
             LocalRepositoryValidation.validate(
               context.authority,
               unavailable_credential,
               repository_id,
               matcher
             )

    assert {:ok, revoked_worker} = Pairing.revoke_worker(context.worker)

    assert {:error, :authorization_required} =
             LocalRepositoryValidation.validate(
               context.authority,
               context.credential,
               repository_id,
               matcher
             )

    assert revoked_worker.state == "revoked"
  end

  test "reconnects an exact device project idempotently without hosted records", context do
    repository = init_repo!(Path.join(context.root, "exact"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    project = restore_device(context.authority, package(repository_id), "local-device-success")
    {:ok, request} = RepositoryReconnection.required(context.authority, project.id)

    matcher = &PortableRepositoryIdentity.match(repository, &1)

    assert {:ok,
            %{
              project_id: project_id,
              repository_provider: "local",
              repository_id: ^repository_id,
              status: :connected
            } = result} =
             LocalRepositoryReconnection.connect(
               context.authority,
               request,
               context.credential,
               matcher
             )

    assert project_id == project.id

    assert result |> Map.keys() |> Enum.sort() ==
             [:project_id, :repository_id, :repository_provider, :status]

    assert {:ok, connected} = Devices.get_project(project.id)
    assert connected.status == "connected"
    assert connected.repository_id == repository_id

    assert {:ok, ^result} =
             LocalRepositoryReconnection.connect(
               context.authority,
               request,
               "not-used-after-success",
               fn _identifier -> raise "not called after success" end
             )

    assert Repo.aggregate(Project, :count) == 0
    assert Repo.aggregate(RepositoryConnection, :count) == 0
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "mismatch and forged requests preserve the disconnected project", context do
    repository = init_repo!(Path.join(context.root, "expected"))
    different = init_repo!(Path.join(context.root, "different"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    project = restore_device(context.authority, package(repository_id), "local-device-mismatch")
    {:ok, request} = RepositoryReconnection.required(context.authority, project.id)

    assert {:error, :repository_mismatch} =
             LocalRepositoryReconnection.connect(
               context.authority,
               request,
               context.credential,
               &PortableRepositoryIdentity.match(different, &1)
             )

    assert {:error, :invalid_request} =
             LocalRepositoryReconnection.connect(
               context.authority,
               %{request | repository_id: portable_identifier()},
               context.credential,
               fn _repository_id -> {:ok, true} end
             )

    assert {:error, :invalid_request} =
             LocalRepositoryReconnection.connect(
               context.authority,
               %{request | method: :github_authorization},
               context.credential,
               fn _repository_id -> {:ok, true} end
             )

    assert {:ok, unchanged} = Devices.get_project(project.id)
    assert unchanged.status == "disconnected"
    assert unchanged.repository_id == repository_id
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "foreign destination, failed authorization, and unavailable worker are non-mutating",
       context do
    repository_id = portable_identifier()

    project =
      restore_device(context.authority, package(repository_id), "local-device-authorization")

    {:ok, request} = RepositoryReconnection.required(context.authority, project.id)
    matcher = fn ^repository_id -> {:ok, true} end

    assert {:error, :destination_unavailable} =
             LocalRepositoryReconnection.connect(
               %DeviceWorkspace{id: Ecto.UUID.generate()},
               request,
               context.credential,
               matcher
             )

    assert {:error, :authorization_required} =
             LocalRepositoryReconnection.connect(
               context.authority,
               request,
               "bad-credential",
               matcher
             )

    %{credential: unavailable_credential} = paired_worker(context.authority.id)

    assert {:error, :worker_unavailable} =
             LocalRepositoryReconnection.connect(
               context.authority,
               request,
               unavailable_credential,
               matcher
             )

    assert {:ok, unchanged} = Devices.get_project(project.id)
    assert unchanged.status == "disconnected"
  end

  test "real exact validation leaves repository content and Git configuration unchanged",
       context do
    repository = init_repo!(Path.join(context.root, "unchanged"))
    git!(repository, ["remote", "add", "origin", "https://example.test/original.git"])
    before = git_snapshot(repository)
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    project = restore_device(context.authority, package(repository_id), "local-device-git-state")
    {:ok, request} = RepositoryReconnection.required(context.authority, project.id)

    assert {:ok, %{status: :connected}} =
             LocalRepositoryReconnection.connect(
               context.authority,
               request,
               context.credential,
               &PortableRepositoryIdentity.match(repository, &1)
             )

    assert git_snapshot(repository) == before

    stored = Devices.get_project(project.id) |> elem(1) |> Map.from_struct()
    refute Map.has_key?(stored, :path)
    refute Map.has_key?(stored, :credential)
    refute inspect(stored) =~ context.credential
    refute inspect(request) =~ repository
    refute inspect(request) =~ context.credential
  end

  defp restore_device(authority, package, idempotency_key) do
    {:ok, %{project: project}} =
      DeviceRestore.restore(authority, package, decision(package),
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
          "name" => "Local reconnect #{System.unique_integer([:positive])}"
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
      checked_boundaries: [:device]
    }
  end

  defp available_worker(workspace_id) do
    %{worker: worker} = pair = paired_worker(workspace_id)
    {:ok, worker} = Pairing.mark_seen(worker)
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

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end

  defp git_root do
    Path.join(
      System.tmp_dir!(),
      "sdd_local_reconnection_#{System.unique_integer([:positive])}"
    )
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "local-reconnect@example.test"])
    git!(path, ["config", "user.name", "Local Reconnect"])
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

  defp store_path do
    dir =
      Path.join(System.tmp_dir!(), "sdd_local_reconnect_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end
end
