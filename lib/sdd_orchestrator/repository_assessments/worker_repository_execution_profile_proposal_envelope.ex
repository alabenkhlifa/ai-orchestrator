defmodule SddOrchestrator.RepositoryAssessments.WorkerRepositoryExecutionProfileProposalEnvelope do
  @moduledoc """
  Transient minimized delivery binding for one current assessment command.

  The cache-stable proposal payload is copied into this value, while every
  assessment-specific field and the completed-result digest are rebound before
  delivery. This worker value is not authoritative persistence.
  """

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryExecutionProfileProposalPayload
  }

  @version 1
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
    :cache_key_sha256,
    :evidence_sha256,
    :result_sha256,
    :payload_digest,
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers,
    :envelope_digest
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @doc "Binds a valid cache-stable payload to the exact current command and result."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, :invalid_proposal_envelope}
  def new(
        %RepositoryExecutionProfileProposalPayload{} = payload,
        %RepositoryAssessmentCommand{} = command,
        %RepositoryAssessmentResult{status: "completed"} = result
      ) do
    case RepositoryExecutionProfileProposalPayload.valid_for?(payload, command, result) do
      true ->
        values = %{
          version: @version,
          assessment_id: command.assessment_id,
          project_id: command.project_id,
          repository_provider: command.repository_provider,
          repository_id: command.repository_id,
          root: command.root,
          commit: command.commit,
          scanner_contract_digest: command.scanner_contract_digest,
          disclosure_digest: command.disclosure_digest,
          worker_ref: command.worker_ref,
          limits: command.limits,
          cache_key_sha256: payload.cache_key_sha256,
          evidence_sha256: payload.evidence_sha256,
          result_sha256: RepositoryExecutionProfileProposalPayload.result_sha256(result),
          payload_digest: payload.payload_digest,
          commands: payload.commands,
          required_checks: payload.required_checks,
          allowed_scope: payload.allowed_scope,
          gaps: payload.gaps,
          conflicts: payload.conflicts,
          multi_root_blockers: payload.multi_root_blockers
        }

        {:ok, struct!(__MODULE__, Map.put(values, :envelope_digest, digest(values)))}

      _invalid ->
        {:error, :invalid_proposal_envelope}
    end
  rescue
    _error -> {:error, :invalid_proposal_envelope}
  end

  def new(_payload, _command, _result), do: {:error, :invalid_proposal_envelope}

  @doc "Confirms no cached or caller-supplied prior assessment binding was reused."
  @spec valid_for?(term(), term(), term(), term()) :: boolean()
  def valid_for?(
        %__MODULE__{} = envelope,
        %RepositoryExecutionProfileProposalPayload{} = payload,
        %RepositoryAssessmentCommand{} = command,
        %RepositoryAssessmentResult{} = result
      ) do
    match?({:ok, ^envelope}, new(payload, command, result))
  rescue
    _error -> false
  end

  def valid_for?(_envelope, _payload, _command, _result), do: false

  @doc "Serializes the exact minimized transient delivery value."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = envelope) do
    envelope
    |> Map.take(@fields)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), stringify_limits(key, value)} end)
  end

  defp stringify_limits(:limits, limits),
    do: Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)

  defp stringify_limits(_key, value), do: value

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
