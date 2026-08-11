defmodule SddOrchestrator.RepositoryInitialization.StagingWorkspaceTest do
  @moduledoc """
  Task 4 proof: `StagingWorkspace`'s symlink-safe, real-path containment —
  mirrors `Delivery.Worker.Workspace`'s own isolation proof
  (`test/sdd_orchestrator/delivery/worker/isolation_test.exs`), adapted from
  an `ExecutionManifest`'s `project_id`/`run_id` segments to this module's
  own `RepositoryInitialization.Run` id, plus `join/2`'s own path-escape
  guard (used by `StagingBuilder` to place every skeleton and kit file).

  No database is needed: `StagingWorkspace` only ever reads a bare `Run`
  struct's `id`.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.RepositoryInitialization.{Run, StagingWorkspace}

  setup do
    base = Path.join(System.tmp_dir!(), "sdd-staging-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    File.mkdir_p!(root)

    previous = Application.fetch_env(:sdd_orchestrator, :initialization_staging_root)
    Application.put_env(:sdd_orchestrator, :initialization_staging_root, root)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:sdd_orchestrator, :initialization_staging_root, value)

        :error ->
          Application.delete_env(:sdd_orchestrator, :initialization_staging_root)
      end

      File.rm_rf!(base)
    end)

    {:ok, real_root} = StagingWorkspace.root()

    %{base: base, root: root, real_root: real_root, run: %Run{id: Ecto.UUID.generate()}}
  end

  describe "staging directory" do
    test "creates the run's staging directory under the root", context do
      %{run: run, real_root: real_root} = context

      assert {:ok, staging} = StagingWorkspace.prepare(run)
      assert staging == Path.join(real_root, run.id)
      assert File.dir?(staging)
    end

    test "gives another run its own directory", context do
      other = %Run{id: Ecto.UUID.generate()}

      assert {:ok, first} = StagingWorkspace.prepare(context.run)
      assert {:ok, second} = StagingWorkspace.prepare(other)
      refute first == second
    end

    test "is idempotent for the same run", context do
      assert {:ok, first} = StagingWorkspace.prepare(context.run)
      assert {:ok, second} = StagingWorkspace.prepare(context.run)
      assert first == second
    end

    test "staging_path/1 resolves without creating anything", context do
      assert {:ok, path} = StagingWorkspace.staging_path(context.run)
      refute File.dir?(path)
    end

    test "refuses to resolve anything when no root is configured", context do
      Application.delete_env(:sdd_orchestrator, :initialization_staging_root)

      assert {:error, :workspace_root_unconfigured} = StagingWorkspace.prepare(context.run)
      assert {:error, :workspace_root_unconfigured} = StagingWorkspace.staging_path(context.run)
    end

    test "refuses a relative configured root", context do
      Application.put_env(:sdd_orchestrator, :initialization_staging_root, "relative/root")

      assert {:error, :workspace_root_unconfigured} = StagingWorkspace.prepare(context.run)
    end

    test "refuses anything that is not a run" do
      assert {:error, :invalid_run} = StagingWorkspace.prepare(%{"id" => "not-a-run"})
      assert {:error, :invalid_run} = StagingWorkspace.staging_path(nil)
      assert {:error, :invalid_run} = StagingWorkspace.join(%{}, "README.md")
    end

    test "refuses a run whose id is not a UUID" do
      run = %Run{id: "../escape"}

      assert {:error, :workspace_escape} = StagingWorkspace.prepare(run)
      assert {:error, :workspace_escape} = StagingWorkspace.staging_path(run)
    end
  end

  describe "symlink containment" do
    test "refuses a staging directory that is itself a link out of the root", context do
      %{base: base, run: run, root: root} = context
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(root, run.id))

      assert {:error, :workspace_escape} = StagingWorkspace.prepare(run)
      refute File.exists?(Path.join(outside, "README.md"))
    end

    test "accepts a configured root that is itself reached through a link", context do
      %{base: base, run: run, real_root: real_root} = context
      linked_root = Path.join(base, "linked-root")
      File.ln_s!(context.root, linked_root)
      Application.put_env(:sdd_orchestrator, :initialization_staging_root, linked_root)

      assert {:ok, staging} = StagingWorkspace.prepare(run)
      assert staging == Path.join(real_root, run.id)
    end
  end

  describe "join/2" do
    test "resolves a relative path inside the staging directory", context do
      assert {:ok, staging} = StagingWorkspace.prepare(context.run)
      assert {:ok, joined} = StagingWorkspace.join(context.run, "README.md")
      assert joined == Path.join(staging, "README.md")
    end

    test "resolves a nested relative path without creating anything", context do
      assert {:ok, staging} = StagingWorkspace.prepare(context.run)
      assert {:ok, joined} = StagingWorkspace.join(context.run, "scripts/check.sh")
      assert joined == Path.join(staging, "scripts/check.sh")
      refute File.exists?(joined)
    end

    test "refuses a parent-directory segment", context do
      assert {:error, :workspace_escape} = StagingWorkspace.join(context.run, "../escape.txt")
    end

    test "refuses a parent-directory segment buried in a longer path", context do
      assert {:error, :workspace_escape} =
               StagingWorkspace.join(context.run, "nested/../../escape.txt")
    end

    test "refuses an absolute path", context do
      assert {:error, :workspace_escape} = StagingWorkspace.join(context.run, "/etc/passwd")
    end

    test "refuses a blank path", context do
      assert {:error, :workspace_escape} = StagingWorkspace.join(context.run, "")
    end

    test "refuses a path reached only through a link planted inside staging", context do
      %{base: base, run: run} = context
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)

      assert {:ok, staging} = StagingWorkspace.prepare(run)
      File.ln_s!(outside, Path.join(staging, "linked"))

      assert {:error, :workspace_escape} = StagingWorkspace.join(run, "linked/escape.txt")
    end
  end
end
