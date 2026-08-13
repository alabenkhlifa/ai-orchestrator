defmodule SddOrchestrator.ProjectAssistant.ProcessingSummary do
  @moduledoc """
  Builds the versioned processing summary business rule 69 requires
  disclosing before the first answered question, and its stable digest.

  The summary states only the configured AI execution location and
  provider, whether a repository worker may be used, what boundary project
  or source content may cross, where conversation history and its index are
  stored, and the current retention boundary. Every input comes from
  `SddOrchestrator.ProjectAssistant.RuntimeAvailability.resolve/3`'s already
  safe fields and a plain worker-available boolean — never a credential,
  exact quota, or provider diagnostic.
  """

  @version 1
  @max_retention_days 30

  @type storage_mode :: :hosted | :device

  @doc "Builds one processing summary from safe runtime, worker, and storage facts."
  @spec build(map(), boolean(), storage_mode()) :: map()
  def build(%{} = runtime, repository_worker_available?, storage_mode)
      when is_boolean(repository_worker_available?) and storage_mode in [:hosted, :device] do
    %{
      version: @version,
      execution: %{
        location: :participant_personal_worker,
        provider: Map.get(runtime, :provider),
        authentication_mode: Map.get(runtime, :authentication_mode)
      },
      repository_worker_available: repository_worker_available?,
      transfer_boundary: transfer_boundary(repository_worker_available?),
      storage: %{conversation: storage_mode, index: storage_mode},
      retention: %{max_days: @max_retention_days}
    }
  end

  @doc "The stable digest of one processing summary's disclosed fields."
  @spec digest(map()) :: String.t()
  def digest(%{} = summary) do
    summary
    |> canonical_terms()
    |> Enum.map_join(fn term -> "#{byte_size(term)}:#{term}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The current processing-summary schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The approved maximum conversation-retention window, in days."
  @spec max_retention_days() :: pos_integer()
  def max_retention_days, do: @max_retention_days

  defp transfer_boundary(true), do: :project_context_and_on_demand_repository_source
  defp transfer_boundary(false), do: :project_context_only

  defp canonical_terms(summary) do
    [
      summary.version,
      summary.execution.location,
      summary.execution.provider,
      summary.execution.authentication_mode,
      summary.repository_worker_available,
      summary.transfer_boundary,
      summary.storage.conversation,
      summary.storage.index,
      summary.retention.max_days
    ]
    |> Enum.map(&term_to_string/1)
  end

  defp term_to_string(nil), do: "nil"
  defp term_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp term_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp term_to_string(value) when is_binary(value), do: value
end
