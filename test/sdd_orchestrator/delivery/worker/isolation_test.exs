defmodule SddOrchestrator.Delivery.Worker.IsolationTest.RepositoryDouble do
  @moduledoc false

  @behaviour SddOrchestrator.Delivery.Worker.Branch.Repository

  @empty %{revisions: %{}, branches: [], created: [], checked_out: nil, failure: nil}

  def install(overrides \\ %{}) do
    Process.put(__MODULE__, Map.merge(@empty, overrides))
    __MODULE__
  end

  def state, do: Process.get(__MODULE__)

  @impl true
  def resolve_revision(_directory, revision) do
    case Map.fetch(state().revisions, revision) do
      {:ok, resolved} -> {:ok, resolved}
      :error -> {:error, :unknown_revision}
    end
  end

  @impl true
  def branch_exists?(_directory, name) do
    if state().failure == :branch_exists do
      {:error, :repository_unavailable}
    else
      {:ok, name in state().branches}
    end
  end

  @impl true
  def create_branch(_directory, name, revision) do
    update(fn current ->
      %{
        current
        | branches: [name | current.branches],
          created: current.created ++ [{name, revision}]
      }
    end)
  end

  @impl true
  def checkout(_directory, name) do
    update(fn current -> %{current | checked_out: name} end)
  end

  defp update(fun) do
    Process.put(__MODULE__, fun.(state()))
    :ok
  end
end

defmodule SddOrchestrator.Delivery.Worker.IsolationTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.Worker.Branch
  alias SddOrchestrator.Delivery.Worker.IsolationTest.RepositoryDouble
  alias SddOrchestrator.Delivery.Worker.ProcessLock
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryProtocolFixtures, as: Fixtures

  @base_revision "9f2c1ab4d5e6f708192a3b4c5d6e7f8091a2b3c4"
  @target_branch "sdd/feature/ftr-0002/run-0003"

  setup do
    base = Path.join(System.tmp_dir!(), "sdd-worker-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    File.mkdir_p!(root)

    previous = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
    Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_workspace_root, value)
        :error -> Application.delete_env(:sdd_orchestrator, :worker_workspace_root)
      end

      File.rm_rf!(base)
    end)

    {:ok, real_root} = Workspace.root()

    %{base: base, root: root, real_root: real_root, manifest: Fixtures.manifest()}
  end

  describe "run workspace" do
    test "creates the run workspace and its repository directory under the root", context do
      %{manifest: manifest, real_root: real_root} = context

      assert {:ok, workspace} = Workspace.prepare(manifest)
      assert workspace == Path.join([real_root, manifest.project_id, manifest.run_id])
      assert File.dir?(workspace)
      assert File.dir?(Path.join(workspace, "repository"))
    end

    test "resolves the same workspace for a later attempt of the same run", context do
      retry =
        Fixtures.manifest(%{
          "attempt_number" => 2,
          "continuation" => %{"reason" => "manual_retry", "prior_attempt_number" => 1}
        })

      assert {:ok, first} = Workspace.prepare(context.manifest)
      assert {:ok, second} = Workspace.prepare(retry)
      assert first == second
    end

    test "gives another run its own directory", context do
      other = Fixtures.manifest(%{"run_id" => "run_01HZX0000000000000000099"})

      assert {:ok, first} = Workspace.prepare(context.manifest)
      assert {:ok, second} = Workspace.prepare(other)
      refute first == second
    end

    test "refuses to resolve anything when no root is configured", context do
      Application.delete_env(:sdd_orchestrator, :worker_workspace_root)

      assert {:error, :workspace_root_unconfigured} = Workspace.prepare(context.manifest)

      assert {:error, :workspace_root_unconfigured} =
               Workspace.working_directory(context.manifest)
    end

    test "refuses a relative configured root", context do
      Application.put_env(:sdd_orchestrator, :worker_workspace_root, "relative/root")

      assert {:error, :workspace_root_unconfigured} = Workspace.prepare(context.manifest)
    end

    test "refuses anything that is not a manifest" do
      assert {:error, :invalid_manifest} = Workspace.prepare(%{"run_id" => "run_1"})
      assert {:error, :invalid_manifest} = Workspace.working_directory(nil)
    end
  end

  describe "traversal denial" do
    test "refuses a parent-directory segment", context do
      escaping = tampered(context.manifest, run_id: "..")

      assert {:error, :workspace_escape} = Workspace.prepare(escaping)
    end

    test "refuses a segment that climbs out of the root", context do
      escaping = tampered(context.manifest, run_id: "../../escaped")

      assert {:error, :workspace_escape} = Workspace.prepare(escaping)
      refute File.dir?(Path.join(context.base, "escaped"))
    end

    test "refuses an absolute segment", context do
      escaping = tampered(context.manifest, project_id: "/etc")

      assert {:error, :workspace_escape} = Workspace.prepare(escaping)
    end

    test "refuses a segment carrying its own separator", context do
      escaping = tampered(context.manifest, run_id: "run/nested")

      assert {:error, :workspace_escape} = Workspace.prepare(escaping)
    end
  end

  describe "symlink containment" do
    test "refuses a run path whose parent links outside the root", context do
      %{base: base, manifest: manifest, root: root} = context
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(root, manifest.project_id))

      assert {:error, :workspace_escape} = Workspace.prepare(manifest)
      assert {:error, :workspace_escape} = Workspace.working_directory(manifest)
      refute File.dir?(Path.join(outside, manifest.run_id))
    end

    test "refuses a run workspace that is itself a link out of the root", context do
      %{base: base, manifest: manifest, root: root} = context
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      File.mkdir_p!(Path.join(root, manifest.project_id))
      File.ln_s!(outside, Path.join([root, manifest.project_id, manifest.run_id]))

      assert {:error, :workspace_escape} = Workspace.prepare(manifest)
      refute File.dir?(Path.join(outside, "repository"))
    end

    test "refuses a repository directory linked out of the root", context do
      %{base: base, manifest: manifest} = context
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)

      assert {:ok, workspace} = Workspace.prepare(manifest)
      File.rm_rf!(Path.join(workspace, "repository"))
      File.ln_s!(outside, Path.join(workspace, "repository"))

      assert {:error, :workspace_escape} = Workspace.prepare(manifest)
      assert {:error, :workspace_escape} = Workspace.working_directory(manifest)
    end

    test "accepts a configured root that is itself reached through a link", context do
      %{base: base, manifest: manifest, real_root: real_root} = context
      linked_root = Path.join(base, "linked-root")
      File.ln_s!(context.root, linked_root)
      Application.put_env(:sdd_orchestrator, :worker_workspace_root, linked_root)

      assert {:ok, workspace} = Workspace.prepare(manifest)
      assert workspace == Path.join([real_root, manifest.project_id, manifest.run_id])
    end
  end

  describe "process working directory" do
    test "is the repository directory inside the run workspace", context do
      assert {:ok, workspace} = Workspace.prepare(context.manifest)
      assert {:ok, directory} = Workspace.working_directory(context.manifest)
      assert directory == Path.join(workspace, "repository")
    end

    test "does not create anything by being asked", context do
      assert {:ok, directory} = Workspace.working_directory(context.manifest)
      refute File.dir?(directory)
    end

    test "accepts the exact directory and an equivalent spelling", context do
      assert {:ok, _workspace} = Workspace.prepare(context.manifest)
      assert {:ok, directory} = Workspace.working_directory(context.manifest)

      assert :ok = Workspace.ensure_working_directory(context.manifest, directory)
      assert :ok = Workspace.ensure_working_directory(context.manifest, directory <> "/")
      assert :ok = Workspace.ensure_working_directory(context.manifest, directory <> "/./")
    end

    test "refuses the run workspace, a subdirectory, and an unrelated directory", context do
      assert {:ok, workspace} = Workspace.prepare(context.manifest)
      assert {:ok, directory} = Workspace.working_directory(context.manifest)
      nested = Path.join(directory, "nested")
      File.mkdir_p!(nested)

      assert {:error, :workspace_escape} =
               Workspace.ensure_working_directory(context.manifest, workspace)

      assert {:error, :workspace_escape} =
               Workspace.ensure_working_directory(context.manifest, nested)

      assert {:error, :workspace_escape} =
               Workspace.ensure_working_directory(context.manifest, context.base)

      assert {:error, :workspace_escape} =
               Workspace.ensure_working_directory(context.manifest, :not_a_path)
    end

    test "refuses a directory that only reaches the run through a link", context do
      assert {:ok, _workspace} = Workspace.prepare(context.manifest)
      impostor = Path.join(context.base, "impostor")
      File.ln_s!(context.base, impostor)

      assert {:error, :workspace_escape} =
               Workspace.ensure_working_directory(context.manifest, Path.join(impostor, "root"))
    end
  end

  describe "isolated branch" do
    test "creates the manifest branch from the resolved base revision", context do
      repository = RepositoryDouble.install(%{revisions: %{@base_revision => @base_revision}})

      assert {:ok, branch} = Branch.prepare(context.manifest, repository: repository)
      assert branch.name == @target_branch
      assert branch.run_id == context.manifest.run_id
      assert branch.base_revision == @base_revision
      refute branch.reused?

      assert {:ok, directory} = Workspace.working_directory(context.manifest)
      assert branch.working_directory == directory
      assert RepositoryDouble.state().created == [{@target_branch, @base_revision}]
      assert RepositoryDouble.state().checked_out == @target_branch
    end

    test "reuses the same branch on a later attempt instead of creating it again", context do
      repository = RepositoryDouble.install(%{revisions: %{@base_revision => @base_revision}})

      assert {:ok, created} = Branch.prepare(context.manifest, repository: repository)
      refute created.reused?

      retry =
        Fixtures.manifest(%{
          "attempt_number" => 2,
          "continuation" => %{"reason" => "automatic_retry", "prior_attempt_number" => 1}
        })

      assert {:ok, reused} = Branch.prepare(retry, repository: repository)
      assert reused.reused?
      assert reused.name == created.name
      assert RepositoryDouble.state().created == [{@target_branch, @base_revision}]
    end

    test "refuses the default branch by any spelling" do
      repository = RepositoryDouble.install(%{revisions: %{@base_revision => @base_revision}})

      for name <- ["main", "master", "MAIN", "refs/heads/main", "HEAD"] do
        manifest = Fixtures.manifest(%{"target_branch" => name})

        assert {:error, :default_branch_forbidden} =
                 Branch.prepare(manifest, repository: repository)
      end

      assert RepositoryDouble.state().created == []
    end

    test "refuses a different branch for the same run", context do
      repository = RepositoryDouble.install(%{revisions: %{@base_revision => @base_revision}})

      assert {:ok, _branch} = Branch.prepare(context.manifest, repository: repository)

      renamed = Fixtures.manifest(%{"target_branch" => "sdd/feature/ftr-0002/run-9999"})

      assert {:error, :branch_conflict} = Branch.prepare(renamed, repository: repository)
      assert RepositoryDouble.state().created == [{@target_branch, @base_revision}]
    end

    test "refuses a branch the manifest's own rules reject" do
      repository = RepositoryDouble.install(%{revisions: %{@base_revision => @base_revision}})
      manifest = tampered(Fixtures.manifest(), target_branch: "sdd/../escape")

      assert {:error, :invalid_manifest} = Branch.prepare(manifest, repository: repository)
      assert RepositoryDouble.state().created == []
    end

    test "refuses a manifest whose identity was altered", context do
      repository = RepositoryDouble.install(%{revisions: %{@base_revision => @base_revision}})
      manifest = tampered(context.manifest, run_id: "../escape")

      assert {:error, :invalid_manifest} = Branch.prepare(manifest, repository: repository)
    end

    test "refuses anything that is not a manifest" do
      assert {:error, :invalid_manifest} = Branch.prepare(%{"run_id" => "run_1"})
    end

    test "reports a repository it cannot reach", context do
      repository =
        RepositoryDouble.install(%{
          revisions: %{@base_revision => @base_revision},
          failure: :branch_exists
        })

      assert {:error, :repository_unavailable} =
               Branch.prepare(context.manifest, repository: repository)
    end

    test "defaults to the installed git boundary" do
      assert Branch.repository() == SddOrchestrator.Delivery.Worker.Branch.Repository.Git
    end
  end

  describe "base revision validation" do
    test "accepts an abbreviated revision that prefixes the repository revision" do
      repository = RepositoryDouble.install(%{revisions: %{"9f2c1ab" => @base_revision}})
      manifest = Fixtures.manifest(%{"repository_base_revision" => "9f2c1ab"})

      assert {:ok, branch} = Branch.prepare(manifest, repository: repository)
      assert branch.base_revision == @base_revision
      assert RepositoryDouble.state().created == [{@target_branch, @base_revision}]
    end

    test "refuses a repository resolving a different revision", context do
      other = "1111111111111111111111111111111111111111"
      repository = RepositoryDouble.install(%{revisions: %{@base_revision => other}})

      assert {:error, :base_revision_mismatch} =
               Branch.prepare(context.manifest, repository: repository)

      assert RepositoryDouble.state().created == []
    end

    test "refuses a revision the repository does not have", context do
      repository = RepositoryDouble.install(%{})

      assert {:error, :base_revision_mismatch} =
               Branch.prepare(context.manifest, repository: repository)

      assert RepositoryDouble.state().created == []
      assert RepositoryDouble.state().checked_out == nil
    end
  end

  describe "one current process" do
    test "records the holder and its fence token in the run workspace", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1)
      assert lock.run_id == context.manifest.run_id
      assert lock.fence_token == 1
      assert lock.os_pid == System.pid()
      assert File.exists?(Path.join(lock.workspace, "run.lock"))
    end

    test "refuses a second live holder at the same fence", context do
      assert {:ok, _lock} = ProcessLock.acquire(context.manifest, 1, os_pid: "4001")

      assert {:error, :locked} =
               ProcessLock.acquire(context.manifest, 1,
                 os_pid: "4002",
                 alive?: fn _pid -> true end
               )
    end

    test "lets the same process reclaim its own lock", context do
      assert {:ok, first} = ProcessLock.acquire(context.manifest, 1)
      assert {:ok, second} = ProcessLock.acquire(context.manifest, 1)
      assert second.fence_token == first.fence_token
    end

    test "lets a higher fence token take over from a live holder", context do
      assert {:ok, _held} =
               ProcessLock.acquire(context.manifest, 1, os_pid: "4001")

      assert {:ok, fenced} =
               ProcessLock.acquire(context.manifest, 2,
                 os_pid: "4002",
                 alive?: fn _pid -> true end
               )

      assert fenced.fence_token == 2
      assert fenced.os_pid == "4002"
    end

    test "never lets a lower fence token take over, even from a dead holder", context do
      assert {:ok, _held} = ProcessLock.acquire(context.manifest, 5, os_pid: "4001")

      assert {:error, :fenced} =
               ProcessLock.acquire(context.manifest, 4,
                 os_pid: "4002",
                 alive?: fn _pid -> false end
               )
    end

    test "refuses an invalid fence token or target", context do
      assert {:error, :invalid_fence_token} = ProcessLock.acquire(context.manifest, 0)
      assert {:error, :invalid_fence_token} = ProcessLock.acquire(context.manifest, "1")
      assert {:error, :invalid_manifest} = ProcessLock.acquire(%{}, 1)
    end

    test "releases only for the holder that owns the lock", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1, os_pid: "4001")

      assert {:ok, fenced} = ProcessLock.acquire(context.manifest, 2, os_pid: "4002")
      assert {:error, :fenced} = ProcessLock.release(lock)
      assert File.exists?(Path.join(lock.workspace, "run.lock"))

      assert :ok = ProcessLock.release(fenced)
      refute File.exists?(Path.join(lock.workspace, "run.lock"))

      assert {:ok, reacquired} = ProcessLock.acquire(context.manifest, 1, os_pid: "4003")
      assert reacquired.fence_token == 1
    end

    test "refuses to act on a lock record it cannot read", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1)
      File.write!(Path.join(lock.workspace, "run.lock"), "not json")

      assert {:error, :lock_unreadable} = ProcessLock.acquire(context.manifest, 9)
      assert {:error, :lock_unreadable} = ProcessLock.release(lock)
      refute ProcessLock.stale?(lock)
    end
  end

  describe "stale process reclaim" do
    test "reclaims a lock whose recorded process is gone", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1, os_pid: "4001")
      gone = fn _pid -> false end

      assert ProcessLock.stale?(lock, alive?: gone)

      assert {:ok, reclaimed} =
               ProcessLock.acquire(context.manifest, 1, os_pid: "4002", alive?: gone)

      assert reclaimed.os_pid == "4002"
    end

    test "does not reclaim a live holder", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1, os_pid: "4001")
      live = fn _pid -> true end

      refute ProcessLock.stale?(lock, alive?: live)
    end

    test "treats a released lock as reclaimable", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1)
      assert :ok = ProcessLock.release(lock)

      assert ProcessLock.stale?(lock, alive?: fn _pid -> true end)
    end

    test "the real liveness probe sees this process and not an exited one", context do
      assert {:ok, running} = ProcessLock.acquire(context.manifest, 1)
      refute ProcessLock.stale?(running)

      {output, 0} = System.cmd("sh", ["-c", "echo $$"])
      exited = String.trim(output)

      assert {:ok, gone} = ProcessLock.acquire(context.manifest, 2, os_pid: exited)
      assert ProcessLock.stale?(gone)
    end
  end

  describe "cancellation stop seam" do
    test "a stop request is visible to the current holder", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1)
      refute ProcessLock.stop_requested?(lock)

      assert :ok = ProcessLock.request_stop(context.manifest)
      assert ProcessLock.stop_requested?(lock)
    end

    test "a holder can record its own stop request", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1)

      assert :ok = ProcessLock.request_stop(lock)
      assert ProcessLock.stop_requested?(lock)
    end

    test "releasing the lock clears the stop request", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1)
      assert :ok = ProcessLock.request_stop(lock)
      assert :ok = ProcessLock.release(lock)

      assert {:ok, next} = ProcessLock.acquire(context.manifest, 1)
      refute ProcessLock.stop_requested?(next)
    end

    test "a superseded stop request does not stop the attempt that replaced it", context do
      assert {:ok, held} = ProcessLock.acquire(context.manifest, 1, os_pid: "4001")
      assert :ok = ProcessLock.request_stop(held)

      assert {:ok, fenced} = ProcessLock.acquire(context.manifest, 2, os_pid: "4002")
      refute ProcessLock.stop_requested?(fenced)
    end

    test "a stop request recorded against no holder stops whoever runs next", context do
      assert :ok = ProcessLock.request_stop(context.manifest)

      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 7)
      assert ProcessLock.stop_requested?(lock)
    end

    test "an unreadable stop request still stops the holder", context do
      assert {:ok, lock} = ProcessLock.acquire(context.manifest, 1)
      File.write!(Path.join(lock.workspace, "run.stop"), "not json")

      assert ProcessLock.stop_requested?(lock)
    end

    test "refuses a stop request for anything that is not a run", %{manifest: _manifest} do
      assert {:error, :invalid_manifest} = ProcessLock.request_stop(%{"run_id" => "run_1"})
    end
  end

  if System.find_executable("git") do
    describe "repository fixture" do
      setup context do
        assert {:ok, _workspace} = Workspace.prepare(context.manifest)
        assert {:ok, directory} = Workspace.working_directory(context.manifest)

        git!(directory, ["init", "--quiet"])
        git!(directory, ["commit", "--allow-empty", "--quiet", "--message", "base"])
        revision = git!(directory, ["rev-parse", "HEAD"])

        %{directory: directory, revision: revision}
      end

      test "creates and then reuses the run branch in a real repository", context do
        manifest = Fixtures.manifest(%{"repository_base_revision" => context.revision})

        assert {:ok, created} =
                 Branch.prepare(manifest,
                   repository: SddOrchestrator.Delivery.Worker.Branch.Repository.Git
                 )

        refute created.reused?
        assert created.name == @target_branch
        assert created.base_revision == context.revision
        assert git!(context.directory, ["rev-parse", "--abbrev-ref", "HEAD"]) == @target_branch
        assert git!(context.directory, ["rev-parse", @target_branch]) == context.revision

        assert {:ok, reused} =
                 Branch.prepare(manifest,
                   repository: SddOrchestrator.Delivery.Worker.Branch.Repository.Git
                 )

        assert reused.reused?
        assert reused.name == created.name
      end

      test "refuses a base revision the real repository does not have", context do
        manifest =
          Fixtures.manifest(%{
            "repository_base_revision" => "1111111111111111111111111111111111111111"
          })

        assert {:error, :base_revision_mismatch} =
                 Branch.prepare(manifest,
                   repository: SddOrchestrator.Delivery.Worker.Branch.Repository.Git
                 )

        refute git!(context.directory, ["branch", "--list", @target_branch]) =~ @target_branch
      end

      test "accepts the abbreviated revision of a real commit", context do
        abbreviated = String.slice(context.revision, 0, 10)
        manifest = Fixtures.manifest(%{"repository_base_revision" => abbreviated})

        assert {:ok, branch} =
                 Branch.prepare(manifest,
                   repository: SddOrchestrator.Delivery.Worker.Branch.Repository.Git
                 )

        assert branch.base_revision == context.revision
      end
    end
  else
    test "the real repository proof needs git" do
      flunk("environment blocker: no git executable, so the repository fixture cannot be proven")
    end
  end

  # A worker must not trust a manifest merely because a control plane validated
  # one, so these proofs hand it values no accepted manifest could carry.
  defp tampered(%ExecutionManifest{} = manifest, changes), do: struct!(manifest, changes)

  defp git!(directory, args) do
    identity = [
      "-c",
      "user.name=SDD Orchestrator Test",
      "-c",
      "user.email=test@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "init.defaultBranch=base"
    ]

    {output, 0} = System.cmd("git", identity ++ args, cd: directory, stderr_to_stdout: true)
    String.trim(output)
  end
end
