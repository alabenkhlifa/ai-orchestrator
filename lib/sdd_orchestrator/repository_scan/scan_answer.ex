defmodule SddOrchestrator.RepositoryScan.ScanAnswer do
  @moduledoc """
  A worker's answer to one open scan request.

  The worker runs the bounded worker-local scanner over the folder it is
  already holding and sends back only what that scanner already minimized:
  the findings, the structure, the stats, and the six managed-runtime proposal
  fields derived from them. Or a refusal. Or a cancellation.

  ## What is deliberately absent

  A scanner result also repeats the command it was run for: its protocol
  version, assessment and project ids, repository identity, root, commit, and
  scanner-contract digest. None of that crosses. The control plane issued the
  command and still holds it, and a worker echoing those fields back proves
  nothing, because a worker that would lie about them would echo them
  correctly. `RepositoryAssessments` rebuilds the full scanner result by
  putting its own command fields beside the three evidence fields here, so the
  narrower answer is also the stricter one.

  The proposal's own digests are absent for the same reason. `commands`,
  `required_checks`, `allowed_scope`, `gaps`, `conflicts`, and
  `multi_root_blockers` are the only proposal values a worker derives;
  `RepositoryExecutionProfileProposalPayload.new/2` re-derives the cache key,
  the evidence digest, and the payload digest from the result the control
  plane built.

  `provenance` is the exception that proves the rule. Its `source` and
  `cache_stored` say whether this answer came from a fresh read or the
  worker's exact-commit cache, and whether the worker kept it. Neither is
  derivable here, because both are facts about a cache the control plane
  cannot see. They cross for that reason, and the two digests that complete a
  `RepositoryAssessmentCacheProvenance` still do not.

  ## Why `new/1` is strict

  A worker answer arrives from outside the control plane, so an unknown
  outcome, an unrecognised refusal reason, a missing field for the outcome
  that requires it, or any key this module does not recognise is refused as
  `:invalid_result` before it can reach a requester. The recognised-key rule
  at every level, including inside each finding and each structure entry, is
  what keeps a stray field such as an absolute path out of a worker's answer.

  The refusal reasons are exactly the bounded scanner's own terminal errors,
  which are also `RepositoryAssessmentResult`'s allowlisted failure codes,
  plus `selection_expired` for a folder the worker is no longer holding.
  """

  @enforce_keys [:request_id, :outcome]
  defstruct [
    :request_id,
    :outcome,
    :findings,
    :structure,
    :stats,
    :proposal,
    :provenance,
    :reason
  ]

  @outcomes [:scanned, :refused, :cancelled]

  @refusal_reasons [
    :file_limit_exceeded,
    :file_size_limit_exceeded,
    :invalid_command,
    :path_limit_exceeded,
    :repository_unavailable,
    :root_escape,
    :selection_expired,
    :stale_commit,
    :time_limit_exceeded,
    :total_byte_limit_exceeded
  ]

  @keys [
    :request_id,
    :outcome,
    :findings,
    :structure,
    :stats,
    :proposal,
    :provenance,
    :reason
  ]
  @finding_keys [:category, :path, :bytes, :sha256, :line_count]
  @structure_keys [:path, :kind]
  @stats_keys [:discovered_paths, :inspected_files, :bytes_read]
  @provenance_keys [:source, :cache_stored]
  @proposal_keys [
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers
  ]

  @typedoc "What the worker did with the request."
  @type outcome :: :scanned | :refused | :cancelled

  @typedoc "Why the worker refused to scan."
  @type refusal_reason ::
          :file_limit_exceeded
          | :file_size_limit_exceeded
          | :invalid_command
          | :path_limit_exceeded
          | :repository_unavailable
          | :root_escape
          | :selection_expired
          | :stale_commit
          | :time_limit_exceeded
          | :total_byte_limit_exceeded

  @type t :: %__MODULE__{
          request_id: String.t(),
          outcome: outcome(),
          findings: [map()] | nil,
          structure: [map()] | nil,
          stats: map() | nil,
          proposal: map() | nil,
          provenance: map() | nil,
          reason: refusal_reason() | nil
        }

  @doc "The refusal reasons a worker may answer with."
  @spec refusal_reasons() :: [refusal_reason()]
  def refusal_reasons, do: @refusal_reasons

  @doc "The proposal fields a worker derives and this answer carries."
  @spec proposal_keys() :: [atom()]
  def proposal_keys, do: @proposal_keys

  @doc "The cache-provenance values only the worker can know."
  @spec provenance_keys() :: [atom()]
  def provenance_keys, do: @provenance_keys

  @doc """
  Builds one answer from a worker's plain map, with string or atom keys.

  Returns `{:error, :invalid_result}` for anything a trusted worker would
  never send, so a malformed or hostile answer is refused at the boundary
  rather than delivered to a requester. The evidence it carries is rebuilt
  with atom keys, which is the shape
  `RepositoryAssessments.RepositoryAssessmentResult.completed/2` validates.
  """
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_result}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_keys(attrs, @keys),
         {:ok, request_id} <- fetch_binary(attrs, :request_id),
         {:ok, outcome} <- fetch_outcome(attrs),
         {:ok, fields} <- fetch_outcome_fields(outcome, attrs) do
      {:ok, struct!(__MODULE__, Map.merge(%{request_id: request_id, outcome: outcome}, fields))}
    end
  end

  def new(_attrs), do: {:error, :invalid_result}

  # Every key is checked against the allowlist before anything is read, so an
  # unrecognised key is refused even when the rest of the answer is valid.
  defp normalize_keys(attrs, allowed) when is_map(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case known_key(key, allowed) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, :invalid_result}}
      end
    end)
  end

  defp normalize_keys(_attrs, _allowed), do: {:error, :invalid_result}

  defp known_key(key, allowed) when is_atom(key),
    do: if(key in allowed, do: {:ok, key}, else: :error)

  defp known_key(key, allowed) when is_binary(key) do
    Enum.find_value(allowed, :error, fn known ->
      if Atom.to_string(known) == key, do: {:ok, known}
    end)
  end

  defp known_key(_key, _allowed), do: :error

  defp fetch_outcome(%{outcome: outcome}) when outcome in @outcomes, do: {:ok, outcome}

  defp fetch_outcome(%{outcome: outcome}) when is_binary(outcome) do
    Enum.find_value(@outcomes, {:error, :invalid_result}, fn known ->
      if Atom.to_string(known) == outcome, do: {:ok, known}
    end)
  end

  defp fetch_outcome(_attrs), do: {:error, :invalid_result}

  # A "scanned" answer must carry every evidence field and the proposal: it is
  # the only outcome a requester's blocked call resolves into a result.
  defp fetch_outcome_fields(:scanned, attrs) do
    with {:ok, findings} <- fetch_entries(attrs, :findings, @finding_keys),
         {:ok, structure} <- fetch_entries(attrs, :structure, @structure_keys),
         {:ok, stats} <- fetch_map(attrs, :stats, @stats_keys),
         {:ok, proposal} <- fetch_map(attrs, :proposal, @proposal_keys),
         {:ok, provenance} <- fetch_map(attrs, :provenance, @provenance_keys) do
      {:ok,
       %{
         findings: findings,
         structure: structure,
         stats: stats,
         proposal: proposal,
         provenance: provenance
       }}
    end
  end

  defp fetch_outcome_fields(:refused, attrs) do
    with {:ok, reason} <- fetch_reason(attrs) do
      {:ok, %{reason: reason}}
    end
  end

  defp fetch_outcome_fields(:cancelled, _attrs), do: {:ok, %{}}

  defp fetch_entries(attrs, key, allowed) do
    case Map.get(attrs, key) do
      entries when is_list(entries) -> map_each(entries, &normalize_keys(&1, allowed))
      _other -> {:error, :invalid_result}
    end
  end

  defp fetch_map(attrs, key, allowed) do
    case Map.get(attrs, key) do
      value when is_map(value) -> normalize_keys(value, allowed)
      _other -> {:error, :invalid_result}
    end
  end

  defp map_each(values, mapper) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
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

  defp fetch_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid_result}
    end
  end

  defp fetch_reason(%{reason: reason}) when reason in @refusal_reasons, do: {:ok, reason}

  defp fetch_reason(%{reason: reason}) when is_binary(reason) do
    Enum.find_value(@refusal_reasons, {:error, :invalid_result}, fn known ->
      if Atom.to_string(known) == reason, do: {:ok, known}
    end)
  end

  defp fetch_reason(_attrs), do: {:error, :invalid_result}
end
