defmodule SddOrchestrator.Delivery.WorkerProtocol do
  @moduledoc """
  Versioned vocabulary shared by the control plane and a configured worker.

  This module owns the protocol version, the negotiated capability names, the
  command operations, the normalized event types, and the stable identifier
  format. It performs no transport, dispatch, or persistence; the worker
  gateway and delivery store consume these values.
  """

  alias SddOrchestrator.Delivery.ProtocolLimits

  @version 1
  @supported_versions [1]

  @required_capabilities ~w(
    run.cancel
    run.reconcile
    run.resume
    run.retry
    run.start
    evidence.required_checks
    workspace.isolated_branch
  )

  @optional_capabilities ~w(
    agent.thread_resume
    evidence.screenshot
    preview.request
    repository_metadata
    repository_selection
  )

  @envelope_types ~w(acknowledgement command event heartbeat reconciliation_snapshot)
  @command_operations ~w(cancel reconcile resume retry start)
  @manifest_operations ~w(resume retry start)
  @event_types ~w(
    blocked
    canceled
    evidence
    failed
    progress
    verification_completed
    workspace_ready
  )
  @event_sources ~w(agent check worker)
  @acknowledgement_statuses ~w(accepted duplicate rejected)
  @heartbeat_states ~w(blocked idle running stopping)
  @attempt_states ~w(blocked canceled failed running stopped)

  @id_pattern ~r/\A[A-Za-z0-9_-]+\z/

  @spec version() :: pos_integer()
  def version, do: @version

  @spec supported_versions() :: [pos_integer()]
  def supported_versions, do: @supported_versions

  @spec supported_version?(term()) :: boolean()
  def supported_version?(version), do: version in @supported_versions

  @spec required_capabilities() :: [String.t()]
  def required_capabilities, do: @required_capabilities

  @spec optional_capabilities() :: [String.t()]
  def optional_capabilities, do: @optional_capabilities

  @spec capabilities() :: [String.t()]
  def capabilities, do: Enum.sort(@required_capabilities ++ @optional_capabilities)

  @spec envelope_types() :: [String.t()]
  def envelope_types, do: @envelope_types

  @spec command_operations() :: [String.t()]
  def command_operations, do: @command_operations

  @spec manifest_operations() :: [String.t()]
  def manifest_operations, do: @manifest_operations

  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @spec event_sources() :: [String.t()]
  def event_sources, do: @event_sources

  @spec acknowledgement_statuses() :: [String.t()]
  def acknowledgement_statuses, do: @acknowledgement_statuses

  @spec heartbeat_states() :: [String.t()]
  def heartbeat_states, do: @heartbeat_states

  @spec attempt_states() :: [String.t()]
  def attempt_states, do: @attempt_states

  @doc """
  Resolves the capability contract for one worker announcement.

  An incompatible protocol version or a missing required capability fails
  closed before any command is dispatched. Unknown capability names are
  ignored rather than granted so a worker cannot widen its own contract.
  """
  @spec negotiate(map()) ::
          {:ok, %{protocol_version: pos_integer(), capabilities: [String.t()]}}
          | {:error, atom()}
  def negotiate(%{"protocol_version" => version, "capabilities" => announced})
      when is_list(announced) do
    with :ok <- validate_version(version),
         :ok <- validate_capability_count(announced),
         {:ok, granted} <- grant_capabilities(announced) do
      {:ok, %{protocol_version: version, capabilities: granted}}
    end
  end

  def negotiate(_announcement), do: {:error, :invalid_announcement}

  @doc """
  Generates one stable opaque identifier for a command, attempt, or event.
  """
  @spec generate_id() :: String.t()
  def generate_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  @spec valid_id?(term()) :: boolean()
  def valid_id?(value) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= ProtocolLimits.get(:max_id_bytes) and
      Regex.match?(@id_pattern, value)
  end

  def valid_id?(_value), do: false

  defp validate_version(version) do
    if supported_version?(version), do: :ok, else: {:error, :unsupported_protocol_version}
  end

  defp validate_capability_count(announced) do
    if length(announced) <= ProtocolLimits.get(:max_capabilities) do
      :ok
    else
      {:error, :too_many_capabilities}
    end
  end

  defp grant_capabilities(announced) do
    known = capabilities()
    granted = announced |> Enum.filter(&(&1 in known)) |> Enum.uniq() |> Enum.sort()

    case Enum.reject(@required_capabilities, &(&1 in granted)) do
      [] -> {:ok, granted}
      _missing -> {:error, :missing_required_capability}
    end
  end
end
