defmodule SddOrchestrator.Delivery.WorkerAttachment do
  @moduledoc """
  Records that one worker process is attached for one device workspace.

  A worker is authorized for its Mac before it is authorized for any project,
  so the control plane must be able to answer "is this machine's worker live?"
  without a project to ask it about. That is the whole purpose of this
  registry, and it is keyed by the device workspace the gateway credential
  named rather than by anything the worker announced about itself.

  An entry holds the worker identity, the contract it negotiated, and when it
  attached. It exists only while an authenticated channel process is alive and
  disappears with that process, so nothing here is persisted and nothing here
  is authoritative: after a restart every worker reconnects and registers
  again. An entry carries no repository path, no filename, and no source
  content, because liveness never needs them.

  Registration is duplicate-keyed deliberately: a reconnect can briefly overlap
  the connection it replaces, and refusing the newcomer would strand the worker
  until the abandoned channel process died. An overlap therefore costs a second
  entry for as long as the old process takes to go down, never a worker the
  control plane believes is gone.

  This module delivers nothing. It has no `deliver/1` and handles no envelope:
  everything a worker may execute is still scoped to a project and still
  travels through `SddOrchestrator.Delivery.CommandTransport.Channel`.
  """

  @registry SddOrchestrator.Delivery.WorkspaceWorkerRegistry

  @type contract :: %{
          worker_id: String.t(),
          protocol_version: pos_integer(),
          capabilities: [String.t()],
          attached_at: DateTime.t()
        }

  @doc "The registry of attached workers, keyed by device workspace."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  Registers the calling process as a worker attached for one device workspace.

  Registration is duplicate-keyed for the reason stated above: a reconnect that
  overlaps the connection it replaces must not be refused, because the worker
  would then stay unreachable until the abandoned channel process died.
  """
  @spec attach(Ecto.UUID.t(), map()) :: {:ok, pid()} | {:error, term()}
  def attach(device_workspace_id, contract) do
    Registry.register(@registry, device_workspace_id, %{
      worker_id: Map.fetch!(contract, :worker_id),
      protocol_version: Map.fetch!(contract, :protocol_version),
      capabilities: Map.fetch!(contract, :capabilities),
      attached_at: DateTime.utc_now()
    })
  end

  @doc "The workers currently attached for one device workspace."
  @spec attached(Ecto.UUID.t()) :: [{pid(), contract()}]
  def attached(device_workspace_id), do: Registry.lookup(@registry, device_workspace_id)
end
