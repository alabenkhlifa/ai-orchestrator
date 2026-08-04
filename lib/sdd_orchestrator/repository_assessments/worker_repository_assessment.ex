defmodule SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessment do
  @moduledoc """
  Bounded worker-local scanner for one exact repository commit.

  Repository content is treated as untrusted data and is never executed. The
  scanner reads allowlisted blobs directly from the authorized Git commit,
  emits only minimized metadata and a strict worker-local proposal payload, and
  performs no checkout or repository write.
  """

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryExecutionProfileProposalPayload
  }

  @generated_segments MapSet.new(~w(
    .cache .git .gradle .idea .next .pytest_cache .terraform .venv _build
    __pycache__ build coverage deps dist node_modules out target temp tmp vendor venv
  ))

  @instruction_names MapSet.new(~w(agents.md claude.md))
  @contribution_names MapSet.new(~w(contributing contributing.md code_of_conduct.md))

  @manifest_names MapSet.new(~w(
    build.gradle build.gradle.kts cargo.toml composer.json deno.json deno.jsonc
    gemfile go.mod mix.exs package.json pom.xml pyproject.toml
  ))

  @check_names MapSet.new(~w(justfile makefile taskfile.yml taskfile.yaml))

  @ci_names MapSet.new(~w(
    .gitlab-ci.yml azure-pipelines.yml bitbucket-pipelines.yml jenkinsfile
  ))

  @secret_names MapSet.new(~w(
    .npmrc .pypirc credentials credentials.json id_dsa id_ed25519 id_rsa
    secrets secrets.json
  ))

  @type error ::
          :canceled
          | :file_limit_exceeded
          | :file_size_limit_exceeded
          | :invalid_command
          | :path_limit_exceeded
          | :repository_unavailable
          | :root_escape
          | :stale_commit
          | :time_limit_exceeded
          | :total_byte_limit_exceeded

  @type finding :: %{
          required(:category) => String.t(),
          required(:path) => String.t(),
          required(:bytes) => non_neg_integer(),
          required(:sha256) => String.t(),
          required(:line_count) => non_neg_integer()
        }

  @doc "Scans the allowlisted high-signal surfaces at the command's exact commit."
  @spec scan(Path.t(), RepositoryAssessmentCommand.t(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def scan(repository_path, command, opts \\ [])

  def scan(repository_path, %RepositoryAssessmentCommand{} = command, opts)
      when is_binary(repository_path) and is_list(opts) do
    case do_scan(repository_path, command, opts) do
      {:ok, worker_result, _worker_local_evidence} -> {:ok, worker_result}
      {:error, _reason} = error -> error
    end
  end

  def scan(_repository_path, _command, _opts), do: {:error, :invalid_command}

  @doc "Scans once and derives the cache-stable proposal while raw evidence remains local."
  @spec scan_with_proposal(Path.t(), RepositoryAssessmentCommand.t(), keyword()) ::
          {:ok, map(), RepositoryExecutionProfileProposalPayload.t()} | {:error, error() | atom()}
  def scan_with_proposal(repository_path, command, opts \\ [])

  def scan_with_proposal(repository_path, %RepositoryAssessmentCommand{} = command, opts)
      when is_binary(repository_path) and is_list(opts) do
    with {:ok, worker_result, worker_local_evidence} <- do_scan(repository_path, command, opts),
         {:ok, result} <- RepositoryAssessmentResult.completed(command, worker_result),
         {:ok, payload} <-
           RepositoryExecutionProfileProposalPayload.derive(
             command,
             result,
             worker_local_evidence
           ) do
      {:ok, worker_result, payload}
    else
      {:error, :invalid_proposal_payload} -> {:error, :invalid_proposal_payload}
      {:error, :invalid_result} -> {:error, :invalid_result}
      {:error, _reason} = error -> error
    end
  end

  def scan_with_proposal(_repository_path, _command, _opts), do: {:error, :invalid_command}

  defp do_scan(repository_path, command, opts) do
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)
    on_progress = Keyword.get(opts, :on_progress, fn _progress -> :ok end)
    now_ms = Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    with true <- RepositoryAssessmentCommand.valid?(command),
         true <- is_function(cancelled?, 0),
         true <- is_function(on_progress, 1),
         true <- is_function(now_ms, 0),
         {:ok, started_at} <- monotonic_now(now_ms),
         :ok <- active(cancelled?, now_ms, started_at, command.limits.timeout_ms),
         {:ok, repository_root} <- repository_root(repository_path),
         :ok <- exact_commit(repository_root, command.commit),
         :ok <- selected_root(repository_root, command),
         {:ok, entries} <- tree_entries(repository_root, command),
         :ok <- active(cancelled?, now_ms, started_at, command.limits.timeout_ms),
         :ok <- enforce_path_limit(entries, command.limits),
         {:ok, candidates, structure} <- select_entries(entries, command.root),
         :ok <- enforce_file_limits(candidates, command.limits),
         :ok <- progress(on_progress, "enumerating", 0, 0, length(entries)),
         {:ok, findings, worker_local_evidence, inspected_files, bytes_read} <-
           inspect_candidates(
             repository_root,
             candidates,
             command,
             cancelled?,
             on_progress,
             now_ms,
             started_at,
             length(entries)
           ),
         :ok <- active(cancelled?, now_ms, started_at, command.limits.timeout_ms),
         :ok <- progress(on_progress, "completed", inspected_files, bytes_read, length(entries)) do
      worker_result = %{
        protocol_version: command.version,
        assessment_id: command.assessment_id,
        project_id: command.project_id,
        repository: %{
          provider: command.repository_provider,
          id: command.repository_id
        },
        root: command.root,
        commit: command.commit,
        scanner_contract_digest: command.scanner_contract_digest,
        status: "completed",
        findings: findings,
        structure: structure,
        stats: %{
          discovered_paths: length(entries),
          inspected_files: inspected_files,
          bytes_read: bytes_read
        }
      }

      {:ok, worker_result, worker_local_evidence}
    else
      false -> {:error, :invalid_command}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :repository_unavailable}
    end
  rescue
    _error -> {:error, :repository_unavailable}
  catch
    _kind, _reason -> {:error, :repository_unavailable}
  end

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

  defp selected_root(_repository_root, %{root: "."}), do: :ok

  defp selected_root(repository_root, command) do
    object = command.commit <> ":" <> command.root

    case git(repository_root, ["cat-file", "-t", object]) do
      {:ok, "tree"} -> :ok
      {:ok, _not_a_tree} -> {:error, :root_escape}
      _failure -> {:error, :root_escape}
    end
  end

  defp tree_entries(repository_root, command) do
    pathspec = if command.root == ".", do: [], else: ["--", command.root]

    case git(
           repository_root,
           ["ls-tree", "-r", "-z", "-l", "--full-tree", command.commit] ++ pathspec,
           trim: false
         ) do
      {:ok, output} -> parse_entries(output, command.root)
      _failure -> {:error, :repository_unavailable}
    end
  end

  defp parse_entries(output, root) do
    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, entries} ->
      case parse_entry(raw, root) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:skip, _reason} -> {:cont, {:ok, entries}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1.path)}
      error -> error
    end
  end

  defp parse_entry(raw, root) do
    with [metadata, path] <- :binary.split(raw, "\t"),
         true <- safe_path?(path),
         [mode, type, object_id, size] <- String.split(metadata, " ", trim: true),
         {size, ""} <- Integer.parse(size),
         true <- type == "blob",
         true <- mode not in ["120000", "160000"],
         {:ok, relative_path} <- relative_path(path, root) do
      {:ok,
       %{mode: mode, object_id: object_id, path: path, relative_path: relative_path, size: size}}
    else
      false -> {:skip, :unsafe_or_unsupported}
      _invalid -> {:error, :repository_unavailable}
    end
  end

  defp relative_path(path, "."), do: {:ok, path}
  defp relative_path(path, root) when path == root, do: {:error, :root_escape}

  defp relative_path(path, root) do
    prefix = root <> "/"

    if String.starts_with?(path, prefix),
      do: {:ok, String.replace_prefix(path, prefix, "")},
      else: {:error, :root_escape}
  end

  defp safe_path?(path) do
    is_binary(path) and String.valid?(path) and path != "" and Path.type(path) == :relative and
      not String.contains?(path, ["\\", <<0>>]) and
      not String.match?(path, ~r/[\x00-\x1f\x7f]/u) and
      not Enum.any?(Path.split(path), &(&1 in ["", ".", ".."]))
  end

  defp enforce_path_limit(entries, limits) do
    if length(entries) <= limits.max_paths,
      do: :ok,
      else: {:error, :path_limit_exceeded}
  end

  defp select_entries(entries, root) do
    {candidates, structure} =
      Enum.reduce(entries, {[], MapSet.new()}, fn entry, {selected, structure} ->
        relative = entry.relative_path

        if prohibited?(relative) do
          {selected, structure}
        else
          structure = MapSet.put(structure, top_level(relative))

          case category(relative) do
            nil -> {selected, structure}
            category -> {[Map.put(entry, :category, category) | selected], structure}
          end
        end
      end)

    structure =
      structure
      |> MapSet.delete("")
      |> Enum.sort()
      |> Enum.map(fn path -> %{path: path, kind: structure_kind(entries, root, path)} end)

    {:ok, Enum.sort_by(candidates, & &1.relative_path), structure}
  end

  defp enforce_file_limits(candidates, limits) do
    cond do
      length(candidates) > limits.max_files ->
        {:error, :file_limit_exceeded}

      Enum.any?(candidates, &(&1.size > limits.max_file_bytes)) ->
        {:error, :file_size_limit_exceeded}

      Enum.reduce(candidates, 0, &(&1.size + &2)) > limits.max_total_bytes ->
        {:error, :total_byte_limit_exceeded}

      true ->
        :ok
    end
  end

  defp inspect_candidates(
         repository_root,
         candidates,
         command,
         cancelled?,
         on_progress,
         now_ms,
         started_at,
         discovered_paths
       ) do
    Enum.reduce_while(candidates, {:ok, [], [], 0, 0}, fn entry,
                                                          {:ok, findings, evidence, files, bytes} ->
      with :ok <- active(cancelled?, now_ms, started_at, command.limits.timeout_ms),
           {:ok, content} <-
             git(repository_root, ["cat-file", "blob", entry.object_id], trim: false),
           true <- byte_size(content) == entry.size,
           next_bytes <- bytes + entry.size,
           true <- next_bytes <= command.limits.max_total_bytes,
           finding <- finding(entry, content),
           next_findings <- if(finding, do: [finding | findings], else: findings),
           next_evidence <-
             if(finding,
               do: [proposal_evidence(entry, content) | evidence],
               else: evidence
             ),
           :ok <- progress(on_progress, "scanning", files + 1, next_bytes, discovered_paths) do
        {:cont, {:ok, next_findings, next_evidence, files + 1, next_bytes}}
      else
        false -> {:halt, {:error, :repository_unavailable}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, findings, evidence, files, bytes} ->
        {:ok, Enum.sort_by(findings, & &1.path), Enum.sort_by(evidence, & &1.path), files, bytes}

      error ->
        error
    end
  end

  defp finding(_entry, content) when not is_binary(content), do: nil

  defp finding(entry, content) do
    if binary?(content) do
      nil
    else
      %{
        category: entry.category,
        path: entry.relative_path,
        bytes: entry.size,
        sha256: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower),
        line_count: line_count(content)
      }
    end
  end

  defp proposal_evidence(entry, content) do
    %{category: entry.category, path: entry.relative_path, content: content}
  end

  defp binary?(content),
    do: :binary.match(content, <<0>>) != :nomatch or not String.valid?(content)

  defp line_count(""), do: 0

  defp line_count(content) do
    newline_count = length(:binary.matches(content, "\n"))
    if String.ends_with?(content, "\n"), do: newline_count, else: newline_count + 1
  end

  defp category(path) do
    downcase = String.downcase(path)
    basename = Path.basename(downcase)

    cond do
      MapSet.member?(@instruction_names, basename) -> "instruction"
      MapSet.member?(@contribution_names, basename) -> "contribution"
      MapSet.member?(@manifest_names, basename) -> "manifest"
      MapSet.member?(@check_names, basename) -> "check"
      ci_path?(downcase, basename) -> "ci"
      true -> nil
    end
  end

  defp ci_path?(path, basename) do
    MapSet.member?(@ci_names, basename) or
      Regex.match?(~r/(?:\A|\/)\.github\/workflows\/[^\/]+\.ya?ml\z/, path) or
      String.ends_with?(path, ".circleci/config.yml")
  end

  defp prohibited?(path) do
    segments = path |> String.downcase() |> Path.split()
    basename = List.last(segments) || ""

    Enum.any?(segments, &MapSet.member?(@generated_segments, &1)) or
      MapSet.member?(@secret_names, basename) or
      basename == ".env" or String.starts_with?(basename, ".env.") or
      String.ends_with?(basename, [".key", ".pem", ".p12", ".pfx"]) or
      String.starts_with?(basename, ["credentials.", "secrets."])
  end

  defp top_level(path), do: path |> Path.split() |> List.first() || ""

  defp structure_kind(entries, root, path) do
    prefix = if root == ".", do: path <> "/", else: root <> "/" <> path <> "/"

    if Enum.any?(entries, &String.starts_with?(&1.path, prefix)),
      do: "directory",
      else: "file"
  end

  defp active(cancelled?, now_ms, started_at, timeout_ms) do
    cond do
      cancelled?.() == true -> {:error, :canceled}
      elapsed(now_ms, started_at) > timeout_ms -> {:error, :time_limit_exceeded}
      true -> :ok
    end
  end

  defp monotonic_now(now_ms) do
    case now_ms.() do
      value when is_integer(value) -> {:ok, value}
      _invalid -> {:error, :invalid_command}
    end
  rescue
    _error -> {:error, :invalid_command}
  end

  defp elapsed(now_ms, started_at) do
    case now_ms.() do
      value when is_integer(value) -> max(value - started_at, 0)
      _invalid -> raise ArgumentError, "invalid monotonic clock"
    end
  end

  defp progress(on_progress, phase, inspected_files, bytes_read, discovered_paths) do
    case on_progress.(%{
           phase: phase,
           inspected_files: inspected_files,
           bytes_read: bytes_read,
           discovered_paths: discovered_paths
         }) do
      :ok -> :ok
      _invalid -> {:error, :repository_unavailable}
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
