defmodule SddOrchestrator.RepositoryKits.WorkerKitApply do
  @moduledoc """
  Worker-local, isolated-branch application of one confirmed
  `RepositoryKitChangePlan`'s exact operations.

  Applies only the confirmed `"create"` operations (skipping every
  `"omit"`), never reads a `"conflict"` operation as anything but a reason
  to refuse via the operation allowlist, never touches a path outside the
  confirmed root, and never runs a repository hook. Every git invocation
  this module makes carries `-c core.hooksPath=/dev/null`, so hooks are
  disabled for branch creation, checkout, staging, and commit alike — not
  only the commit step — because a `post-checkout` or `pre-commit` hook is
  equally unreviewed repository content and must never execute.

  This intentionally duplicates the small git primitives
  `SddOrchestrator.RepositoryKits.WorkerKitComparison` already defines
  (repository-root resolution, exact-commit staleness) rather than reaching
  into that module's private functions, exactly as that module's own
  moduledoc explains and justifies for its own duplication from
  `WorkerRepositoryAssessment`. It also mirrors
  `SddOrchestrator.Delivery.Worker.Branch`'s default-branch refusal list and
  defensive git-argument discipline without importing or calling that
  module, since `Branch` is coupled to `ExecutionManifest`/`Workspace`/
  `run_id` and this module is not.

  Every gate in `apply/5` runs before the repository is mutated: the
  repository is only ever branched, checked out, or written to once every
  staleness, cleanliness, default-branch, conflict, allowlist, path, and
  symlink check has passed. Any failure from branch creation onward rolls
  back to the original ref and deletes the created branch on a best-effort
  basis, so a refused or failed apply never leaves a half-applied branch
  behind pretending to be a successful installation.
  """

  @default_branches ~w(head main master)
  @allowed_kinds ~w(create omit)
  @commit_message "Apply SDD kit change plan"

  @type error ::
          :apply_failed
          | :branch_conflict
          | :default_branch_forbidden
          | :dirty_working_tree
          | :invalid_operation
          | :path_escape
          | :repository_unavailable
          | :stale_commit
          | :symlink_escape
          | :unexpected_file

  @doc """
  Applies `operations` (one `RepositoryKitChangePlan`'s exact operation set)
  on a new isolated branch created from `base_commit`, and returns the
  resulting commit, the installed-file digests, and non-identifying apply
  evidence.

  Never puts `repository_path`, `repository_root`, or any other filesystem
  path into the returned evidence or anywhere but `installed_files[].path`,
  which is always relative to the repository root (joined with `root`).
  """
  @spec apply(Path.t(), String.t(), String.t(), String.t(), [map()]) ::
          {:ok, %{commit: String.t(), installed_files: [map()], evidence: map()}}
          | {:error, error()}
  def apply(repository_path, base_commit, root, target_branch, operations)
      when is_binary(repository_path) and is_binary(base_commit) and is_binary(root) and
             is_binary(target_branch) and is_list(operations) do
    with {:ok, repository_root} <- repository_root(repository_path),
         :ok <- exact_commit(repository_root, base_commit),
         :ok <- clean_working_tree(repository_root),
         {:ok, original_ref} <- original_ref(repository_root),
         :ok <- refuse_default_branch(normalize_branch(target_branch)),
         :ok <- refuse_existing_branch(repository_root, target_branch),
         :ok <- validate_operation_kinds(operations),
         {:ok, creates} <- validate_paths(repository_root, root, operations) do
      apply_creates(
        repository_root,
        root,
        target_branch,
        base_commit,
        original_ref,
        creates,
        omit_count(operations)
      )
    end
  end

  def apply(_repository_path, _base_commit, _root, _target_branch, _operations),
    do: {:error, :repository_unavailable}

  ## Pre-mutation gates (read-only)

  defp repository_root(repository_path) do
    case git(repository_path, ["rev-parse", "--show-toplevel"]) do
      {:ok, root} when root != "" ->
        expanded = Path.expand(root)

        if Path.type(root) == :absolute and File.dir?(expanded),
          do: {:ok, expanded},
          else: {:error, :repository_unavailable}

      _failure ->
        {:error, :repository_unavailable}
    end
  end

  defp exact_commit(repository_root, expected_commit) do
    case git(repository_root, ["rev-parse", "--verify", "HEAD^{commit}"]) do
      {:ok, ^expected_commit} -> :ok
      {:ok, _different_commit} -> {:error, :stale_commit}
      _failure -> {:error, :repository_unavailable}
    end
  end

  defp clean_working_tree(repository_root) do
    case git(repository_root, ["status", "--porcelain"]) do
      {:ok, ""} -> :ok
      {:ok, _dirty} -> {:error, :dirty_working_tree}
      {:error, reason} -> {:error, reason}
    end
  end

  defp original_ref(repository_root) do
    case git(repository_root, ["symbolic-ref", "--short", "-q", "HEAD"]) do
      {:ok, ref} when ref != "" -> {:ok, ref}
      _detached_or_failed -> fallback_ref(repository_root)
    end
  end

  defp fallback_ref(repository_root) do
    case git(repository_root, ["rev-parse", "HEAD"]) do
      {:ok, sha} when sha != "" -> {:ok, sha}
      _failure -> {:error, :repository_unavailable}
    end
  end

  # Case and a `refs/heads/` prefix are stripped so the refusal cannot be
  # spelled around, mirroring `Delivery.Worker.Branch.refuse_default_branch/1`.
  defp normalize_branch(branch),
    do: branch |> String.replace_prefix("refs/heads/", "") |> String.downcase()

  defp refuse_default_branch(normalized) do
    if normalized in @default_branches, do: {:error, :default_branch_forbidden}, else: :ok
  end

  defp refuse_existing_branch(repository_root, branch) do
    case branch_exists?(repository_root, branch) do
      {:ok, true} -> {:error, :branch_conflict}
      {:ok, false} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp branch_exists?(repository_root, branch) do
    case git_raw(repository_root, ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch]) do
      {:ok, {_output, 0}} -> {:ok, true}
      {:ok, {_output, _nonzero}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_operation_kinds(operations) do
    if Enum.all?(operations, &(&1["kind"] in @allowed_kinds)) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  defp omit_count(operations), do: Enum.count(operations, &(&1["kind"] == "omit"))

  ## Path and symlink containment (read-only; every "create" operation is
  ## checked before anything is mutated, so a rejected plan creates no branch)

  defp validate_paths(repository_root, root, operations) do
    allowed_root = expanded_root(repository_root, root)

    operations
    |> Enum.filter(&(&1["kind"] == "create"))
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
      case validate_operation_path(repository_root, root, allowed_root, operation) do
        {:ok, target_path} -> {:cont, {:ok, [{operation, target_path} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, creates} -> {:ok, Enum.reverse(creates)}
      error -> error
    end
  end

  defp expanded_root(repository_root, "."), do: repository_root
  defp expanded_root(repository_root, root), do: Path.expand(Path.join(repository_root, root))

  defp validate_operation_path(repository_root, root, allowed_root, operation) do
    target_path = operation_target_path(repository_root, root, operation["path"])
    expanded_target = Path.expand(target_path)

    if contained?(expanded_target, allowed_root) do
      check_symlink_ancestors(expanded_target, repository_root, target_path)
    else
      {:error, :path_escape}
    end
  end

  defp operation_target_path(repository_root, ".", path), do: Path.join(repository_root, path)

  defp operation_target_path(repository_root, root, path),
    do: Path.join([repository_root, root, path])

  defp contained?(expanded_target, allowed_root) do
    expanded_target == allowed_root or String.starts_with?(expanded_target, allowed_root <> "/")
  end

  defp check_symlink_ancestors(expanded_target, repository_root, target_path) do
    if Enum.any?(ancestors(expanded_target, repository_root), &symlink?/1) do
      {:error, :symlink_escape}
    else
      {:ok, target_path}
    end
  end

  defp ancestors(expanded_target, repository_root) do
    expanded_repository_root = Path.expand(repository_root)
    do_ancestors(Path.dirname(expanded_target), expanded_repository_root, [])
  end

  defp do_ancestors(current, repository_root, acc) do
    cond do
      current == repository_root -> [current | acc]
      current in ["/", "."] -> acc
      true -> do_ancestors(Path.dirname(current), repository_root, [current | acc])
    end
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _not_a_symlink_or_missing -> false
    end
  end

  ## Mutation (only ever reached once every gate above has passed)

  defp apply_creates(
         repository_root,
         root,
         target_branch,
         base_commit,
         original_ref,
         creates,
         omit_count
       ) do
    case do_apply(repository_root, root, target_branch, base_commit, creates) do
      {:ok, result} -> {:ok, build_result(result, length(creates), omit_count)}
      {:error, reason} -> rollback(repository_root, original_ref, target_branch, reason)
    end
  end

  defp do_apply(repository_root, root, target_branch, base_commit, creates) do
    with :ok <- create_branch(repository_root, target_branch, base_commit),
         :ok <- checkout_branch(repository_root, target_branch),
         {:ok, installed_files} <- write_creates(creates),
         :ok <- stage_and_verify(repository_root, root, installed_files),
         {:ok, committed?} <- commit_if_needed(repository_root),
         {:ok, commit} <- read_head(repository_root) do
      {:ok, %{commit: commit, installed_files: installed_files, committed?: committed?}}
    end
  end

  defp create_branch(repository_root, target_branch, base_commit) do
    case git(repository_root, ["branch", target_branch, base_commit]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkout_branch(repository_root, target_branch) do
    case git(repository_root, ["checkout", "--quiet", target_branch]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Every raised error while writing (a bad path, a permission failure, a
  # malformed base64 payload) is caught here and routed to the caller as
  # `:apply_failed` rather than left as an uncaught exception, so the
  # surrounding `apply_creates/7` always gets a chance to roll back.
  defp write_creates(creates) do
    creates
    |> Enum.reduce_while({:ok, []}, fn {operation, target_path}, {:ok, acc} ->
      case write_create(target_path, operation) do
        {:ok, file_entry} -> {:cont, {:ok, [file_entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  rescue
    _error -> {:error, :apply_failed}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_create(target_path, operation) do
    if File.exists?(target_path) and is_nil(operation["existing_sha256"]) do
      {:error, :unexpected_file}
    else
      content = Base.decode64!(operation["proposed_content_base64"])
      File.mkdir_p!(Path.dirname(target_path))
      File.write!(target_path, content)
      mode = if operation["proposed_executable"], do: 0o755, else: 0o644
      File.chmod!(target_path, mode)

      {:ok,
       %{
         "path" => operation["path"],
         "sha256" => content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
         "size" => byte_size(content),
         "executable" => !!operation["proposed_executable"]
       }}
    end
  end

  defp stage_and_verify(repository_root, root, installed_files) do
    pathspecs = Enum.map(installed_files, &git_pathspec(root, &1["path"]))

    with :ok <- git_add(repository_root, pathspecs),
         {:ok, staged} <- staged_paths(repository_root) do
      if MapSet.new(staged) == MapSet.new(pathspecs),
        do: :ok,
        else: {:error, :unexpected_file}
    end
  end

  defp git_pathspec(".", path), do: path
  defp git_pathspec(root, path), do: root <> "/" <> path

  defp git_add(_repository_root, []), do: :ok

  defp git_add(repository_root, pathspecs) do
    case git(repository_root, ["add", "--" | pathspecs]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp staged_paths(repository_root) do
    case git(repository_root, ["diff", "--cached", "--name-only"], trim: false) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_if_needed(repository_root) do
    case git_raw(repository_root, ["diff", "--cached", "--quiet"]) do
      {:ok, {_output, 0}} -> {:ok, false}
      {:ok, {_output, 1}} -> do_commit(repository_root)
      {:ok, {_output, _other}} -> {:error, :repository_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_commit(repository_root) do
    case git_raw(repository_root, ["commit", "-m", @commit_message]) do
      {:ok, {_output, 0}} -> {:ok, true}
      _failure -> {:error, :apply_failed}
    end
  end

  defp read_head(repository_root) do
    case git(repository_root, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> {:ok, sha}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_result(
         %{commit: commit, installed_files: installed_files, committed?: committed?},
         create_count,
         omit_count
       ) do
    %{
      commit: commit,
      installed_files: installed_files,
      evidence: %{
        "hooks_disabled" => true,
        "working_tree_clean_before_apply" => true,
        "operations_applied" => create_count,
        "operations_omitted" => omit_count,
        "committed" => committed?
      }
    }
  end

  # Best-effort: a failure while cleaning up is logged (ignored) here rather
  # than surfaced, since the point of rollback is to not leave a half-applied
  # branch pretending to be checked out, not to guarantee the cleanup itself
  # cannot fail. The original `{:error, reason}` this rollback was called for
  # is always what gets returned.
  defp rollback(repository_root, original_ref, target_branch, reason) do
    _ = git(repository_root, ["checkout", "--quiet", original_ref])
    _ = git(repository_root, ["branch", "-D", target_branch])
    _ = git(repository_root, ["clean", "-fd"])
    {:error, reason}
  end

  ## Git primitives (duplicated from `WorkerKitComparison`; see moduledoc)

  # Every git invocation this module makes carries `-c core.hooksPath=/dev/null`
  # as a per-invocation config override, disabling every repository hook
  # (pre-commit, post-checkout, and any other) for that one call without
  # touching the repository's real hooks configuration. `--no-verify` alone
  # would only skip the two commit-time hook types, not the rest.
  # sobelow_skip ["CI.System"]
  defp git_raw(path, args) do
    {:ok,
     System.cmd("git", ["-C", path, "-c", "core.hooksPath=/dev/null" | args],
       stderr_to_stdout: true
     )}
  rescue
    _error -> {:error, :repository_unavailable}
  end

  defp git(path, args, opts \\ []) do
    trim? = Keyword.get(opts, :trim, true)

    case git_raw(path, args) do
      {:ok, {output, 0}} -> {:ok, if(trim?, do: String.trim(output), else: output)}
      {:ok, {_output, _status}} -> {:error, :repository_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end
end
