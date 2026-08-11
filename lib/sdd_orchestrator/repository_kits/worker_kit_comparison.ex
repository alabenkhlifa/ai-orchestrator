defmodule SddOrchestrator.RepositoryKits.WorkerKitComparison do
  @moduledoc """
  Bounded, worker-local, read-only comparison between a kit package's
  proposed files and the repository tree at one exact commit.

  Repository content is treated as untrusted data and is never executed.
  Comparison never checks out the repository, never writes to it, and never
  runs a script or hook — it only reads allowlisted blob objects directly
  from the authorized Git commit via `git cat-file` and `git ls-tree`.

  This intentionally duplicates a handful of small git primitives from
  `SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessment`
  (repository-root resolution, exact-commit staleness, selected-root
  containment, and the same path-safety and symlink/submodule exclusion
  rules used when parsing `git ls-tree` output) rather than reaching into
  that module's private functions or refactoring it. The two modules solve
  different problems — a bounded allowlisted-surface scan there, an exact
  per-path existence-and-content comparison here — and this module only
  ever targets the small set of exact paths named by one kit package's file
  manifest instead of enumerating the whole tree.
  """

  @generated_segments MapSet.new(~w(
    .cache .git .gradle .idea .next .pytest_cache .terraform .venv _build
    __pycache__ build coverage deps dist node_modules out target temp tmp vendor venv
  ))

  @secret_names MapSet.new(~w(
    .npmrc .pypirc credentials credentials.json id_dsa id_ed25519 id_rsa
    secrets secrets.json
  ))

  @type error :: :invalid_path | :repository_unavailable | :root_escape | :stale_commit

  @doc """
  Compares every file in `files` (one kit package's
  `file_manifest["files"]`) against the repository tree at `commit`, scoped
  to `root`, and classifies each as `"create"`, `"omit"`, or `"conflict"`.

  `protected_paths` is the set of paths the approved execution profile's
  `instruction_precedence` already names — those are always `"omit"`
  regardless of content, before anything is read from the repository.

  For every other path, existence is read from one batched `git ls-tree`
  call (metadata only, no blob content). A path whose shape matches a
  secret, credential, or generated-directory pattern (the same shape
  `WorkerRepositoryAssessment` already excludes from assessment findings)
  is classified `"conflict"`/`"safety"` from that existence check alone —
  its blob content is never read, so a secret's bytes are never pulled into
  worker memory even transiently. Every other existing path has its blob
  content read once to compute a comparable sha256.

  Fails closed with `{:error, :stale_commit}` before any operation is
  computed when the live repository's `HEAD` no longer matches `commit`.
  """
  @spec compare(Path.t(), String.t(), String.t(), [map()], MapSet.t()) ::
          {:ok, [map()]} | {:error, error()}
  def compare(repository_path, commit, root, files, %MapSet{} = protected_paths)
      when is_binary(repository_path) and is_binary(commit) and is_binary(root) and
             is_list(files) do
    with :ok <- validate_kit_paths(files),
         {:ok, repository_root} <- repository_root(repository_path),
         :ok <- exact_commit(repository_root, commit),
         :ok <- selected_root(repository_root, commit, root),
         {:ok, found} <- existing_entries(repository_root, commit, root, files) do
      build_operations(repository_root, found, files, protected_paths)
    end
  end

  def compare(_repository_path, _commit, _root, _files, _protected_paths),
    do: {:error, :invalid_path}

  ## Operation classification

  defp build_operations(repository_root, found, files, protected_paths) do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case classify(repository_root, found, file, protected_paths) do
        {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp classify(repository_root, found, file, protected_paths) do
    path = file["path"]

    cond do
      MapSet.member?(protected_paths, path) ->
        {:ok,
         operation(
           file,
           "omit",
           nil,
           nil,
           "protected by an existing repository instruction or contribution rule"
         )}

      not Map.has_key?(found, path) ->
        {:ok,
         operation(file, "create", nil, nil, "not present in the repository at the base commit")}

      safety_path?(path) ->
        {:ok,
         operation(
           file,
           "conflict",
           "safety",
           nil,
           "existing path matches a protected secret, credential, or generated-directory " <>
             "pattern; existing content was not read"
         )}

      true ->
        with {:ok, existing_sha256} <- blob_sha256(repository_root, found[path].object_id) do
          if existing_sha256 == file["sha256"] do
            {:ok,
             operation(
               file,
               "create",
               nil,
               existing_sha256,
               "identical content already present in the repository"
             )}
          else
            {:ok,
             operation(
               file,
               "conflict",
               "ordinary",
               existing_sha256,
               "existing file content differs from the proposed content"
             )}
          end
        end
    end
  end

  defp operation(file, kind, severity, existing_sha256, reason) do
    %{
      "path" => file["path"],
      "kind" => kind,
      "conflict_severity" => severity,
      "proposed_sha256" => file["sha256"],
      "existing_sha256" => existing_sha256,
      "proposed_size" => file["size"],
      "proposed_executable" => !!file["executable"],
      "proposed_content_base64" => file["content"],
      "reason" => reason
    }
  end

  defp safety_path?(path) do
    segments = path |> String.downcase() |> Path.split()
    basename = List.last(segments) || ""

    Enum.any?(segments, &MapSet.member?(@generated_segments, &1)) or
      MapSet.member?(@secret_names, basename) or
      basename == ".env" or String.starts_with?(basename, ".env.") or
      String.ends_with?(basename, [".key", ".pem", ".p12", ".pfx"]) or
      String.starts_with?(basename, ["credentials.", "secrets."])
  end

  ## Existence (metadata-only) reads

  defp existing_entries(_repository_root, _commit, _root, []), do: {:ok, %{}}

  defp existing_entries(repository_root, commit, root, files) do
    pathspecs = Enum.map(files, &git_path(root, &1["path"]))

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
  # `WorkerRepositoryAssessment.tree_entries/2`'s exact same exclusion so the
  # two readers agree on what "exists" means at this exact commit. A kit path
  # that happens to land on a symlink or submodule therefore compares as
  # "does not exist" here; `RepositoryKitInstallation`'s apply-time root and
  # symlink containment check (a later task) is the actual safety backstop
  # for that specific case, exactly as it already is for the assessment scan.
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

  ## Blob content read (only ever called for a non-safety, existing path)

  defp blob_sha256(repository_root, object_id) do
    case git(repository_root, ["cat-file", "blob", object_id], trim: false) do
      {:ok, content} ->
        {:ok, content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Repository-local primitives (duplicated from `WorkerRepositoryAssessment`)

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

  ## Kit-manifest path safety (defense in depth — `RepositoryKits.publish_package/2`
  ## already rejects an absolute, escaping, or malformed path at publish time)

  defp validate_kit_paths(files) do
    if Enum.all?(files, &safe_relative_kit_path?(&1["path"])) do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  defp safe_relative_kit_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and not String.contains?(path, <<0>>) and
      not Enum.any?(Path.split(path), &(&1 in [".", ".."]))
  end

  defp safe_relative_kit_path?(_path), do: false

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
