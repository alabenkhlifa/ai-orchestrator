defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCacheProvenance do
  @moduledoc """
  Strict minimized provenance for one completed repository assessment.

  The worker supplies the source and storage outcome. Cache-key and evidence
  digests are recalculated from the exact command and completed result before
  authoritative persistence; no provenance field is inferred from evidence.
  """

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult
  }

  @cache_contract_version 1
  @fields [:source, :cache_key_sha256, :evidence_sha256, :cache_stored]
  @sources ["fresh_scan", "complete_cache"]
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @enforce_keys @fields
  defstruct @fields

  @type source :: String.t()
  @type t :: %__MODULE__{
          source: source(),
          cache_key_sha256: String.t(),
          evidence_sha256: String.t(),
          cache_stored: boolean()
        }

  @doc "Builds only the exact minimized worker-reported value."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_cache_provenance}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs),
         true <- attrs.source in @sources,
         true <- digest?(attrs.cache_key_sha256),
         true <- digest?(attrs.evidence_sha256),
         true <- is_boolean(attrs.cache_stored),
         true <- attrs.source != "complete_cache" or attrs.cache_stored do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _invalid -> {:error, :invalid_cache_provenance}
    end
  rescue
    _error -> {:error, :invalid_cache_provenance}
  end

  def new(_attrs), do: {:error, :invalid_cache_provenance}

  @doc "Validates worker provenance against the exact command and completed evidence."
  @spec validate(term(), term(), term()) :: {:ok, t()} | {:error, :invalid_cache_provenance}
  def validate(
        provenance,
        %RepositoryAssessmentCommand{} = command,
        %RepositoryAssessmentResult{} = result
      ) do
    with {:ok, provenance} <- cast(provenance),
         true <- RepositoryAssessmentCommand.valid?(command),
         true <- RepositoryAssessmentResult.valid?(result),
         true <- result.status == "completed",
         true <- RepositoryAssessmentResult.matches_command?(result, command),
         {:ok, expected_cache_digest} <- cache_key_sha256(command),
         {:ok, expected_evidence_digest} <- evidence_sha256(result),
         true <- provenance.cache_key_sha256 == expected_cache_digest,
         true <- provenance.evidence_sha256 == expected_evidence_digest do
      {:ok, provenance}
    else
      _invalid -> {:error, :invalid_cache_provenance}
    end
  rescue
    _error -> {:error, :invalid_cache_provenance}
  end

  def validate(_provenance, _command, _result), do: {:error, :invalid_cache_provenance}

  @doc "Returns the canonical Task 9 cache key for a strict command or completed result."
  @spec cache_key(term()) :: {:ok, tuple()} | {:error, :invalid_cache_binding}
  def cache_key(%RepositoryAssessmentCommand{} = command) do
    if RepositoryAssessmentCommand.valid?(command) do
      {:ok,
       key(
         command.project_id,
         command.repository_provider,
         command.repository_id,
         command.root,
         command.commit,
         command.version,
         command.scanner_contract_digest,
         command.limits
       )}
    else
      {:error, :invalid_cache_binding}
    end
  end

  def cache_key(%RepositoryAssessmentResult{status: "completed"} = result) do
    if RepositoryAssessmentResult.valid?(result) do
      {:ok,
       key(
         result.project_id,
         result.repository_provider,
         result.repository_id,
         result.root,
         result.commit,
         result.version,
         result.scanner_contract_digest,
         result.limits
       )}
    else
      {:error, :invalid_cache_binding}
    end
  end

  def cache_key(_value), do: {:error, :invalid_cache_binding}

  @doc false
  @spec cache_key_sha256(term()) :: {:ok, String.t()} | {:error, :invalid_cache_binding}
  def cache_key_sha256(value) do
    with {:ok, cache_key} <- cache_key(value) do
      {:ok, digest({:cache_key, cache_key})}
    end
  end

  @doc false
  @spec evidence_sha256(term()) :: {:ok, String.t()} | {:error, :invalid_cache_evidence}
  def evidence_sha256(%RepositoryAssessmentResult{status: "completed"} = result) do
    if RepositoryAssessmentResult.valid?(result),
      do: {:ok, evidence_sha256(result.findings, result.structure, result.stats)},
      else: {:error, :invalid_cache_evidence}
  end

  def evidence_sha256(_result), do: {:error, :invalid_cache_evidence}

  @doc false
  @spec cache_key_digest(tuple()) :: String.t()
  def cache_key_digest(cache_key) when is_tuple(cache_key), do: digest({:cache_key, cache_key})

  @doc false
  @spec evidence_sha256(list(), list(), map()) :: String.t()
  def evidence_sha256(findings, structure, stats)
      when is_list(findings) and is_list(structure) and is_map(stats) do
    digest({:evidence, {findings, structure, stats}})
  end

  @doc "Serializes exactly the minimized provenance fields."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = provenance) do
    provenance
    |> Map.take(@fields)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc false
  @spec complete?(term()) :: boolean()
  def complete?(%__MODULE__{} = provenance),
    do: match?({:ok, ^provenance}, new(Map.from_struct(provenance)))

  def complete?(_provenance), do: false

  defp cast(%__MODULE__{} = provenance), do: new(Map.from_struct(provenance))
  defp cast(value), do: new(value)

  defp normalize_attrs(attrs) do
    atom_keys = MapSet.new(@fields)
    string_keys = MapSet.new(Enum.map(@fields, &Atom.to_string/1))

    case MapSet.new(Map.keys(attrs)) do
      ^atom_keys -> {:ok, Map.take(attrs, @fields)}
      ^string_keys -> {:ok, Map.new(@fields, &{&1, attrs[Atom.to_string(&1)]})}
      _unknown -> {:error, :invalid_cache_provenance}
    end
  end

  defp key(project_id, provider, repository_id, root, commit, version, scanner_digest, limits) do
    {
      @cache_contract_version,
      project_id,
      provider,
      repository_id,
      root,
      commit,
      version,
      scanner_digest,
      limits_tuple(limits)
    }
  end

  defp limits_tuple(limits) do
    {
      limits.max_paths,
      limits.max_files,
      limits.max_total_bytes,
      limits.max_file_bytes,
      limits.timeout_ms
    }
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_pattern, value)

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
