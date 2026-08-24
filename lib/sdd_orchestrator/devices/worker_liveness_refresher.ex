defmodule SddOrchestrator.Devices.WorkerLivenessRefresher do
  @moduledoc """
  Supervised refresher that keeps an attached worker's `last_seen_at` current.

  Reachability is modeled through `LocalWorker.last_seen_at`, but nothing on the
  real outbound transport ever stamped it: only the accountless dev/test
  LiveView stand-in called `Pairing.mark_seen/1`. A genuinely connected worker
  therefore went stale once that refresh aged past
  `WorkerDiscovery.staleness_seconds/0`, and connection state reported it
  temporarily unavailable while it was live.

  A worker-initiated call cannot close that. The failing case is a connected but
  *idle* worker, which sends no run heartbeat at all, and the worker is a
  separate process on the user's machine that may not reach `Devices.Pairing`
  directly. Liveness is therefore derived from the control plane's own record of
  live attachments: `Delivery.CommandTransport.Channel`'s registry holds an entry
  only while an authenticated channel process for that worker is alive, so
  enumerating it and marking those workers seen is a truthful liveness signal
  that needs no protocol change.

  Each node refreshes the workers attached to itself, which stays correct if the
  control plane ever runs on more than one node — a worker is attached to exactly
  one of them, and `Pairing.mark_seen/1` is idempotent across a brief reconnect
  overlap. The refresher is started by the application supervisor except where
  `config :sdd_orchestrator, :start_worker_liveness_refresher` is false (the test
  environment calls `refresh/0` directly instead of running a timer).
  """
  use GenServer

  import Ecto.Query

  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: WorkerTransport
  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.WorkerDiscovery
  alias SddOrchestrator.Repo

  # A third of the staleness window, so an attached worker is refreshed several
  # times before discovery would call it stale. Derived rather than a second
  # constant that could drift from the policy it exists to satisfy.
  @refresh_divisor 3

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The refresh interval in milliseconds, derived from the staleness window."
  @spec default_interval() :: pos_integer()
  def default_interval,
    do: :timer.seconds(div(WorkerDiscovery.staleness_seconds(), @refresh_divisor))

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, default_interval())
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    schedule(state.interval)
    {:noreply, state}
  end

  @doc """
  Marks every worker currently attached to this node seen.

  Returns how many workers were refreshed. A registered worker whose row is gone,
  revoked, or otherwise not active is skipped rather than failing the pass, so one
  stale registration never costs the other attached workers their refresh.
  """
  @spec refresh() :: non_neg_integer()
  def refresh do
    case attached_worker_ids() do
      [] -> 0
      ids -> ids |> attached_workers() |> Enum.count(&refreshed?/1)
    end
  end

  defp attached_worker_ids do
    WorkerTransport.registry()
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.map(& &1.worker_id)
    |> Enum.uniq()
  end

  defp attached_workers(ids), do: Repo.all(from(w in LocalWorker, where: w.id in ^ids))

  defp refreshed?(%LocalWorker{state: "active"} = worker),
    do: match?({:ok, %LocalWorker{}}, Pairing.mark_seen(worker))

  defp refreshed?(%LocalWorker{}), do: false

  defp schedule(interval), do: Process.send_after(self(), :refresh, interval)
end
