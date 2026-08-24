defmodule SddOrchestrator.Portability.HostedLocalRepositoryFolderTest do
  @moduledoc """
  Task 7 proof for pointing the selected machine at the repository folder.

  The owner names the folder; the machine never searches for it. The chosen path
  is held only in the returned proof's closure, so nothing that crosses back to
  the control plane can carry a path, remote URL, filename, or Git object.
  """

  use ExUnit.Case, async: true

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Portability.HostedLocalRepositoryFolder

  setup do
    root = git_root()
    on_exit(fn -> File.rm_rf!(root) end)

    repository = init_repo!(Path.join(root, "chosen-folder"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)

    %{root: root, repository: repository, repository_id: repository_id}
  end

  test "a selected folder yields a proof of the project-held identity only", context do
    assert {:ok, proof} = HostedLocalRepositoryFolder.select(picker: picker(context.repository))

    assert is_function(proof, 1)
    assert proof.(context.repository_id) == {:ok, true}

    {:ok, other_id} =
      context.root |> Path.join("other") |> init_repo!() |> PortableRepositoryIdentity.generate()

    assert proof.(other_id) == {:ok, false}
  end

  test "the chosen path never leaves the device", context do
    assert {:ok, proof} = HostedLocalRepositoryFolder.select(picker: picker(context.repository))

    refute inspect(proof) =~ context.repository
    refute inspect(proof) =~ Path.basename(context.repository)
    refute inspect(proof) =~ "README"

    verdict = proof.(context.repository_id)
    assert verdict == {:ok, true}

    rendered = inspect(verdict)
    refute rendered =~ context.repository
    refute rendered =~ "README"
    refute rendered =~ "example.test"
  end

  test "a cancelled selection attempts no connection and stores nothing", context do
    assert {:error, :cancelled} =
             HostedLocalRepositoryFolder.select(picker: fn -> :cancelled end)

    assert {:error, :picker_unavailable} =
             HostedLocalRepositoryFolder.select(picker: fn -> :unavailable end)

    assert File.dir?(context.repository)
  end

  test "a folder that is not a Git repository is refused at selection", context do
    plain = Path.join(context.root, "plain-folder")
    File.mkdir_p!(plain)

    assert {:error, :not_a_git_repository} =
             HostedLocalRepositoryFolder.select(picker: picker(plain))

    missing = Path.join(context.root, "does-not-exist")

    assert {:error, :repository_unavailable} =
             HostedLocalRepositoryFolder.select(picker: picker(missing))

    empty = init_bare_repo!(Path.join(context.root, "empty-repository"))

    assert {:error, :repository_unavailable} =
             HostedLocalRepositoryFolder.select(picker: picker(empty))
  end

  test "selecting and proving never writes to the repository", context do
    before = git_snapshot(context.repository)

    assert {:ok, proof} = HostedLocalRepositoryFolder.select(picker: picker(context.repository))
    assert proof.(context.repository_id) == {:ok, true}

    {:ok, unrelated_id} =
      context.root
      |> Path.join("unrelated")
      |> init_repo!()
      |> PortableRepositoryIdentity.generate()

    assert proof.(unrelated_id) == {:ok, false}
    assert git_snapshot(context.repository) == before
  end

  test "a repository that disappears after selection is reported, never matched", context do
    disposable = init_repo!(Path.join(context.root, "disposable"))
    {:ok, disposable_id} = PortableRepositoryIdentity.generate(disposable)

    assert {:ok, proof} = HostedLocalRepositoryFolder.select(picker: picker(disposable))
    assert proof.(disposable_id) == {:ok, true}

    File.rm_rf!(disposable)

    assert {:error, :inaccessible} = proof.(disposable_id)
  end

  test "the default picker follows the established worker stand-in seam" do
    assert HostedLocalRepositoryFolder.picker_available?() ==
             Application.get_env(:sdd_orchestrator, :device_worker_stub, false)
  end

  defp picker(path), do: fn -> {:ok, path} end

  defp git_root do
    Path.join(
      System.tmp_dir!(),
      "sdd_hosted_local_folder_#{System.unique_integer([:positive])}"
    )
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "folder-selection@example.test"])
    git!(path, ["config", "user.name", "Folder Selection"])
    File.write!(Path.join(path, "README.md"), "unchanged #{Path.basename(path)}")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-q", "-m", "initial"])
    path
  end

  defp init_bare_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
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
