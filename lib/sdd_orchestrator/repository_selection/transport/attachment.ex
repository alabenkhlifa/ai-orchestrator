defmodule SddOrchestrator.RepositorySelection.Transport.Attachment do
  @moduledoc """
  Hands one selection request to the worker attached for its Mac.

  Workers dial in and register themselves when they join their Mac-scoped
  topic, so reaching one is a lookup rather than an outbound connection. The
  registry is `SddOrchestrator.Delivery.WorkerAttachment`, which is keyed by
  the device workspace the gateway credential named. That is the whole reason
  this request can travel at all: a worker being asked to point at a folder has
  no project binding yet, so the project-scoped topic has nothing to key it by.

  The request is aimed at one named worker inside that workspace, never at
  whoever happens to be attached. A person picked a machine, and the answer
  must come back from the machine they picked.

  Three refusals stay distinguishable on purpose. `:no_worker` means the Mac's
  worker is not attached, so the person is told to open the app rather than
  watching a panel that will never appear. `:worker_needs_update` means a
  worker is attached but did not negotiate the folder-picker vocabulary, which
  is a worker too old to ask. `:transport_error` means the request itself could
  not be encoded, which is a defect on this side and never the person's fault.

  A cancellation is fire and forget. The request is already gone here, and a
  worker that has meanwhile detached needs no telling: its panel went with it.

  Nothing pushed from here holds a filesystem path, a remote URL, or a file
  name, and nothing is logged here. The payload is built by
  `SddOrchestrator.RepositorySelection.AttachmentCodec`, which is closed to
  every field but the four a request is made of.
  """
  @behaviour SddOrchestrator.RepositorySelection.Transport

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.RepositorySelection.AttachmentCodec
  alias SddOrchestrator.RepositorySelection.SelectionRequest

  @capability "repository_selection"

  @doc "The capability a worker declares at attach to be askable for a folder."
  @spec capability() :: String.t()
  def capability, do: @capability

  @impl true
  def push(%SelectionRequest{} = request) do
    with {:ok, channel} <- capable_attachment(request),
         {:ok, payload} <- encode(request) do
      send(channel, {:repository_selection, payload})
      {:ok, channel}
    end
  end

  @impl true
  def cancel(%SelectionRequest{} = request) do
    with {:ok, channel} <- capable_attachment(request),
         {:ok, payload} <- AttachmentCodec.encode_cancellation(request) do
      send(channel, {:repository_selection_cancel, payload})
    end

    :ok
  end

  # A reconnect can briefly overlap the connection it replaces, so the registry
  # is duplicate-keyed and the same worker can hold two entries. The first
  # capable one is taken, exactly as command delivery does: an overlap costs a
  # request pushed to the older channel at worst, never a worker the control
  # plane believes is gone.
  defp capable_attachment(request) do
    case named_attachments(request) do
      [] -> {:error, :no_worker}
      attachments -> first_capable(attachments)
    end
  end

  defp named_attachments(request) do
    request.device_workspace_id
    |> WorkerAttachment.attached()
    |> Enum.filter(fn {_channel, contract} -> contract.worker_id == request.worker_id end)
  end

  defp first_capable(attachments) do
    case Enum.find(attachments, fn {_channel, contract} -> capable?(contract) end) do
      {channel, _contract} -> {:ok, channel}
      nil -> {:error, :worker_needs_update}
    end
  end

  # The negotiated version is re-checked against the versions this control plane
  # still supports, so a worker that outlived support for its contract is asked
  # to update rather than sent a request it cannot read.
  defp capable?(contract) do
    WorkerProtocol.supported_version?(contract.protocol_version) and
      @capability in contract.capabilities
  end

  # An encode failure is a defect on this side, not a worker that is missing or
  # old, so it is reported as neither of those.
  defp encode(request) do
    case AttachmentCodec.encode_request(request) do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> {:error, :transport_error}
    end
  end
end
