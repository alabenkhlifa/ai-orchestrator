defmodule SddOrchestrator.RepositoryScan.Transport do
  @moduledoc """
  How a scan request reaches the Mac's attached worker.

  The request lifecycle owns correlation, expiry, cancellation, and the single
  outcome; this boundary owns only the hand-off. Keeping them apart is what
  lets the lifecycle be proven without an attached worker, and lets the
  attachment be replaced without touching who may answer or how many times.

  `push/1` reports whether the request left the control plane, never what the
  worker found. It answers with the pid of the attached worker's channel
  process, because a request that outlives its worker must resolve the
  blocked caller to `:worker_unavailable` rather than wait for a timeout that
  will never be answered. `cancel/1` tells the worker to stop and is fire and
  forget: the request is already gone on this side.

  Nothing here carries an absolute path, a remote URL, or file content. A
  request holds an opaque selection reference and a closed assessment command.
  """

  alias SddOrchestrator.RepositoryScan.ScanRequest

  @typedoc "Why a request could not leave the control plane."
  @type reason :: :no_worker | :worker_needs_update | :transport_error

  @callback push(ScanRequest.t()) :: {:ok, pid()} | {:error, reason()}
  @callback cancel(ScanRequest.t()) :: :ok

  @doc "The configured transport, defaulting to the unavailable-worker stand-in."
  @spec transport() :: module()
  def transport do
    Application.get_env(
      :sdd_orchestrator,
      :repository_scan_transport,
      SddOrchestrator.RepositoryScan.Transport.Unavailable
    )
  end
end

defmodule SddOrchestrator.RepositoryScan.Transport.Unavailable do
  @moduledoc """
  The default transport: no worker is attached.

  A request is refused at once rather than left open, which is the correct
  behaviour before the attachment transport exists and whenever no worker is
  attached for the asking workspace. The blocked caller learns the worker is
  not there instead of waiting out a request that will never be answered.
  """
  @behaviour SddOrchestrator.RepositoryScan.Transport

  @impl true
  def push(_request), do: {:error, :no_worker}

  @impl true
  def cancel(_request), do: :ok
end
