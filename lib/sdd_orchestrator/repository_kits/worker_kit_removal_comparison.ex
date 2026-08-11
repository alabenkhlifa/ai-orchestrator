defmodule SddOrchestrator.RepositoryKits.WorkerKitRemovalComparison do
  @moduledoc """
  Bounded, worker-local, read-only comparison classifying which of a
  currently-installed kit's own recorded files are still safely removable.

  Repository content is treated as untrusted data and is never executed.
  Comparison never checks out the repository, never writes to it, and never
  runs a script or hook — it only reads allowlisted blob objects directly
  from the authorized Git commit via `git cat-file` and `git ls-tree`.

  This intentionally duplicates the same small git primitives
  `SddOrchestrator.RepositoryKits.WorkerKitComparison` and
  `SddOrchestrator.RepositoryKits.WorkerKitUpdateComparison` already define
  (repository-root resolution, exact-commit staleness, selected-root
  containment, and the `git ls-tree`/`git cat-file` existence-and-content
  read) rather than reaching into either module's private functions — the
  same documented duplication those two modules' own moduledocs explain and
  justify, continued one layer further rather than inventing a different
  pattern.

  Unlike `WorkerKitComparison` and `WorkerKitUpdateComparison`, this module
  iterates `installed_files` (the authoritative record of what this
  project's kit currently owns), not a proposed package's file manifest —
  there is no "propose new content" step in a removal, only "is it still
  safe to delete what was recorded". `protected_paths` and the
  secret/credential/generated-directory safety-path check both existing
  sibling modules apply are deliberately not needed here: a protected or
  safety path is never a `"create"` operation at install or update time, so
  it can never appear in `installed_files` to begin with.
  """

  alias SddOrchestrator.RepositoryKits.WorkerKitComparison

  @doc """
  Compares every entry in `installed_files` (this project's
  `RepositoryKitInstallation.installed_files`) against the repository tree
  at `commit`, scoped to `root`, classifying each as `"delete"`, `"omit"`,
  or `"conflict"`/`"drifted"`:

    * Missing entirely from the live repository → `"omit"` — already
      absent, nothing to remove.
    * Live content still matches what was recorded at install or last
      update → `"delete"` — kit-owned and unchanged, safe to remove.
    * Live content no longer matches what was recorded → `"conflict"` /
      `"drifted"` — not safely removable automatically.

  `package_files` is the currently-installed package's own
  `file_manifest["files"]`, consulted only to source each operation's
  `proposed_content_base64` (the content originally installed at that path,
  shown so the owner can review exactly what a `"delete"` operation would
  remove) — it is never used to decide `"delete"` vs `"omit"` vs
  `"conflict"`, only `installed_files` and the live tree decide that.

  Fails closed with `{:error, :stale_commit}` before any operation is
  computed when the live repository's `HEAD` no longer matches `commit`,
  identical to `WorkerKitComparison.compare/5` and
  `WorkerKitUpdateComparison.compare/6`.
  """
  @spec compare(Path.t(), String.t(), String.t(), [map()], [map()]) ::
          {:ok, [map()]} | {:error, WorkerKitComparison.error()}
  def compare(repository_path, commit, root, package_files, installed_files)
      when is_binary(repository_path) and is_binary(commit) and is_binary(root) and
             is_list(package_files) and is_list(installed_files) do
    with {:ok, repository_root} <- repository_root(repository_path),
         :ok <- exact_commit(repository_root, commit),
         :ok <- selected_root(repository_root, commit, root),
         {:ok, found} <- existing_entries(repository_root, commit, root, installed_files) do
      content_by_path = Map.new(package_files, &{&1["path"], &1["content"]})
      build_operations(repository_root, found, installed_files, content_by_path)
    end
  end

  def compare(_repository_path, _commit, _root, _package_files, _installed_files),
    do: {:error, :invalid_path}

  ## Operation classification

  defp build_operations(repository_root, found, installed_files, content_by_path) do
    installed_files
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case classify(repository_root, found, entry, content_by_path) do
        {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp classify(repository_root, found, entry, content_by_path) do
    with {:ok, live_sha256} <- live_sha256(repository_root, found, entry["path"]) do
      classify_by_presence(entry, live_sha256, content_by_path)
    end
  end

  defp classify_by_presence(entry, nil, content_by_path) do
    {:ok,
     operation(
       entry,
       "omit",
       nil,
       nil,
       "already absent from the repository; nothing to remove",
       content_by_path
     )}
  end

  defp classify_by_presence(entry, live_sha256, content_by_path) do
    if live_sha256 == entry["sha256"] do
      {:ok,
       operation(
         entry,
         "delete",
         nil,
         live_sha256,
         "kit-owned and unchanged since installation; safe to remove",
         content_by_path
       )}
    else
      {:ok,
       operation(
         entry,
         "conflict",
         "drifted",
         live_sha256,
         "this kit-owned file was modified since installation; not safely removable automatically",
         content_by_path
       )}
    end
  end

  defp operation(entry, kind, severity, existing_sha256, reason, content_by_path) do
    %{
      "path" => entry["path"],
      "kind" => kind,
      "conflict_severity" => severity,
      "proposed_sha256" => entry["sha256"],
      "existing_sha256" => existing_sha256,
      "proposed_size" => entry["size"],
      "proposed_executable" => !!entry["executable"],
      "proposed_content_base64" => Map.get(content_by_path, entry["path"], ""),
      "reason" => reason
    }
  end

  ## Existence (metadata-only) reads, plus one blob read per existing path

  defp live_sha256(_repository_root, found, path) when not is_map_key(found, path), do: {:ok, nil}

  defp live_sha256(repository_root, found, path) do
    blob_sha256(repository_root, found[path].object_id)
  end

  defp existing_entries(_repository_root, _commit, _root, []), do: {:ok, %{}}

  defp existing_entries(repository_root, commit, root, installed_files) do
    pathspecs = Enum.map(installed_files, &git_path(root, &1["path"]))

    case git(
           repository_root,
           ["ls-tree", "-r", "-z", "-l", "--full-tree", commit, "--"] ++ pathspecs,
           trim: false
         ) do
      {:ok, output} -> parse_entries(output, root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_entries(output, root) do
    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn raw, {:ok, acc} ->
      case parse_entry(raw, root) do
        {:ok, relative_path, entry} -> {:cont, {:ok, Map.put(acc, relative_path, entry)}}
        :skip -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A symlink (mode 120000) or submodule (type "commit", mode 160000) is
  # silently skipped here — never surfaced as an existing entry — mirroring
  # `WorkerKitComparison.parse_entry/2`'s and `WorkerKitUpdateComparison.parse_entry/2`'s
  # exact same exclusion. A recorded path that happens to land on a symlink
  # or submodule therefore compares as "does not exist" here, which safely
  # resolves to `"omit"` rather than a mistaken `"delete"`.
  defp parse_entry(raw, root) do
    with [metadata, path] <- :binary.split(raw, "\t"),
         [mode, type, object_id, _size] <- String.split(metadata, " ", trim: true),
         true <- type == "blob",
         true <- mode not in ["120000", "160000"],
         {:ok, relative_path} <- relative_path(path, root) do
      {:ok, relative_path, %{object_id: object_id}}
    else
      false -> :skip
      {:error, :root_escape} -> :skip
      _invalid -> {:error, :repository_unavailable}
    end
  end

  defp relative_path(path, "."), do: {:ok, path}

  defp relative_path(path, root) do
    prefix = root <> "/"

    if String.starts_with?(path, prefix),
      do: {:ok, String.replace_prefix(path, prefix, "")},
      else: {:error, :root_escape}
  end

  defp git_path(".", path), do: path
  defp git_path(root, path), do: root <> "/" <> path

  ## Blob content read (only ever called for an existing path)

  defp blob_sha256(repository_root, object_id) do
    case git(repository_root, ["cat-file", "blob", object_id], trim: false) do
      {:ok, content} ->
        {:ok, content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Repository-local primitives (duplicated from `WorkerKitComparison`/`WorkerKitUpdateComparison`)

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

  defp selected_root(_repository_root, _commit, "."), do: :ok

  defp selected_root(repository_root, commit, root) do
    object = commit <> ":" <> root

    case git(repository_root, ["cat-file", "-t", object]) do
      {:ok, "tree"} -> :ok
      {:ok, _not_a_tree} -> {:error, :root_escape}
      _failure -> {:error, :root_escape}
    end
  end

  defp git(path, args, opts \\ []) do
    trim? = Keyword.get(opts, :trim, true)
    {output, status} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)

    if status == 0 do
      {:ok, if(trim?, do: String.trim(output), else: output)}
    else
      {:error, :repository_unavailable}
    end
  rescue
    _error -> {:error, :repository_unavailable}
  end
end
