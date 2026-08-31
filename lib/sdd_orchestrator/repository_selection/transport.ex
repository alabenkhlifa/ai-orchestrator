defmodule SddOrchestrator.RepositorySelection.Transport do
  @moduledoc """
  How a selection request reaches the Mac's attached worker.

  The request lifecycle owns correlation, expiry, cancellation, and the single
  outcome; this boundary owns only the hand-off. Keeping them apart is what
  lets the lifecycle be proven without an attached worker, and lets the
  attachment be replaced without touching who may answer or how many times.

  `push/1` reports whether the request left the control plane, never what the
  person chose. It answers with the pid of the attached worker's channel
  process, because a request that outlives its worker must end as
  `:worker_lost` rather than wait for a timeout that will never be answered.
  `cancel/1` tells the worker to close its panel and is fire and forget: the
  request is already gone on this side.

  Nothing here carries a filesystem path, a remote URL, or a file name. A
  request holds identities and a worker's answer holds verdicts.
  """

  alias SddOrchestrator.RepositorySelection.SelectionRequest

  @typedoc "Why a request could not leave the control plane."
  @type reason :: :no_worker | :worker_needs_update | :transport_error

  @callback push(SelectionRequest.t()) :: {:ok, pid()} | {:error, reason()}
  @callback cancel(SelectionRequest.t()) :: :ok

  @doc "The configured transport, defaulting to the unavailable-worker stand-in."
  @spec transport() :: module()
  def transport do
    Application.get_env(
      :sdd_orchestrator,
      :repository_selection_transport,
      SddOrchestrator.RepositorySelection.Transport.Unavailable
    )
  end
end

defmodule SddOrchestrator.RepositorySelection.Transport.Unavailable do
  @moduledoc """
  The default transport: no worker is attached.

  A request is refused at once rather than left open, which is the correct
  behaviour before the attachment transport exists and whenever no worker is
  attached for the asking workspace. The person is told the worker is not
  there instead of watching a panel that will never open.
  """
  @behaviour SddOrchestrator.RepositorySelection.Transport

  @impl true
  def push(_request), do: {:error, :no_worker}

  @impl true
  def cancel(_request), do: :ok
end
