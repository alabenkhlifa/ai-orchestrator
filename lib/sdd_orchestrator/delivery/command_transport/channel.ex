defmodule SddOrchestrator.Delivery.CommandTransport.EnvelopeSource do
  @moduledoc """
  Where a claimed command's protocol payload comes from.

  The outbox records identities, a manifest digest, and a due time — never the
  manifest body or a cancellation reason — so the durable row alone cannot
  rebuild the envelope its worker must receive. The transaction that enqueued
  the command owns that content, and this is where it supplies it.

  Until a producing task installs a source, delivery fails closed rather than
  pushing a partial envelope. The command stays queued, which is the same
  outcome as having no worker attached.
  """

  alias SddOrchestrator.Delivery.RunCommand

  @callback envelope(RunCommand.t()) :: {:ok, map()} | {:error, atom()}

  @doc "The configured source, or `nil` while none is installed."
  @spec source() :: module() | nil
  def source, do: Application.get_env(:sdd_orchestrator, :command_envelope_source)

  @doc "Builds the protocol envelope for one durable command."
  @spec envelope(RunCommand.t()) :: {:ok, map()} | {:error, atom()}
  def envelope(%RunCommand{} = command) do
    case source() do
      nil -> {:error, :envelope_source_unavailable}
      module -> module.envelope(command)
    end
  end
end

defmodule SddOrchestrator.Delivery.CommandTransport.Channel do
  @moduledoc """
  Hands one claimed command to the worker currently attached for its project.

  Workers dial in and register themselves here when they join their project
  topic, so delivery is a lookup rather than an outbound connection. Nothing
  authoritative lives in the registry: after a restart every worker reconnects,
  and the queue is still the database.

  Two refusals stay distinguishable on purpose. `:no_worker` means the work is
  still wanted and nobody is listening yet; `:incompatible_worker` means
  somebody is listening but has not negotiated the contract this envelope
  needs. Neither is a delivery, and both leave the command claimed until its
  lease expires.

  The envelope is checked against the durable row before it is pushed. A source
  that answered with another command's envelope, or with one whose operation,
  expected version, or manifest no longer matches the record, is a defect that
  must never reach a worker.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport

  alias SddOrchestrator.Delivery.CommandTransport.EnvelopeSource
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.RunCommand
  alias SddOrchestrator.Delivery.WorkerProtocol

  @registry SddOrchestrator.Delivery.WorkerRegistry

  @type contract :: %{
          worker_id: String.t(),
          protocol_version: pos_integer(),
          capabilities: [String.t()],
          attached_at: DateTime.t()
        }

  @doc "The registry of attached workers, keyed by project."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  Registers the calling process as a worker attached for one project.

  Registration is duplicate-keyed deliberately: a reconnect can briefly overlap
  the connection it replaces, and refusing the newcomer would strand the worker
  until the abandoned channel process died. Delivery is at least once and
  command IDs are idempotent, so an overlap costs a redelivery, never a second
  agent process.
  """
  @spec attach(Ecto.UUID.t(), map()) :: {:ok, pid()} | {:error, term()}
  def attach(project_id, contract) do
    Registry.register(@registry, project_id, %{
      worker_id: Map.fetch!(contract, :worker_id),
      protocol_version: Map.fetch!(contract, :protocol_version),
      capabilities: Map.fetch!(contract, :capabilities),
      attached_at: DateTime.utc_now()
    })
  end

  @doc "The workers currently attached for one project."
  @spec attached(Ecto.UUID.t()) :: [{pid(), contract()}]
  def attached(project_id), do: Registry.lookup(@registry, project_id)

  @impl true
  def deliver(%RunCommand{} = command) do
    case attached(command.project_id) do
      [] -> {:error, :no_worker}
      workers -> push(workers, command)
    end
  end

  defp push(workers, command) do
    with {:ok, envelope} <- EnvelopeSource.envelope(command),
         :ok <- ProtocolCodec.validate(envelope),
         :ok <- confirm_binding(command, envelope),
         {:ok, worker} <- compatible_worker(workers, envelope) do
      send(worker, {:deliver_command, envelope})
      :ok
    else
      {:error, :incompatible_worker} = refusal -> refusal
      {:error, _reason} -> {:error, :transport_error}
    end
  end

  defp confirm_binding(command, envelope) do
    bound? =
      envelope["type"] == "command" and
        envelope["command_id"] == command.id and
        envelope["project_id"] == command.project_id and
        envelope["run_id"] == command.run_id and
        envelope["operation"] == command.operation and
        envelope["expected_state_version"] == command.expected_state_version and
        digest_bound?(command, envelope)

    if bound?, do: :ok, else: {:error, :envelope_binding_mismatch}
  end

  # A control command records no manifest of its own, yet the protocol still
  # names the attempt manifest it acts on, so only a recorded digest is compared.
  defp digest_bound?(%RunCommand{manifest_digest: nil}, _envelope), do: true

  defp digest_bound?(command, envelope),
    do: envelope["manifest_digest"] == command.manifest_digest

  defp compatible_worker(workers, envelope) do
    version = envelope["protocol_version"]
    capability = "run." <> envelope["operation"]

    case Enum.find(workers, fn {_pid, contract} ->
           compatible?(contract, version, capability)
         end) do
      {worker, _contract} -> {:ok, worker}
      nil -> {:error, :incompatible_worker}
    end
  end

  # The negotiated version is re-checked against the versions this control plane
  # still supports, so a worker that outlived support for its contract is
  # refused instead of being sent an envelope it cannot read.
  defp compatible?(contract, version, capability) do
    contract.protocol_version == version and
      WorkerProtocol.supported_version?(contract.protocol_version) and
      capability in contract.capabilities
  end
end
