defmodule SddOrchestrator.RepositoryInitialization.EligibilityTest do
  @moduledoc """
  Task 2 proof (AC-01): classifies an empty directory and an unborn Git
  repository as eligible, and routes a mature repository, a non-empty
  non-Git directory, and an inaccessible path as not eligible without any
  mutation.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.RepositoryInitialization.Eligibility

  describe "classify/1" do
    test "an empty directory is eligible" do
      dir = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, :empty_directory} = Eligibility.classify(dir)
    end

    test "an unborn Git repository (initialized, zero commits) is eligible" do
      dir = unborn_repo_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, :unborn_repository} = Eligibility.classify(dir)
    end

    test "a non-empty, non-Git directory is not eligible" do
      dir = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "notes.txt"), "hello")

      assert {:error, :non_empty_directory} = Eligibility.classify(dir)
    end

    test "an existing-commit (mature) repository is not eligible" do
      dir = git_repo_with_commit_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:error, :mature_repository} = Eligibility.classify(dir)
    end

    test "an inaccessible path is not eligible" do
      path = "/no/such/path/#{System.unique_integer([:positive])}"

      assert {:error, :inaccessible} = Eligibility.classify(path)
    end

    test "never mutates the target" do
      dir = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, :empty_directory} = Eligibility.classify(dir)
      assert {:ok, []} = File.ls(dir)
      refute File.dir?(Path.join(dir, ".git"))
    end
  end

  # ---- helpers ----

  defp empty_dir_fixture do
    dir = Path.join(System.tmp_dir!(), "sdd_eligibility_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp unborn_repo_fixture do
    dir = empty_dir_fixture()
    {_out, 0} = System.cmd("git", ["-C", dir, "init", "--quiet"], stderr_to_stdout: true)
    dir
  end

  defp git_repo_with_commit_fixture do
    dir = unborn_repo_fixture()
    {_out, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@example.com"])
    {_out, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
    File.write!(Path.join(dir, "README.md"), "hello")
    {_out, 0} = System.cmd("git", ["-C", dir, "add", "."], stderr_to_stdout: true)

    {_out, 0} =
      System.cmd("git", ["-C", dir, "commit", "-m", "init", "--quiet"], stderr_to_stdout: true)

    dir
  end
end
