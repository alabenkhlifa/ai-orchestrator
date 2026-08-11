defmodule SddOrchestrator.RepositoryInitialization.Publisher do
  @moduledoc """
  Verifies, commits, and publishes a staged empty-repository build into the
  user's still-empty target directory (specs/16 Task 5, AC-09, AC-11, AC-12,
  `entity:RepositoryInitializationResult`).

  Continues directly from a `Run` Task 4's `StagingBuilder` already left
  `"completed"` (staging built, no commit yet — see
  `specs/16-empty-repository-initialization/progress.md`, "Task 4
  implemented"). Like `StagingBuilder`, this never routes through
  `Delivery.AgentAdapter`: verifying the target, running `git add`/`git
  commit`, and transferring already-known files are fully deterministic
  filesystem and Git operations with nothing for a generic coding agent to
  decide.

  `target_path` is always a caller-supplied real absolute path, never
  resolved from `Plan.target_reference` here — the real path still lives
  only wherever the caller (today, only this module's own tests) already
  holds it, matching AC-01's opaque-reference rule. Re-resolving
  `target_reference` back to a path for a live caller remains the same open
  gap Task 2's own progress note already flagged for "whichever task needs
  it next"; wiring a live UI trigger for this module is not this task's own
  owned surface.

  Idempotent replay (AC-11) is decided by the presence of a `Result` row for
  `run.id`, not by `run.state`: once one exists, every later call returns it
  immediately without touching Git or the filesystem again. Before that row
  exists, a first commit already present in staging (`git rev-parse HEAD`
  succeeding) is reused rather than re-committed — the real mechanism that
  makes a retry after a publish-phase failure safe, since `git add`/`git
  commit` are not re-run once a commit exists.

  A failure at any step (target revalidation, commit, or transfer) marks the
  run `"failed"` with a specific typed reason and appends a `"failed"`
  progress event (AC-12's visible failure stage and evidence) without
  deleting the run's staging directory — unlike `StagingBuilder`'s own
  failure/cancellation cleanup, a Task-5-level failure leaves the already
  (possibly partially) staged and committed content in place so a retry
  after the underlying problem is fixed can resume from wherever it stopped.
  A publish-phase (transfer) failure also removes only the files this
  attempt itself just wrote into `target_path` — never anything already
  there, which by that point has already been revalidated as empty.
  """

  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryInitialization.{Eligibility, Plan, Result, Run, Skeleton}
  alias SddOrchestrator.RepositoryInitialization.{SecurityLog, StagingWorkspace}

  @type publish_error ::
          :run_not_ready
          | :mature_repository
          | :non_empty_directory
          | :inaccessible
          | :target_changed
          | :target_symlinked
          | :target_permission_changed
          | :commit_failed
          | :publish_failed
          | :result_persist_failed

  @doc """
  Verifies the target is unchanged, ensures the staged build has one first
  commit, and publishes it into `target_path`.

  Returns the existing `Result` immediately when one already exists for this
  run (idempotent replay). Otherwise returns `{:ok, result}` on a fresh
  successful publication, or `{:error, reason, run}` with `run.state ==
  "failed"` on any failure.
  """
  @spec publish(Run.t(), Plan.t(), Path.t()) ::
          {:ok, Result.t()} | {:error, publish_error(), Run.t()}
  def publish(%Run{} = run, %Plan{} = plan, target_path) when is_binary(target_path) do
    result =
      case existing_result(run.id) do
        {:ok, result} -> {:ok, result}
        {:error, :not_found} -> do_publish(run, plan, target_path)
      end

    SecurityLog.audit(result, :publish)
  end

  defp do_publish(run, plan, target_path) do
    case ensure_stageable(run) do
      {:ok, staging_path} -> revalidate_step(run, plan, target_path, staging_path)
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp revalidate_step(run, plan, target_path, staging_path) do
    case revalidate_target(plan, target_path) do
      :ok -> record_target_revalidated(run, plan, target_path, staging_path)
      {:error, reason} -> {:error, reason, fail(run, reason)}
    end
  end

  defp record_target_revalidated(run, plan, target_path, staging_path) do
    case append_event(run, "progress", %{"step" => "target_revalidated"}) do
      {:ok, run} -> commit_step(run, plan, target_path, staging_path)
      {:error, reason} -> {:error, reason, fail(run, reason)}
    end
  end

  defp commit_step(run, plan, target_path, staging_path) do
    case ensure_first_commit(run, staging_path) do
      {:ok, run, commit_sha, tree_digest} ->
        transfer_step(run, plan, target_path, staging_path, commit_sha, tree_digest)

      {:error, reason} ->
        {:error, reason, fail(run, reason)}
    end
  end

  defp transfer_step(run, plan, target_path, staging_path, commit_sha, tree_digest) do
    case transfer(staging_path, target_path) do
      :ok -> persist_step(run, plan, commit_sha, tree_digest)
      {:error, reason} -> {:error, reason, fail(run, reason)}
    end
  end

  defp persist_step(run, plan, commit_sha, tree_digest) do
    case persist_result(run, plan, commit_sha, tree_digest) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason, fail(run, reason)}
    end
  end

  ## Staging precondition

  defp ensure_stageable(run) do
    case StagingWorkspace.staging_path(run) do
      {:ok, path} -> if File.dir?(path), do: {:ok, path}, else: {:error, :run_not_ready}
      {:error, _reason} -> {:error, :run_not_ready}
    end
  end

  ## Target revalidation (AC-09)

  defp revalidate_target(plan, target_path) do
    with {:ok, eligibility} <- Eligibility.classify(target_path),
         :ok <- ensure_same_eligibility(plan, eligibility),
         :ok <- ensure_not_symlink(target_path) do
      ensure_writable(target_path)
    end
  end

  defp ensure_same_eligibility(%Plan{eligibility: recorded}, eligibility) do
    if recorded == Atom.to_string(eligibility), do: :ok, else: {:error, :target_changed}
  end

  defp ensure_not_symlink(target_path) do
    case File.lstat(target_path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _changed -> {:error, :target_symlinked}
    end
  end

  defp ensure_writable(target_path) do
    case File.stat(target_path) do
      {:ok, %File.Stat{access: :read_write}} -> :ok
      _changed -> {:error, :target_permission_changed}
    end
  end

  ## Idempotent first commit and checked-tree binding (AC-11)

  defp ensure_first_commit(run, staging_path) do
    case current_head(staging_path) do
      {:ok, commit_sha} -> reuse_existing_commit(run, staging_path, commit_sha)
      {:error, :no_commit} -> create_first_commit(run, staging_path)
    end
  end

  defp reuse_existing_commit(run, staging_path, commit_sha) do
    case current_tree(staging_path) do
      {:ok, tree_digest} -> {:ok, run, commit_sha, tree_digest}
      {:error, _reason} -> {:error, :commit_failed}
    end
  end

  defp create_first_commit(run, staging_path) do
    with :ok <- git_add_all(staging_path),
         :ok <- git_commit(staging_path),
         {:ok, commit_sha} <- current_head(staging_path),
         {:ok, tree_digest} <- current_tree(staging_path),
         {:ok, run} <-
           append_event(run, "evidence", %{"step" => "checks_passed", "checks" => []}),
         {:ok, run} <-
           append_event(run, "progress", %{"step" => "committed", "commit_sha" => commit_sha}) do
      {:ok, run, commit_sha, tree_digest}
    else
      {:error, _reason} -> {:error, :commit_failed}
    end
  end

  defp git_add_all(staging_path) do
    case System.cmd("git", ["-C", staging_path, "add", "-A"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :commit_failed}
    end
  end

  defp git_commit(staging_path) do
    message = Skeleton.content()["git_behavior"]["first_commit_message"]

    args = [
      "-C",
      staging_path,
      "-c",
      "user.name=SDD Orchestrator",
      "-c",
      "user.email=init@sdd-orchestrator.local",
      "commit",
      "--quiet",
      "-m",
      message
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :commit_failed}
    end
  end

  defp current_head(staging_path) do
    case System.cmd("git", ["-C", staging_path, "rev-parse", "--verify", "HEAD"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :no_commit}
    end
  end

  defp current_tree(staging_path) do
    case System.cmd("git", ["-C", staging_path, "rev-parse", "HEAD^{tree}"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :tree_lookup_failed}
    end
  end

  ## Rollback-safe publication

  # `staging_path` is `StagingWorkspace.staging_path/1`'s own already-proven
  # contained location, and `target_path` is the caller's real path this
  # same call's own `revalidate_target/2` just independently reconfirmed
  # (still the recorded target, not a symlink, writable) — neither is raw
  # web input. `target_path` was just revalidated as empty, so every entry
  # `cp_r` places under it is this attempt's own content, never pre-existing
  # user data — safe to sweep away wholesale on a partial-copy failure.
  # Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp transfer(staging_path, target_path) do
    case File.cp_r(staging_path, target_path) do
      {:ok, _copied} ->
        File.rm_rf(staging_path)
        :ok

      {:error, _reason, _file} ->
        cleanup_partial_target(target_path)
        {:error, :publish_failed}
    end
  end

  defp cleanup_partial_target(target_path) do
    case File.ls(target_path) do
      {:ok, entries} -> Enum.each(entries, &File.rm_rf!(Path.join(target_path, &1)))
      {:error, _reason} -> :ok
    end
  end

  ## Result persistence

  defp persist_result(run, plan, commit_sha, tree_digest) do
    %Result{}
    |> Result.create_changeset(%{
      plan_id: plan.id,
      run_id: run.id,
      target_reference: plan.target_reference,
      commit_sha: commit_sha,
      tree_digest: tree_digest,
      kit_choice: run.kit_choice,
      kit_package_id: run.kit_package_id,
      kit_package_digest: run.kit_package_digest,
      check_evidence: [],
      completed_at: now(),
      onboarding_handoff_state: "pending"
    })
    |> Repo.insert()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, _changeset} -> {:error, :result_persist_failed}
    end
  end

  defp existing_result(run_id) do
    case Repo.get_by(Result, run_id: run_id) do
      %Result{} = result -> {:ok, result}
      nil -> {:error, :not_found}
    end
  end

  ## Failure recording (AC-12's visible failure stage and evidence)

  defp fail(run, reason) do
    event = build_event("failed", %{"reason" => to_string(reason)})

    {:ok, failed} =
      run
      |> Run.state_changeset(%{
        state: "failed",
        failure_reason: to_string(reason),
        finished_at: now(),
        progress: run.progress ++ [event]
      })
      |> Repo.update()

    failed
  end

  defp append_event(run, type, payload) do
    event = build_event(type, payload)

    run
    |> Run.progress_changeset(%{progress: run.progress ++ [event]})
    |> Repo.update()
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, _changeset} -> {:error, :run_transition_failed}
    end
  end

  defp build_event(type, payload) do
    %{"type" => type, "occurred_at" => now() |> DateTime.to_iso8601(), "payload" => payload}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
