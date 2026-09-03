defmodule SddOrchestrator.RepositoryMetadata.Transport do
  @moduledoc """
  How a metadata request reaches the Mac's attached worker.

  The request lifecycle owns correlation, expiry, cancellation, and the
  single outcome; this boundary owns only the hand-off. Keeping them apart is
  what lets the lifecycle be proven without an attached worker, and lets the
  attachment be replaced without touching who may answer or how many times.

  `push/1` reports whether the request left the control plane, never what the
  worker found. It answers with the pid of the attached worker's channel
  process, because a request that outlives its worker must resolve the
  blocked caller to `:worker_unavailable` rather than wait for a timeout that
  will never be answered. `cancel/1` tells the worker to stop and is fire and
  forget: the request is already gone on this side.

  Nothing here carries a filesystem path, a remote URL, or a file name. A
  request holds opaque references and a worker's answer holds verdicts.
  """

  alias SddOrchestrator.RepositoryMetadata.MetadataRequest

  @typedoc "Why a request could not leave the control plane."
  @type reason :: :no_worker | :worker_needs_update | :transport_error

  @callback push(MetadataRequest.t()) :: {:ok, pid()} | {:error, reason()}
  @callback cancel(MetadataRequest.t()) :: :ok

  @doc "The configured transport, defaulting to the unavailable-worker stand-in."
  @spec transport() :: module()
  def transport do
    Application.get_env(
      :sdd_orchestrator,
      :repository_metadata_transport,
      SddOrchestrator.RepositoryMetadata.Transport.Unavailable
    )
  end
end

defmodule SddOrchestrator.RepositoryMetadata.Transport.Unavailable do
  @moduledoc """
  The default transport: no worker is attached.

  A request is refused at once rather than left open, which is the correct
  behaviour before the attachment transport exists and whenever no worker is
  attached for the asking workspace. The blocked caller learns the worker is
  not there instead of waiting out a request that will never be answered.
  """
  @behaviour SddOrchestrator.RepositoryMetadata.Transport

  @impl true
  def push(_request), do: {:error, :no_worker}

  @impl true
  def cancel(_request), do: :ok
end
