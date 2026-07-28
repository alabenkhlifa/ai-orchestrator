defmodule SddOrchestrator.Devices.RepositoryIdentityIntegrationTest do
  @moduledoc """
  Task 9 proof for portable identity onboarding, workspace-authorized duplicate
  comparison, exact Locate recovery, atomic legacy upgrade, race rollback, and
  backup-readiness handoff.
  """

  use ExUnit.Case, async: false

  alias SddOrchestrator.Devices

  alias SddOrchestrator.Devices.{
    DeviceStore.Local,
    PortableRepositoryIdentity,
    RepositoryValidation
  }

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, workspace} = Devices.establish_workspace()

    root =
      Path.join(
        System.tmp_dir!(),
        "repository_identity_integration_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{workspace: workspace, root: root}
  end

  test "new onboarding allocates a portable identity only after workspace duplicate comparison",
       %{
         workspace: workspace,
         root: root
       } do
    repository = init_repo!(Path.join(root, "repository"))

    assert {:ok, %{fingerprint: identity}} =
             Devices.select_repository(repository, workspace)

    assert {:ok, _portable} = PortableRepositoryIdentity.parse(identity)

    assert {:ok, project} =
             Devices.register_project(%{
               name: "Repository",
               repository_fingerprint: identity,
               status: "connected"
             })

    assert {:error, {:repository_already_linked, existing}} =
             Devices.select_repository(repository, workspace)

    assert existing.id == project.id
    assert [^project] = Devices.list_projects()
  end

  test "independent device workspaces allocate unlinkable identities for the same repository", %{
    workspace: first_workspace,
    root: root
  } do
    repository = init_repo!(Path.join(root, "repository"))

    assert {:ok, %{fingerprint: first}} =
             Devices.select_repository(repository, first_workspace)

    stop_supervised!(Local)
    second_path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(second_path)) end)
    start_supervised!({Local, path: second_path})
    {:ok, second_workspace} = Devices.establish_workspace()

    refute second_workspace.id == first_workspace.id

    assert {:ok, %{fingerprint: second}} =
             Devices.select_repository(repository, second_workspace)

    refute second == first
    assert {:ok, true} = PortableRepositoryIdentity.match(repository, first)
    assert {:ok, true} = PortableRepositoryIdentity.match(repository, second)
  end

  test "portable Locate recovery matches exactly without replacing the identity", %{
    workspace: workspace,
    root: root
  } do
    repository = init_repo!(Path.join(root, "repository"))
    {:ok, %{fingerprint: identity}} = Devices.select_repository(repository, workspace)

    {:ok, project} =
      Devices.register_project(%{
        name: "Portable",
        repository_fingerprint: identity,
        status: "connected"
      })

    assert {:ok, %{project: same, upgraded?: false}} =
             Devices.locate_repository(repository, project, workspace)

    assert same.id == project.id
    assert same.repository_fingerprint == identity
    assert Devices.repository_backup_readiness(same) == :backup_ready
  end

  test "exact source-side Locate atomically upgrades a legacy identity", %{
    workspace: workspace,
    root: root
  } do
    repository = init_repo!(Path.join(root, "repository"))
    before = repository_snapshot(repository)
    {:ok, %{fingerprint: legacy}} = RepositoryValidation.validate(repository, workspace.id)

    {:ok, project} =
      Devices.register_project(%{
        name: "Legacy",
        repository_fingerprint: legacy,
        status: "connected"
      })

    assert Devices.repository_backup_readiness(project) == :upgrade_required

    assert {:ok, %{project: upgraded, upgraded?: true}} =
             Devices.locate_repository(repository, project, workspace)

    assert upgraded.id == project.id
    assert upgraded.name == project.name
    assert upgraded.status == project.status
    refute upgraded.repository_fingerprint == legacy
    assert {:ok, _portable} = PortableRepositoryIdentity.parse(upgraded.repository_fingerprint)
    assert Devices.repository_backup_readiness(upgraded) == :backup_ready
    assert {:ok, ^upgraded} = Devices.get_project(project.id)
    assert repository_snapshot(repository) == before
  end

  test "legacy mismatch and unavailable source preserve the existing connection", %{
    workspace: workspace,
    root: root
  } do
    repository = init_repo!(Path.join(root, "repository"))
    different = init_repo!(Path.join(root, "different"))
    {:ok, %{fingerprint: legacy}} = RepositoryValidation.validate(repository, workspace.id)

    {:ok, project} =
      Devices.register_project(%{
        name: "Legacy",
        repository_fingerprint: legacy,
        status: "connected"
      })

    assert {:error, :repository_mismatch} =
             Devices.locate_repository(different, project, workspace)

    assert {:ok, unchanged} = Devices.get_project(project.id)
    assert unchanged.repository_fingerprint == legacy

    assert {:error, :inaccessible} =
             Devices.locate_repository(Path.join(root, "missing"), project, workspace)

    assert {:ok, still_unchanged} = Devices.get_project(project.id)
    assert still_unchanged.repository_fingerprint == legacy
    assert Devices.repository_backup_readiness(still_unchanged) == :upgrade_required
  end

  test "a uniqueness race rolls back the legacy upgrade", %{
    workspace: workspace,
    root: root
  } do
    repository = init_repo!(Path.join(root, "repository"))
    {:ok, %{fingerprint: legacy}} = RepositoryValidation.validate(repository, workspace.id)

    {:ok, project} =
      Devices.register_project(%{
        name: "Legacy",
        repository_fingerprint: legacy,
        status: "connected"
      })

    before_replace = fn replacement_identity ->
      assert {:ok, _raced_project} =
               Devices.register_project(%{
                 name: "Concurrent",
                 repository_fingerprint: replacement_identity,
                 status: "connected"
               })

      :ok
    end

    assert {:error, :identity_race} =
             Devices.locate_repository_with_hook(
               repository,
               project,
               workspace,
               before_replace
             )

    assert {:ok, unchanged} = Devices.get_project(project.id)
    assert unchanged.repository_fingerprint == legacy
    assert Devices.repository_backup_readiness(unchanged) == :upgrade_required
  end

  defp init_repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "identity@example.test"])
    git!(dir, ["config", "user.name", "Identity Integration"])
    File.write!(Path.join(dir, "README.md"), "seed-#{Path.basename(dir)}")
    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "-q", "-m", "root"])
    dir
  end

  defp repository_snapshot(repository) do
    %{
      head: git!(repository, ["rev-parse", "HEAD"]),
      refs: git!(repository, ["show-ref"]),
      remotes: git!(repository, ["remote", "-v"]),
      status: git!(repository, ["status", "--porcelain=v1"])
    }
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "identity_store_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
