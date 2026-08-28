defmodule SddOrchestrator.Worker.ConnectionStatus do
  @moduledoc """
  Last-known worker gateway connection status, observable from outside the
  BEAM process running the worker release (e.g. via `bin/worker rpc`).

  `SddOrchestrator.Worker.GatewayConnection` has no public status-read
  function of its own — several of its callbacks report into this module as a
  side effect only, added specs/36-local-worker-native-distribution Task 2
  without changing any callback's own control flow or return value. The native
  menu-bar app polls `status/0` over `bin/worker rpc` on a short interval to
  reflect the current state in its menu.

  Connected means attached, not merely dialled
  (specs/39-mac-scoped-worker-connection Task 7). A connected websocket is not
  yet a worker the control plane knows about: the join can still be refused, and
  a refused join is answered the same way every time it is retried. So the
  states are reported from the callback that actually proves each one:

    * `:connecting` — `handle_connect/1`. The transport is up and the join has
      been sent. Nothing is attached yet, so this is never `:connected`.
      Distinct from `:unknown`, which means nothing has been observed at all.
    * `:connected` — `handle_join/3`, and only there. A successful join is
      exactly the control plane having attached this worker.
    * `:refused` — `handle_topic_close/3`'s `{:failed_to_join, _}` clause. The
      control plane refused the attachment, carrying the refusal reason. Never
      presented as a connection and never retried as though it had succeeded.
    * `:disconnected` — `handle_disconnect/2`, and also the topic close that
      loses an established attachment while the transport stays up. Either way
      nothing is attached any more.

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

  @type status :: :connected | :connecting | :disconnected | :refused | :unknown

  @type snapshot :: %{status: status(), reason: term(), updated_at: DateTime.t() | nil}

  @doc """
  Records a successful attachment: the control plane joined this worker.

  Fired on the first join and on every rejoin. Never fired by the transport
  callback — a connected socket is not an attached worker.
  """
  @spec set_connected() :: :ok
  def set_connected do
    :persistent_term.put(@key, %{
      status: :connected,
      reason: nil,
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  Records a connected transport whose attachment has not been confirmed yet.

  An observation in its own right, which is why it is not `:unknown`: the
  socket is up and the join is in flight, so the answer to "is this worker
  attached?" is "not yet", not "never looked".
  """
  @spec set_connecting() :: :ok
  def set_connecting do
    :persistent_term.put(@key, %{
      status: :connecting,
      reason: nil,
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  Records the control plane refusing the attachment, carrying its reason.

  A refusal is not a connection and is not a dropped connection: the same
  announcement is refused the same way every time, so it is reported once and
  never retried as though it had succeeded.
  """
  @spec set_refused(term()) :: :ok
  def set_refused(reason \\ nil) do
    :persistent_term.put(@key, %{
      status: :refused,
      reason: reason,
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  Records the attachment being lost, carrying the reason Slipstream reported.

  Covers both a transport drop and a topic close that ends an established
  attachment while the socket stays up: in either case nothing is attached.
  """
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

  `:unknown` before anything at all has been recorded in this VM instance —
  the common case for a worker that has never paired, since `GatewayConnection`
  never starts without a paired configuration. It means nothing was observed,
  never "the socket is up but the join has not landed" (that is `:connecting`).
  """
  @spec status() :: snapshot()
  def status do
    :persistent_term.get(@key, %{status: :unknown, reason: nil, updated_at: nil})
  end
end
