defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessmentResult do
  @moduledoc """
  Strict minimized terminal result for one exact repository-assessment command.

  The value repeats the complete command binding so the authoritative store can
  reject a result for another project, repository, root, commit, scanner,
  disclosure, worker, or limit contract. Completed results contain only bounded
  source-relative metadata. Canceled and failed results contain no partial scan
  evidence, and failures use a closed set of product-safe codes.
  """

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand

  @statuses ~w(completed canceled failed)
  @finding_categories ~w(instruction contribution manifest check ci)

  @failure_codes ~w(
    file_limit_exceeded file_size_limit_exceeded invalid_command path_limit_exceeded
    repository_unavailable root_escape stale_commit time_limit_exceeded
    total_byte_limit_exceeded
  )

  @fields [
    :version,
    :assessment_id,
    :project_id,
    :repository_provider,
    :repository_id,
    :root,
    :commit,
    :scanner_contract_digest,
    :disclosure_digest,
    :worker_ref,
    :limits,
    :status,
    :findings,
    :structure,
    :stats,
    :failure_code
  ]

  @enforce_keys @fields
  defstruct @fields

  @max_anchor_bytes 4_096
  @max_result_bytes 2 * 1_024 * 1_024

  @type t :: %__MODULE__{
          version: pos_integer(),
          assessment_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          root: String.t(),
          commit: String.t(),
          scanner_contract_digest: String.t(),
          disclosure_digest: String.t(),
          worker_ref: Ecto.UUID.t(),
          limits: RepositoryAssessmentCommand.limits(),
          status: String.t(),
          findings: [map()],
          structure: [map()],
          stats: map(),
          failure_code: String.t() | nil
        }

  @doc "Builds one completed result from the exact output of the bounded scanner."
  @spec completed(RepositoryAssessmentCommand.t(), map()) ::
          {:ok, t()} | {:error, :invalid_result}
  def completed(%RepositoryAssessmentCommand{} = command, worker_result) do
    with true <- RepositoryAssessmentCommand.valid?(command),
         {:ok, findings, structure, stats} <- validate_completed(worker_result, command) do
      build(
        command_attrs(command)
        |> Map.merge(%{
          status: "completed",
          findings: findings,
          structure: structure,
          stats: stats,
          failure_code: nil
        })
      )
    else
      _invalid -> {:error, :invalid_result}
    end
  rescue
    _error -> {:error, :invalid_result}
  end

  def completed(_command, _worker_result), do: {:error, :invalid_result}

  @doc "Builds a canceled terminal result without retaining partial evidence."
  @spec canceled(RepositoryAssessmentCommand.t()) :: {:ok, t()} | {:error, :invalid_result}
  def canceled(%RepositoryAssessmentCommand{} = command) do
    terminal_without_evidence(command, "canceled", nil)
  end

  def canceled(_command), do: {:error, :invalid_result}

  @doc "Builds a failed terminal result from one allowlisted product-safe reason."
  @spec failed(RepositoryAssessmentCommand.t(), atom() | String.t()) ::
          {:ok, t()} | {:error, :invalid_result}
  def failed(%RepositoryAssessmentCommand{} = command, reason) do
    with {:ok, code} <- failure_code(reason) do
      terminal_without_evidence(command, "failed", code)
    end
  end

  def failed(_command, _reason), do: {:error, :invalid_result}

  @doc "Restores only the exact serialized result shape."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_result}
  def from_value(value) when is_map(value) do
    expected =
      MapSet.new(
        ~w(version assessment_id project_id repository root commit scanner_contract_digest disclosure_digest worker_ref limits status findings structure stats failure_code)
      )

    with true <- MapSet.new(Map.keys(value)) == expected,
         %{"provider" => provider, "id" => repository_id} = repository <-
           Map.fetch!(value, "repository"),
         true <- MapSet.new(Map.keys(repository)) == MapSet.new(~w(provider id)),
         {:ok, limits} <- limits_from_value(Map.fetch!(value, "limits")) do
      build(%{
        version: Map.fetch!(value, "version"),
        assessment_id: Map.fetch!(value, "assessment_id"),
        project_id: Map.fetch!(value, "project_id"),
        repository_provider: provider,
        repository_id: repository_id,
        root: Map.fetch!(value, "root"),
        commit: Map.fetch!(value, "commit"),
        scanner_contract_digest: Map.fetch!(value, "scanner_contract_digest"),
        disclosure_digest: Map.fetch!(value, "disclosure_digest"),
        worker_ref: Map.fetch!(value, "worker_ref"),
        limits: limits,
        status: Map.fetch!(value, "status"),
        findings: Map.fetch!(value, "findings"),
        structure: Map.fetch!(value, "structure"),
        stats: Map.fetch!(value, "stats"),
        failure_code: Map.fetch!(value, "failure_code")
      })
    else
      _invalid -> {:error, :invalid_result}
    end
  rescue
    _error -> {:error, :invalid_result}
  end

  def from_value(_value), do: {:error, :invalid_result}

  @doc "Serializes the complete allowlisted result without source content or paths."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = result) do
    %{
      "version" => result.version,
      "assessment_id" => result.assessment_id,
      "project_id" => result.project_id,
      "repository" => %{
        "provider" => result.repository_provider,
        "id" => result.repository_id
      },
      "root" => result.root,
      "commit" => result.commit,
      "scanner_contract_digest" => result.scanner_contract_digest,
      "disclosure_digest" => result.disclosure_digest,
      "worker_ref" => result.worker_ref,
      "limits" => stringify_keys(result.limits),
      "status" => result.status,
      "findings" => result.findings,
      "structure" => result.structure,
      "stats" => result.stats,
      "failure_code" => result.failure_code
    }
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = result) do
    case result |> to_value() |> from_value() do
      {:ok, ^result} -> true
      _invalid -> false
    end
  rescue
    _error -> false
  end

  def valid?(_result), do: false

  @doc "Confirms every command-owned field, including the full limit contract."
  @spec matches_command?(t(), RepositoryAssessmentCommand.t()) :: boolean()
  def matches_command?(%__MODULE__{} = result, %RepositoryAssessmentCommand{} = command) do
    valid?(result) and RepositoryAssessmentCommand.valid?(command) and
      command_attrs(command) ==
        Map.take(result, Map.keys(command_attrs(command)))
  end

  def matches_command?(_result, _command), do: false

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec failure_codes() :: [String.t()]
  def failure_codes, do: @failure_codes

  @doc false
  @spec max_result_bytes() :: pos_integer()
  def max_result_bytes, do: @max_result_bytes

  defp terminal_without_evidence(command, status, code) do
    if RepositoryAssessmentCommand.valid?(command) do
      build(
        command_attrs(command)
        |> Map.merge(%{
          status: status,
          findings: [],
          structure: [],
          stats: %{},
          failure_code: code
        })
      )
    else
      {:error, :invalid_result}
    end
  end

  defp validate_completed(worker_result, command) when is_map(worker_result) do
    expected =
      MapSet.new([
        :protocol_version,
        :assessment_id,
        :project_id,
        :repository,
        :root,
        :commit,
        :scanner_contract_digest,
        :status,
        :findings,
        :structure,
        :stats
      ])

    with true <- MapSet.new(Map.keys(worker_result)) == expected,
         true <- worker_result.protocol_version == command.version,
         true <- worker_result.assessment_id == command.assessment_id,
         true <- worker_result.project_id == command.project_id,
         true <-
           worker_result.repository == %{
             provider: command.repository_provider,
             id: command.repository_id
           },
         true <- worker_result.root == command.root,
         true <- worker_result.commit == command.commit,
         true <- worker_result.scanner_contract_digest == command.scanner_contract_digest,
         true <- worker_result.status == "completed",
         {:ok, findings} <- validate_findings(worker_result.findings, command.limits),
         {:ok, structure} <- validate_structure(worker_result.structure, command.limits),
         {:ok, stats} <- validate_stats(worker_result.stats, findings, structure, command.limits) do
      {:ok, findings, structure, stats}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp validate_completed(_worker_result, _command), do: {:error, :invalid_result}

  defp validate_findings(findings, limits) when is_list(findings) do
    with true <- length(findings) <= limits.max_files,
         {:ok, normalized} <- map_each(findings, &validate_finding(&1, limits)),
         true <- ordered_unique?(normalized),
         true <-
           Enum.reduce(normalized, 0, &(Map.fetch!(&1, "bytes") + &2)) <= limits.max_total_bytes do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp validate_findings(_findings, _limits), do: {:error, :invalid_result}

  defp validate_finding(finding, limits) when is_map(finding) do
    with true <-
           MapSet.new(Map.keys(finding)) ==
             MapSet.new([:category, :path, :bytes, :sha256, :line_count]),
         category when category in @finding_categories <- finding.category,
         {:ok, path} <- safe_anchor(finding.path),
         bytes when is_integer(bytes) and bytes >= 0 and bytes <= limits.max_file_bytes <-
           finding.bytes,
         {:ok, sha256} <- digest(finding.sha256),
         line_count when is_integer(line_count) and line_count >= 0 <- finding.line_count,
         true <- valid_line_count?(bytes, line_count) do
      {:ok,
       %{
         "category" => category,
         "path" => path,
         "bytes" => bytes,
         "sha256" => sha256,
         "line_count" => line_count
       }}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp validate_finding(_finding, _limits), do: {:error, :invalid_result}

  defp validate_structure(structure, limits) when is_list(structure) do
    with true <- length(structure) <= limits.max_paths,
         {:ok, normalized} <- map_each(structure, &validate_structure_entry/1),
         true <- ordered_unique?(normalized) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp validate_structure(_structure, _limits), do: {:error, :invalid_result}

  defp validate_structure_entry(entry) when is_map(entry) do
    with true <- MapSet.new(Map.keys(entry)) == MapSet.new([:path, :kind]),
         {:ok, path} <- safe_anchor(entry.path),
         kind when kind in ~w(file directory) <- entry.kind do
      {:ok, %{"path" => path, "kind" => kind}}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp validate_structure_entry(_entry), do: {:error, :invalid_result}

  defp validate_stats(stats, findings, structure, limits) when is_map(stats) do
    with true <-
           MapSet.new(Map.keys(stats)) ==
             MapSet.new([:discovered_paths, :inspected_files, :bytes_read]),
         discovered
         when is_integer(discovered) and discovered >= 0 and discovered <= limits.max_paths <-
           stats.discovered_paths,
         inspected when is_integer(inspected) and inspected >= 0 and inspected <= limits.max_files <-
           stats.inspected_files,
         bytes when is_integer(bytes) and bytes >= 0 and bytes <= limits.max_total_bytes <-
           stats.bytes_read,
         true <- discovered >= inspected,
         true <- discovered >= length(structure),
         true <- inspected >= length(findings),
         true <- bytes >= Enum.reduce(findings, 0, &(Map.fetch!(&1, "bytes") + &2)) do
      {:ok,
       %{
         "discovered_paths" => discovered,
         "inspected_files" => inspected,
         "bytes_read" => bytes
       }}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  defp validate_stats(_stats, _findings, _structure, _limits), do: {:error, :invalid_result}

  defp build(attrs) do
    command = command_from_attrs(attrs)

    with true <- MapSet.new(Map.keys(attrs)) == MapSet.new(@fields),
         true <- RepositoryAssessmentCommand.valid?(command),
         status when status in @statuses <- attrs.status,
         {:ok, findings} <- validate_stored_findings(attrs.findings, command.limits),
         {:ok, structure} <- validate_stored_structure(attrs.structure, command.limits),
         {:ok, stats} <- validate_stored_stats(attrs.stats, findings, structure, command.limits),
         :ok <- validate_outcome(status, attrs.failure_code, findings, structure, stats) do
      result =
        struct!(__MODULE__, %{
          Map.take(attrs, @fields)
          | limits: command.limits,
            findings: findings,
            structure: structure,
            stats: stats
        })

      if encoded_size(result) <= @max_result_bytes,
        do: {:ok, result},
        else: {:error, :invalid_result}
    else
      _invalid -> {:error, :invalid_result}
    end
  rescue
    _error -> {:error, :invalid_result}
  end

  defp validate_stored_findings(findings, limits) when is_list(findings) do
    atom_findings = Enum.map(findings, &atomize_finding/1)
    validate_findings(atom_findings, limits)
  rescue
    _error -> {:error, :invalid_result}
  end

  defp validate_stored_findings(_findings, _limits), do: {:error, :invalid_result}

  defp validate_stored_structure(structure, limits) when is_list(structure) do
    atom_structure = Enum.map(structure, &atomize_structure/1)
    validate_structure(atom_structure, limits)
  rescue
    _error -> {:error, :invalid_result}
  end

  defp validate_stored_structure(_structure, _limits), do: {:error, :invalid_result}

  defp validate_stored_stats(stats, findings, structure, limits) when is_map(stats) do
    atom_stats =
      case stats do
        %{} when map_size(stats) == 0 ->
          %{}

        %{
          "discovered_paths" => discovered,
          "inspected_files" => inspected,
          "bytes_read" => bytes
        } = value
        when map_size(value) == 3 ->
          %{discovered_paths: discovered, inspected_files: inspected, bytes_read: bytes}

        _invalid ->
          :invalid
      end

    case atom_stats do
      %{} when map_size(atom_stats) == 0 -> {:ok, %{}}
      %{} -> validate_stats(atom_stats, findings, structure, limits)
      :invalid -> {:error, :invalid_result}
    end
  end

  defp validate_stored_stats(_stats, _findings, _structure, _limits),
    do: {:error, :invalid_result}

  defp validate_outcome("completed", nil, _findings, _structure, stats)
       when map_size(stats) == 3,
       do: :ok

  defp validate_outcome("canceled", nil, [], [], stats) when map_size(stats) == 0, do: :ok

  defp validate_outcome("failed", code, [], [], stats)
       when code in @failure_codes and map_size(stats) == 0,
       do: :ok

  defp validate_outcome(_status, _code, _findings, _structure, _stats),
    do: {:error, :invalid_result}

  defp command_from_attrs(attrs) do
    struct!(RepositoryAssessmentCommand, %{
      version: attrs.version,
      assessment_id: attrs.assessment_id,
      project_id: attrs.project_id,
      repository_provider: attrs.repository_provider,
      repository_id: attrs.repository_id,
      root: attrs.root,
      commit: attrs.commit,
      scanner_contract_digest: attrs.scanner_contract_digest,
      disclosure_digest: attrs.disclosure_digest,
      worker_ref: attrs.worker_ref,
      limits: attrs.limits
    })
  end

  defp command_attrs(command) do
    %{
      version: command.version,
      assessment_id: command.assessment_id,
      project_id: command.project_id,
      repository_provider: command.repository_provider,
      repository_id: command.repository_id,
      root: command.root,
      commit: command.commit,
      scanner_contract_digest: command.scanner_contract_digest,
      disclosure_digest: command.disclosure_digest,
      worker_ref: command.worker_ref,
      limits: command.limits
    }
  end

  defp limits_from_value(value) when is_map(value) do
    keys = ~w(max_paths max_files max_total_bytes max_file_bytes timeout_ms)

    if MapSet.new(Map.keys(value)) == MapSet.new(keys) do
      {:ok,
       %{
         max_paths: value["max_paths"],
         max_files: value["max_files"],
         max_total_bytes: value["max_total_bytes"],
         max_file_bytes: value["max_file_bytes"],
         timeout_ms: value["timeout_ms"]
       }}
    else
      {:error, :invalid_result}
    end
  end

  defp limits_from_value(_value), do: {:error, :invalid_result}

  defp safe_anchor(path) when is_binary(path) do
    segments = Path.split(path)

    cond do
      path == "" or byte_size(path) > @max_anchor_bytes -> {:error, :invalid_result}
      not plain_relative_path?(path) -> {:error, :invalid_result}
      Enum.any?(segments, &(&1 in [".", "..", ""])) -> {:error, :invalid_result}
      Path.join(segments) != path -> {:error, :invalid_result}
      true -> {:ok, path}
    end
  end

  defp safe_anchor(_path), do: {:error, :invalid_result}

  # Ordered so the encoding check runs before anything that would interpret the
  # bytes as text.
  defp plain_relative_path?(path) do
    String.valid?(path) and String.trim(path) == path and Path.type(path) == :relative and
      not String.contains?(path, ["\\", <<0>>]) and
      not String.match?(path, ~r/[\x00-\x1f\x7f]/u)
  end

  defp digest(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: {:ok, value}, else: :error
  end

  defp digest(_value), do: :error

  defp valid_line_count?(0, 0), do: true
  defp valid_line_count?(bytes, line_count) when bytes > 0, do: line_count <= bytes
  defp valid_line_count?(_bytes, _line_count), do: false

  defp failure_code(reason) when is_atom(reason), do: failure_code(Atom.to_string(reason))

  defp failure_code(reason) when reason in @failure_codes, do: {:ok, reason}
  defp failure_code(_reason), do: {:error, :invalid_result}

  defp ordered_unique?(values) do
    paths = Enum.map(values, &Map.fetch!(&1, "path"))
    paths == Enum.sort(paths) and length(paths) == length(Enum.uniq(paths))
  end

  defp map_each(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp atomize_finding(
         %{
           "category" => category,
           "path" => path,
           "bytes" => bytes,
           "sha256" => sha256,
           "line_count" => line_count
         } = finding
       )
       when map_size(finding) == 5 do
    %{category: category, path: path, bytes: bytes, sha256: sha256, line_count: line_count}
  end

  defp atomize_finding(_finding), do: :invalid

  defp atomize_structure(%{"path" => path, "kind" => kind} = entry)
       when map_size(entry) == 2,
       do: %{path: path, kind: kind}

  defp atomize_structure(_entry), do: :invalid

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp encoded_size(result) do
    result
    |> to_value()
    |> :erlang.term_to_binary([:deterministic])
    |> byte_size()
  end
end
