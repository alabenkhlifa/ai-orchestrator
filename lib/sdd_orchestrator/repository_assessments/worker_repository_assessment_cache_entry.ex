defmodule SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessmentCacheEntry do
  @moduledoc """
  One complete, minimized worker-local repository-assessment cache value.

  Request-specific assessment, disclosure, and worker references are excluded.
  Reuse is bound only to the approved exact cache key, and the stored evidence
  can be rebound to a later command only after the current result contract
  accepts it again.
  """

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult
  }

  @enforce_keys [
    :key,
    :findings,
    :structure,
    :stats,
    :cache_key_sha256,
    :evidence_sha256,
    :encoded_bytes
  ]
  defstruct @enforce_keys

  @type key ::
          {pos_integer(), Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t(),
           pos_integer(), String.t(),
           {pos_integer(), pos_integer(), pos_integer(), pos_integer(), pos_integer()}}

  @type t :: %__MODULE__{
          key: key(),
          findings: [map()],
          structure: [map()],
          stats: map(),
          cache_key_sha256: String.t(),
          evidence_sha256: String.t(),
          encoded_bytes: pos_integer()
        }

  @doc "Builds a cache entry only from one strict completed terminal result."
  @spec new(term()) :: {:ok, t()} | {:error, :incomplete_result | :invalid_result}
  def new(%RepositoryAssessmentResult{status: "completed"} = result) do
    with true <- RepositoryAssessmentResult.valid?(result),
         {:ok, key} <- RepositoryAssessmentCacheProvenance.cache_key(result),
         {:ok, cache_key_sha256} <- RepositoryAssessmentCacheProvenance.cache_key_sha256(result),
         {:ok, evidence_sha256} <- RepositoryAssessmentCacheProvenance.evidence_sha256(result) do
      evidence = evidence(result)

      entry = %__MODULE__{
        key: key,
        findings: result.findings,
        structure: result.structure,
        stats: result.stats,
        cache_key_sha256: cache_key_sha256,
        evidence_sha256: evidence_sha256,
        encoded_bytes: encoded_size({key, evidence})
      }

      {:ok, entry}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  def new(%RepositoryAssessmentResult{} = result) do
    if RepositoryAssessmentResult.valid?(result),
      do: {:error, :incomplete_result},
      else: {:error, :invalid_result}
  end

  def new(_result), do: {:error, :invalid_result}

  @doc "Returns the exact cache key for a valid current command."
  @spec key(term()) :: {:ok, key()} | {:error, :invalid_command}
  def key(%RepositoryAssessmentCommand{} = command) do
    case RepositoryAssessmentCacheProvenance.cache_key(command) do
      {:ok, cache_key} -> {:ok, cache_key}
      {:error, :invalid_cache_binding} -> {:error, :invalid_command}
    end
  end

  def key(_command), do: {:error, :invalid_command}

  @doc "Rebinds cached evidence to a later command with the same exact cache key."
  @spec reuse(t(), term()) :: {:ok, map()} | {:error, :stale | :invalid_entry}
  def reuse(%__MODULE__{} = entry, %RepositoryAssessmentCommand{} = command) do
    with {:ok, command_key} <- key(command),
         true <- command_key == entry.key,
         true <- valid_digests?(entry),
         worker_result <- worker_result(entry, command),
         {:ok, _result} <- RepositoryAssessmentResult.completed(command, worker_result) do
      {:ok, worker_result}
    else
      false -> {:error, :stale}
      {:error, :invalid_command} -> {:error, :stale}
      {:error, :invalid_result} -> {:error, :invalid_entry}
    end
  end

  def reuse(_entry, _command), do: {:error, :invalid_entry}

  @doc false
  @spec provenance(t(), String.t(), boolean()) ::
          RepositoryAssessmentCacheProvenance.t() | {:error, :invalid_cache_provenance}
  def provenance(%__MODULE__{} = entry, source, stored?)
      when source in ["fresh_scan", "complete_cache"] and is_boolean(stored?) do
    case RepositoryAssessmentCacheProvenance.new(%{
           source: source,
           cache_key_sha256: entry.cache_key_sha256,
           evidence_sha256: entry.evidence_sha256,
           cache_stored: stored?
         }) do
      {:ok, provenance} -> provenance
      {:error, :invalid_cache_provenance} = error -> error
    end
  end

  def provenance(_entry, _source, _stored?), do: {:error, :invalid_cache_provenance}

  defp evidence(result) do
    {result.findings, result.structure, result.stats}
  end

  defp valid_digests?(entry) do
    entry.cache_key_sha256 == RepositoryAssessmentCacheProvenance.cache_key_digest(entry.key) and
      entry.evidence_sha256 ==
        RepositoryAssessmentCacheProvenance.evidence_sha256(
          entry.findings,
          entry.structure,
          entry.stats
        ) and
      entry.encoded_bytes ==
        encoded_size({entry.key, {entry.findings, entry.structure, entry.stats}})
  end

  defp worker_result(entry, command) do
    %{
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
      findings: Enum.map(entry.findings, &atomize_finding/1),
      structure: Enum.map(entry.structure, &atomize_structure/1),
      stats: atomize_stats(entry.stats)
    }
  end

  defp atomize_finding(finding) do
    %{
      category: finding["category"],
      path: finding["path"],
      bytes: finding["bytes"],
      sha256: finding["sha256"],
      line_count: finding["line_count"]
    }
  end

  defp atomize_structure(entry), do: %{path: entry["path"], kind: entry["kind"]}

  defp atomize_stats(stats) do
    %{
      discovered_paths: stats["discovered_paths"],
      inspected_files: stats["inspected_files"],
      bytes_read: stats["bytes_read"]
    }
  end

  defp encoded_size(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> byte_size()
  end
end
