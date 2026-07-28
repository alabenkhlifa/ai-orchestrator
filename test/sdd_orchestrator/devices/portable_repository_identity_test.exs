defmodule SddOrchestrator.Devices.PortableRepositoryIdentityTest do
  @moduledoc """
  Task 8 proof: portable local repository identities are strict, non-reversible,
  independently salted, exactly matchable without source workspace identity, and
  compatible with explicit original-workspace validation of legacy fingerprints.
  """

  use ExUnit.Case, async: true

  alias SddOrchestrator.Devices.{PortableRepositoryIdentity, RepositoryValidation}

  @workspace_salt "original-workspace-salt"
  @other_workspace_salt "another-workspace-salt"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "portable_repo_identity_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp init_repo!(dir, seed \\ nil) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "portable@example.test"])
    git!(dir, ["config", "user.name", "Portable Identity"])
    File.write!(Path.join(dir, "README.md"), seed || "seed-#{Path.basename(dir)}")
    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "-q", "-m", "root"])
    dir
  end

  defp repository_snapshot(repo) do
    %{
      head: git!(repo, ["rev-parse", "HEAD"]),
      refs: git!(repo, ["show-ref"]),
      remotes: git!(repo, ["remote", "-v"]),
      status: git!(repo, ["status", "--porcelain=v1"])
    }
  end

  test "generates a strict round-trippable identity without forbidden metadata", %{root: root} do
    repo = init_repo!(Path.join(root, "private-repository"))
    root_commit = git!(repo, ["rev-list", "--max-parents=0", "HEAD"])
    before = repository_snapshot(repo)

    assert {:ok, identifier} = PortableRepositoryIdentity.generate(repo)
    assert {:ok, identity} = PortableRepositoryIdentity.parse(identifier)
    assert PortableRepositoryIdentity.encode(identity) == identifier
    assert identity.version == 1
    assert byte_size(identity.validation_salt) == 32
    assert byte_size(identity.digest) == 32

    assert Map.keys(Map.from_struct(identity)) |> Enum.sort() ==
             [:digest, :validation_salt, :version]

    assert String.starts_with?(identifier, "local-repo:v1:")
    refute identifier =~ repo
    refute identifier =~ Path.basename(repo)
    refute identifier =~ root_commit
    refute identifier =~ @workspace_salt
    refute identifier =~ "credential"
    assert repository_snapshot(repo) == before
  end

  test "matches only the exact repository represented by a supplied identity", %{root: root} do
    repository = init_repo!(Path.join(root, "repository"))
    different = init_repo!(Path.join(root, "different"))

    assert {:ok, identifier} = PortableRepositoryIdentity.generate(repository)
    assert {:ok, true} = PortableRepositoryIdentity.match(repository, identifier)
    assert {:ok, false} = PortableRepositoryIdentity.match(different, identifier)
  end

  test "independent generation uses fresh salts and creates unlinkable identities", %{root: root} do
    repository = init_repo!(Path.join(root, "repository"))

    assert {:ok, first_identifier} = PortableRepositoryIdentity.generate(repository)
    assert {:ok, second_identifier} = PortableRepositoryIdentity.generate(repository)
    refute first_identifier == second_identifier

    assert {:ok, first} = PortableRepositoryIdentity.parse(first_identifier)
    assert {:ok, second} = PortableRepositoryIdentity.parse(second_identifier)
    refute first.validation_salt == second.validation_salt
    refute first.digest == second.digest

    assert {:ok, true} = PortableRepositoryIdentity.match(repository, first_identifier)
    assert {:ok, true} = PortableRepositoryIdentity.match(repository, second_identifier)
  end

  test "matches moved repositories, clones, worktrees, and changed remotes", %{root: root} do
    original = init_repo!(Path.join(root, "original"))
    assert {:ok, identifier} = PortableRepositoryIdentity.generate(original)

    moved = Path.join(root, "moved")
    File.rename!(original, moved)
    assert {:ok, true} = PortableRepositoryIdentity.match(moved, identifier)

    clone = Path.join(root, "clone")
    {_, 0} = System.cmd("git", ["clone", "-q", moved, clone], stderr_to_stdout: true)
    git!(clone, ["remote", "set-url", "origin", "https://example.test/changed.git"])
    assert {:ok, true} = PortableRepositoryIdentity.match(clone, identifier)

    worktree = Path.join(root, "worktree")
    git!(moved, ["worktree", "add", "--detach", "-q", worktree, "HEAD"])
    assert {:ok, true} = PortableRepositoryIdentity.match(worktree, identifier)
  end

  test "strictly rejects malformed and unsupported portable identifiers", %{root: root} do
    repository = init_repo!(Path.join(root, "repository"))
    short = Base.url_encode64(:crypto.strong_rand_bytes(31), padding: false)
    valid_size = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    malformed = [
      nil,
      "",
      "local-repo:v2:#{valid_size}:#{valid_size}",
      "local-repo:v1:#{short}:#{valid_size}",
      "local-repo:v1:#{valid_size}:#{short}",
      "local-repo:v1:#{valid_size}:not_base64!",
      "local-repo:v1:#{valid_size}:#{valid_size}:extra",
      "local-repo:v1:#{valid_size}=::#{valid_size}"
    ]

    for identifier <- malformed do
      assert {:error, :invalid_identifier} = PortableRepositoryIdentity.parse(identifier)

      assert {:error, :invalid_identifier} =
               PortableRepositoryIdentity.match(repository, identifier)
    end
  end

  test "recognizes and matches legacy identities only with the original workspace salt", %{
    root: root
  } do
    repository = init_repo!(Path.join(root, "repository"))
    different = init_repo!(Path.join(root, "different"))

    assert {:ok, %{fingerprint: legacy}} =
             RepositoryValidation.validate(repository, @workspace_salt)

    assert PortableRepositoryIdentity.legacy_identifier?(legacy)
    assert {:error, :legacy_identifier} = PortableRepositoryIdentity.parse(legacy)
    assert {:error, :legacy_identifier} = PortableRepositoryIdentity.match(repository, legacy)

    assert {:ok, true} =
             PortableRepositoryIdentity.match_legacy(repository, legacy, @workspace_salt)

    assert {:ok, false} =
             PortableRepositoryIdentity.match_legacy(repository, legacy, @other_workspace_salt)

    assert {:ok, false} =
             PortableRepositoryIdentity.match_legacy(different, legacy, @workspace_salt)

    assert {:error, :invalid_identifier} =
             PortableRepositoryIdentity.match_legacy(
               repository,
               "local-repo:v1:invalid",
               @workspace_salt
             )
  end

  test "portable and legacy matching invoke the constant-time comparison seam", %{root: root} do
    repository = init_repo!(Path.join(root, "repository"))
    assert {:ok, portable} = PortableRepositoryIdentity.generate(repository)

    parent = self()

    compare = fn expected, actual ->
      send(parent, {:secure_compare, expected, actual})
      Plug.Crypto.secure_compare(expected, actual)
    end

    assert {:ok, true} =
             PortableRepositoryIdentity.match_with_compare(repository, portable, compare)

    assert_receive {:secure_compare, portable_expected, portable_actual}
    assert byte_size(portable_expected) == 32
    assert byte_size(portable_actual) == 32

    assert {:ok, %{fingerprint: legacy}} =
             RepositoryValidation.validate(repository, @workspace_salt)

    assert {:ok, true} =
             PortableRepositoryIdentity.match_legacy_with_compare(
               repository,
               legacy,
               @workspace_salt,
               compare
             )

    assert_receive {:secure_compare, legacy_expected, legacy_actual}
    assert byte_size(legacy_expected) == 32
    assert byte_size(legacy_actual) == 32
  end

  test "propagates worker-boundary repository validation failures", %{root: root} do
    plain = Path.join(root, "plain")
    File.mkdir_p!(plain)

    assert {:error, :not_a_git_repository} = PortableRepositoryIdentity.generate(plain)

    assert {:error, :inaccessible} =
             PortableRepositoryIdentity.generate(Path.join(root, "missing"))

    empty = Path.join(root, "empty")
    File.mkdir_p!(empty)
    git!(empty, ["init", "-q"])
    assert {:error, :empty_repository} = PortableRepositoryIdentity.generate(empty)
  end
end
