defmodule SddOrchestrator.Devices.RepositoryValidationTest do
  @moduledoc """
  Task 4 proof: on-worker validation of a local Git repository and a canonical
  fingerprint that is path-, clone-, and remote-independent, workspace-scoped,
  distinguishes unrelated repositories, and exposes no source or path metadata.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Devices.RepositoryValidation

  @salt "workspace-salt-a"
  @other_salt "workspace-salt-b"

  setup do
    root = Path.join(System.tmp_dir!(), "repo_val_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp init_repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "t@example.test"])
    git!(dir, ["config", "user.name", "Tester"])
    # A distinct initial blob gives each repo a distinct root commit, mirroring
    # how genuinely unrelated repositories differ. Content is path-independent, so
    # a moved repository keeps its committed blob and therefore its fingerprint.
    File.write!(Path.join(dir, "README.md"), "seed-#{Path.basename(dir)}")
    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "-q", "-m", "root"])
    dir
  end

  test "returns a fingerprint for a valid repository and exposes no path or source", %{root: root} do
    repo = init_repo!(Path.join(root, "repo"))

    assert {:ok, result} = RepositoryValidation.validate(repo, @salt)
    assert Map.keys(result) == [:fingerprint]
    assert is_binary(result.fingerprint)
    refute result.fingerprint =~ root
  end

  test "rejects a directory that is not a Git repository", %{root: root} do
    plain = Path.join(root, "plain")
    File.mkdir_p!(plain)
    assert {:error, :not_a_git_repository} = RepositoryValidation.validate(plain, @salt)
  end

  test "reports an inaccessible path" do
    assert {:error, :inaccessible} =
             RepositoryValidation.validate("/no/such/path/#{System.unique_integer()}", @salt)
  end

  test "reports an empty repository with no commits", %{root: root} do
    empty = Path.join(root, "empty")
    File.mkdir_p!(empty)
    git!(empty, ["init", "-q"])
    assert {:error, :empty_repository} = RepositoryValidation.validate(empty, @salt)
  end

  test "keeps the same fingerprint after the repository is moved", %{root: root} do
    repo = init_repo!(Path.join(root, "before"))
    {:ok, %{fingerprint: before}} = RepositoryValidation.validate(repo, @salt)

    moved = Path.join(root, "after")
    File.rename!(repo, moved)

    assert {:ok, %{fingerprint: ^before}} = RepositoryValidation.validate(moved, @salt)
  end

  test "keeps the same fingerprint for a clone and after a remote change", %{root: root} do
    repo = init_repo!(Path.join(root, "origin"))
    {:ok, %{fingerprint: original}} = RepositoryValidation.validate(repo, @salt)

    clone = Path.join(root, "clone")
    {_, 0} = System.cmd("git", ["clone", "-q", repo, clone], stderr_to_stdout: true)
    assert {:ok, %{fingerprint: ^original}} = RepositoryValidation.validate(clone, @salt)

    git!(clone, ["remote", "set-url", "origin", "https://example.test/other.git"])
    assert {:ok, %{fingerprint: ^original}} = RepositoryValidation.validate(clone, @salt)
  end

  test "distinguishes unrelated repositories", %{root: root} do
    one = init_repo!(Path.join(root, "one"))
    two = init_repo!(Path.join(root, "two"))

    {:ok, %{fingerprint: fp_one}} = RepositoryValidation.validate(one, @salt)
    {:ok, %{fingerprint: fp_two}} = RepositoryValidation.validate(two, @salt)

    refute fp_one == fp_two
  end

  test "scopes the fingerprint to the workspace salt", %{root: root} do
    repo = init_repo!(Path.join(root, "repo"))

    {:ok, %{fingerprint: in_a}} = RepositoryValidation.validate(repo, @salt)
    {:ok, %{fingerprint: in_b}} = RepositoryValidation.validate(repo, @other_salt)

    refute in_a == in_b
  end
end
