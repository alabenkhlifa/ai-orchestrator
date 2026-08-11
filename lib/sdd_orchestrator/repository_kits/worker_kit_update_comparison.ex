defmodule SddOrchestrator.RepositoryKits.WorkerKitUpdateComparison do
  @moduledoc """
  Bounded, worker-local, read-only comparison between a newer kit package's
  proposed files, the currently-installed kit's own recorded file ownership,
  and the repository tree at one exact commit.

  Repository content is treated as untrusted data and is never executed.
  Comparison never checks out the repository, never writes to it, and never
  runs a script or hook — it only reads allowlisted blob objects directly
  from the authorized Git commit via `git cat-file` and `git ls-tree`.

  This intentionally duplicates a handful of small git primitives from
  `SddOrchestrator.RepositoryKits.WorkerKitComparison` (repository-root
  resolution, exact-commit staleness, selected-root containment, kit-path
  safety, and the same secret/generated-directory shape check) rather than
  reaching into that module's private functions or refactoring it. The two
  modules solve related but distinct problems — `WorkerKitComparison` compares
  a proposed package only against the live repository tree (install time,
  nothing is yet kit-owned); this module additionally compares against the
  currently-installed kit's own recorded per-file digests, so it can tell
  "kit-owned and unchanged since installation" (safe to overwrite) apart from
  "kit-owned but modified or deleted since installation" (blocked, a
  `"drifted"` conflict) and from "never kit-owned, exists with different
  content" (blocked, an `"ordinary"` conflict) — a three-way distinction
  `WorkerKitComparison` has no need to make. `WorkerKitComparison.compare/5`'s
  own moduledoc explains and justifies this same style of duplication from
  `WorkerRepositoryAssessment`; this module continues that pattern one layer
  up rather than inventing a different one.
  """

  alias SddOrchestrator.RepositoryKits.WorkerKitComparison

  @generated_segments MapSet.new(~w(
    .cache .git .gradle .idea .next .pytest_cache .terraform .venv _build
    __pycache__ build coverage deps dist node_modules out target temp tmp vendor venv
  ))

  @secret_names MapSet.new(~w(
    .npmrc .pypirc credentials credentials.json id_dsa id_ed25519 id_rsa
    secrets secrets.json
  ))

  @doc """
  Compares every file in `proposed_files` (the *new* package's
  `file_manifest["files"]`) against `installed_files` (the currently
  installed `RepositoryKitInstallation.installed_files`) and the repository
  tree at `commit`, scoped to `root`, classifying each as `"create"`,
  `"omit"`, or `"conflict"` (with severity `"ordinary"`, `"safety"`, or the
  update-only `"drifted"`).

  `protected_paths` is the set of paths the approved execution profile's
  `instruction_precedence` already names — always `"omit"`, identical to
  install. A path shaped like a secret, credential, or generated-directory
  pattern is always a `"safety"` conflict, existing content never read,
  identical to install.

  For every other path, `installed_files` is consulted first (by `"path"`)
  to learn whether this project's installed kit already owns it:

    * Not currently kit-owned, absent from the live repository → `"create"`.
    * Not currently kit-owned, live content identical to proposed →
      `"create"` (a harmless no-op rewrite).
    * Not currently kit-owned, live content differs from proposed →
      `"conflict"`/`"ordinary"` — this file was never the kit's to change.
    * Currently kit-owned, but missing from the live repository (deleted
      since install or last update) → `"conflict"`/`"drifted"` — not safely
      restorable automatically.
    * Currently kit-owned, live content unchanged since it was recorded →
      `"create"` — safe to overwrite with the new proposed content (or a
      no-op if the proposed content already matches).
    * Currently kit-owned, live content changed since it was recorded (a
      user modified it) → `"conflict"`/`"drifted"` — not safely updatable
      automatically.

  Fails closed with `{:error, :stale_commit}` before any operation is
  computed when the live repository's `HEAD` no longer matches `commit`,
  identical to `WorkerKitComparison.compare/5`.
  """
  @spec compare(Path.t(), String.t(), String.t(), [map()], MapSet.t(), [map()]) ::
          {:ok, [map()]} | {:error, WorkerKitComparison.error()}
  def compare(
        repository_path,
        commit,
        root,
        proposed_files,
        %MapSet{} = protected_paths,
        installed_files
      )
      when is_binary(repository_path) and is_binary(commit) and is_binary(root) and
             is_list(proposed_files) and is_list(installed_files) do
    with :ok <- validate_kit_paths(proposed_files),
         {:ok, repository_root} <- repository_root(repository_path),
         :ok <- exact_commit(repository_root, commit),
         :ok <- selected_root(repository_root, commit, root),
         {:ok, found} <- existing_entries(repository_root, commit, root, proposed_files) do
      recorded_by_path = Map.new(installed_files, &{&1["path"], &1["sha256"]})
      build_operations(repository_root, found, proposed_files, protected_paths, recorded_by_path)
    end
  end

  def compare(
        _repository_path,
        _commit,
        _root,
        _proposed_files,
        _protected_paths,
        _installed_files
      ),
      do: {:error, :invalid_path}

  ## Operation classification

  defp build_operations(repository_root, found, proposed_files, protected_paths, recorded_by_path) do
    proposed_files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case classify(repository_root, found, file, protected_paths, recorded_by_path) do
        {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp classify(repository_root, found, file, protected_paths, recorded_by_path) do
    path = file["path"]
    recorded_sha256 = Map.get(recorded_by_path, path)

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
        with {:ok, live_sha256} <- live_sha256(repository_root, found, path) do
          classify_by_ownership(file, recorded_sha256, live_sha256)
        end
    end
  end

  defp classify_by_ownership(file, nil, nil) do
    {:ok, operation(file, "create", nil, nil, "not present in the repository at the base commit")}
  end

  defp classify_by_ownership(file, nil, live_sha256) do
    if live_sha256 == file["sha256"] do
      {:ok,
       operation(
         file,
         "create",
         nil,
         live_sha256,
         "identical content already present in the repository"
       )}
    else
      {:ok,
       operation(
         file,
         "conflict",
         "ordinary",
         live_sha256,
         "existing file content differs from the proposed content"
       )}
    end
  end

  defp classify_by_ownership(file, _recorded_sha256, nil) do
    {:ok,
     operation(
       file,
       "conflict",
       "drifted",
       nil,
       "this kit-owned file was removed since installation; not safely restorable automatically"
     )}
  end

  defp classify_by_ownership(file, recorded_sha256, live_sha256)
       when recorded_sha256 == live_sha256 do
    if live_sha256 == file["sha256"] do
      {:ok, operation(file, "create", nil, live_sha256, "already matches the proposed content")}
    else
      {:ok,
       operation(
         file,
         "create",
         nil,
         live_sha256,
         "kit-owned and unchanged since installation; will be updated to the new version's content"
       )}
    end
  end

  defp classify_by_ownership(file, _recorded_sha256, live_sha256) do
    {:ok,
     operation(
       file,
       "conflict",
       "drifted",
       live_sha256,
       "this kit-owned file was modified since installation; not safely updatable automatically"
     )}
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

  ## Existence (metadata-only) reads, plus one blob read per existing path

  defp live_sha256(_repository_root, found, path) when not is_map_key(found, path), do: {:ok, nil}

  defp live_sha256(repository_root, found, path) do
    blob_sha256(repository_root, found[path].object_id)
  end

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
  # `WorkerKitComparison.parse_entry/2`'s exact same exclusion, and by
  # extension `WorkerRepositoryAssessment.tree_entries/2`'s. A kit path that
  # happens to land on a symlink or submodule therefore compares as "does not
  # exist" here; `WorkerKitApply`'s own apply-time root and symlink
  # containment check remains the actual safety backstop for that case.
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

  ## Repository-local primitives (duplicated from `WorkerKitComparison`)

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
