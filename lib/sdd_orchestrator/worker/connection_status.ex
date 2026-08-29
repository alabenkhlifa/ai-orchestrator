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

  ## The status file

  `:persistent_term` only answers a reader inside this VM. The native menu-bar
  app is a separate process, and reaching in over `bin/worker rpc` needs Erlang
  distribution, which a managed Mac's firewall refuses
  (specs/43-distribution-free-worker-control Task 2). `eval` is no help either:
  a fresh VM has none of the running one's memory, so it would answer
  `:unknown` for a worker that is attached right now.

  So every transition is also published to an owner-only JSON file beside the
  worker configuration, under `SddOrchestrator.Worker.Configuration.home/1`.
  Any process that can read the worker's own storage root can read the state
  without a socket, a node name, or a cookie.

  The file is a report, never the authority:

    * `status/0` still answers from `:persistent_term` and is unchanged. The
      file is a second, out-of-process view of the same write, not a
      replacement for it.
    * the control plane remains the only source of truth for whether a worker
      is actually attached. The file says what this release last observed.
    * it is rewritten on every transition and is meaningless once the release
      stops, so a reader treats a missing or unreadable file as unknown rather
      than as anything else.
    * publishing it is a side effect of recording a state, never a
      precondition. A write that fails is reported to the log and swallowed:
      these functions are called from `GatewayConnection` callbacks as a side
      effect only, and a status report is never worth failing a connection
      callback for.

  It carries the state, its reason, and when it changed. It carries no
  credential, no worker identity, no repository path, and nothing about a run,
  and neither does any log line this module emits.
  """

  require Logger

  alias SddOrchestrator.Worker.Configuration

  @key {__MODULE__, :status}

  @file_name "connection_status.json"

  @type status :: :connected | :connecting | :disconnected | :refused | :unknown

  @type snapshot :: %{status: status(), reason: term(), updated_at: DateTime.t() | nil}

  @doc """
  The full path to the published status file under `Configuration.home/1`.

  Takes the same optional home override every other function in this area
  takes, so the release, the CLI, and a test can all name the storage root
  they mean. Path resolution itself belongs to `Configuration.home/1` and is
  not repeated here.
  """
  @spec path(String.t() | nil) :: String.t()
  def path(home_override \\ nil), do: Path.join(Configuration.home(home_override), @file_name)

  @doc """
  Records a successful attachment: the control plane joined this worker.

  Fired on the first join and on every rejoin. Never fired by the transport
  callback — a connected socket is not an attached worker.
  """
  @spec set_connected(String.t() | nil) :: :ok
  def set_connected(home_override \\ nil) do
    record(:connected, nil, home_override)
  end

  @doc """
  Records a connected transport whose attachment has not been confirmed yet.

  An observation in its own right, which is why it is not `:unknown`: the
  socket is up and the join is in flight, so the answer to "is this worker
  attached?" is "not yet", not "never looked".
  """
  @spec set_connecting(String.t() | nil) :: :ok
  def set_connecting(home_override \\ nil) do
    record(:connecting, nil, home_override)
  end

  @doc """
  Records the control plane refusing the attachment, carrying its reason.

  A refusal is not a connection and is not a dropped connection: the same
  announcement is refused the same way every time, so it is reported once and
  never retried as though it had succeeded.
  """
  @spec set_refused(term(), String.t() | nil) :: :ok
  def set_refused(reason \\ nil, home_override \\ nil) do
    record(:refused, reason, home_override)
  end

  @doc """
  Records the attachment being lost, carrying the reason Slipstream reported.

  Covers both a transport drop and a topic close that ends an established
  attachment while the socket stays up: in either case nothing is attached.
  """
  @spec set_disconnected(term(), String.t() | nil) :: :ok
  def set_disconnected(reason \\ nil, home_override \\ nil) do
    record(:disconnected, reason, home_override)
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

  # One place records a transition, so the in-process reader and the
  # out-of-process reader can never be given different values. The
  # `:persistent_term` write happens first because it is the one `status/0`
  # answers from; the file is the report of it.
  defp record(status, reason, home_override) do
    snapshot = %{status: status, reason: reason, updated_at: DateTime.utc_now()}

    :persistent_term.put(@key, snapshot)
    publish(snapshot, home_override)

    :ok
  end

  defp publish(snapshot, home_override) do
    directory = Configuration.home(home_override)

    case write_atomically(directory, Path.join(directory, @file_name), encode(snapshot)) do
      :ok -> :ok
      {:error, reason} -> warn(reason)
    end
  rescue
    # Resolving the home directory and rendering the payload can raise too,
    # and a caller in a `GatewayConnection` callback must still get its `:ok`.
    # Only the exception's name is reported: a `File.Error` message carries
    # the path, which never belongs in a log line.
    error -> warn(error.__struct__)
  end

  # Written to a uniquely named temporary file in the same directory and then
  # renamed over the target, so a concurrent reader sees either the previous
  # file or the complete new one and never a half-written one. `File.rename/2`
  # within one directory is the atomic step. Owner-only permissions are applied
  # before the rename for the same reason, and are the same `0700` directory
  # and `0600` file discipline `Configuration.store/2` already applies.
  #
  # The path is derived from the worker's own configured or default storage
  # root — trusted application configuration, never web or user input, exactly
  # as in `Configuration.store/2`. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_atomically(directory, file, contents) do
    temporary = file <> ".#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, file) do
      :ok
    else
      {:error, reason} ->
        # Only the rename publishes the file, so a failure before it leaves
        # nothing at the target. The temporary file is removed so a failing
        # release does not accumulate them beside the configuration.
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp encode(%{status: status, reason: reason, updated_at: updated_at}) do
    Jason.encode!(
      %{
        "status" => Atom.to_string(status),
        "reason" => render_reason(reason),
        "updated_at" => DateTime.to_iso8601(updated_at)
      },
      pretty: true
    )
  end

  # The reason is an arbitrary Elixir term — `GatewayConnection` hands over
  # whatever Slipstream reported, commonly a tuple such as
  # `{:topic_closed, reason}`. It is rendered as a display string with
  # `inspect/1` rather than encoded as structured JSON, because the reader is
  # a Swift process that needs a line to show and must not have to interpret
  # Elixir terms. Nothing decides anything from this field. A reason that is
  # already a string is passed through, since it is already what would be
  # displayed.
  defp render_reason(nil), do: nil
  defp render_reason(reason) when is_binary(reason), do: reason
  defp render_reason(reason), do: inspect(reason)

  # The reason alone (`:eacces`, `:enospc`) says what went wrong. The path is
  # deliberately absent: this module writes nothing identifying to disk and
  # logs nothing identifying either.
  defp warn(reason) do
    Logger.warning("worker connection status file not published (#{inspect(reason)})")

    :ok
  end
end
