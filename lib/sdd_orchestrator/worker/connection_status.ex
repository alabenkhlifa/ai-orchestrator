defmodule SddOrchestrator.Worker.ConnectionStatus do
  @moduledoc """
  Last-known worker gateway connection status, observable from outside the
  BEAM process running the worker release (e.g. via `bin/worker rpc`).

  `SddOrchestrator.Worker.GatewayConnection` has no public status-read
  function of its own — its `handle_connect/1` and `handle_disconnect/2`
  callbacks report into this module as a side effect only, added
  specs/36-local-worker-native-distribution Task 2 without changing either
  callback's own control flow or return value. The native menu-bar app polls
  `status/0` over `bin/worker rpc` on a short interval to opportunistically
  reflect "connected"/"disconnected" in its menu (Tasks 9 and 10 build on
  the same plumbing for update and reconnect UX).

  Backed by `:persistent_term` rather than a supervised process:

    * writes are rare — once per connect, reconnect, or disconnect, never a
      hot path — so `:persistent_term`'s global-GC-on-write cost is
      negligible here;
    * a reader must get a value even before any connection has ever been
      attempted (no worker configuration paired yet), with no ordering
      dependency on this module being started first. `:worker` boot mode's
      top-level supervisor starts nothing for this — see
      `SddOrchestrator.Application.worker_mode_children/0` — and
      `GatewayConnection` itself only exists once
      `SddOrchestrator.Worker.Supervisor` is attached.
  """

  @key {__MODULE__, :status}

  @type status :: :connected | :disconnected | :unknown

  @type snapshot :: %{status: status(), reason: term(), updated_at: DateTime.t() | nil}

  @doc "Records a successful gateway connect (fired on first connect and every reconnect)."
  @spec set_connected() :: :ok
  def set_connected do
    :persistent_term.put(@key, %{
      status: :connected,
      reason: nil,
      updated_at: DateTime.utc_now()
    })
  end

  @doc "Records a gateway disconnect, carrying the reason Slipstream reported."
  @spec set_disconnected(term()) :: :ok
  def set_disconnected(reason \\ nil) do
    :persistent_term.put(@key, %{
      status: :disconnected,
      reason: reason,
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  The last-known connection status.

  `:unknown` before any connect or disconnect has ever been recorded in this
  VM instance — the common case for a worker that has never paired, since
  `GatewayConnection` never starts without a paired configuration.
  """
  @spec status() :: snapshot()
  def status do
    :persistent_term.get(@key, %{status: :unknown, reason: nil, updated_at: nil})
  end
end
