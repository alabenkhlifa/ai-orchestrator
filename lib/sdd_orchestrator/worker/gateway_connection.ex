defmodule SddOrchestrator.Worker.GatewayConnection do
  @moduledoc """
  Dials the control plane's `/worker` gateway, joins this worker's execution
  target, and reports refusal or reconnects on drop.

  Two scopes are dialled, decided once in `establish/2` and carried in the
  socket's `:scope` assign so no later callback has to guess from the presence
  of a project (specs/39-mac-scoped-worker-connection Task 7):

    * a worker configured with a project asks for a project-scoped gateway
      credential and joins `worker:<project id>`;
    * a worker paired from the Mac app has no project yet. It asks for a
      workspace-scoped credential — omitting `project_id` from the request
      entirely, because a body naming a project it cannot fill in is still
      asking about a project and is refused — and joins
      `worker_workspace:<device workspace id>`.

  Connected means attached. The transport callback never claims it: only a
  successful join proves the control plane recorded this worker, and only that
  reports `:connected` into `SddOrchestrator.Worker.ConnectionStatus`. A
  refused join is reported as a refusal, never as a connection.

  This is the worker-runtime side of the protocol negotiation implemented by
  `SddOrchestratorWeb.WorkerSocket` and `SddOrchestratorWeb.WorkerChannel`. A
  genuinely remote worker has no in-process access to those control-plane
  modules — or to the control plane's `WorkerProtocol` module (under its
  `Delivery` context) — so the protocol version and capability list below are
  hardcoded literals, not a call into that module. They must be kept in sync
  with `WorkerProtocol.version/0` and `WorkerProtocol.capabilities/0`; a
  dedicated test asserts the two stay equal.

  Two refusals are distinguished on purpose:

    * the worker's own gateway-credential exchange is refused (bad or revoked
      worker credential, or no local-repository binding for the project) —
      this never opens a websocket at all; it is a hard startup refusal, not
      a connection that dropped.
    * the control plane accepts the connection but refuses the join itself
      (unsupported protocol version or a missing required capability) — the
      websocket is open, but this exact announcement will never succeed, so
      it is reported once and never rejoined as though it had connected.

  A transport-level drop (network blip, control-plane restart) is neither of
  those: it reconnects and rejoins the same topic, reusing the same
  already-obtained gateway credential (carried in the retained connection
  URI) via Slipstream's built-in backoff — never a new credential, never a
  different project.

  A Mac-scoped connection also learns which projects this worker serves. The
  control plane pushes `project_bound` and `project_unbound` over that topic,
  each naming a project id and nothing else, and this connection answers by
  opening or closing a second connection for that project under
  `SddOrchestrator.Worker.ProjectConnections`. That second connection is an
  ordinary project-scoped one: it exchanges the project credential, joins
  `worker:<project id>`, and handles commands through the code above,
  unchanged. Opening one is deliberately kept idempotent per project, because
  a worker re-reads the whole list of bindings every time it attaches and a
  worker already configured with a project is already connected for it.
  """

  use Slipstream, restart: :temporary

  require Logger

  alias SddOrchestrator.Delivery.Worker.ProcessLock
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.Worker.AgentObserver
  alias SddOrchestrator.Worker.CommandHandler
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ConnectionStatus
  alias SddOrchestrator.Worker.ExecutionPreparer
  alias SddOrchestrator.Worker.ProjectConnections
  alias SddOrchestrator.Worker.RepositorySelection
  alias SddOrchestrator.Worker.RequiredCheckRunner
  alias SddOrchestrator.Worker.RunState

  # Must be kept in sync with the control plane's `WorkerProtocol` module —
  # see the moduledoc. A remote worker binary has no access to that module
  # either, so these are literal values, not a call into it.
  @protocol_version 1

  @required_capabilities ~w(
    run.cancel
    run.reconcile
    run.resume
    run.retry
    run.start
    evidence.required_checks
    workspace.isolated_branch
  )

  @optional_capabilities ~w(
    agent.thread_resume
    evidence.screenshot
    preview.request
    repository_selection
  )

  @capabilities Enum.sort(@required_capabilities ++ @optional_capabilities)

  @gateway_credential_path "/worker/gateway_credentials"
  @websocket_path "/worker/websocket"

  # How often a running attempt's agent output is polled. Production callers
  # never override this; tests do, via `opts[:observe_interval]`, the same
  # seam `:protocol_version` and `:capabilities` already use, so a suite
  # never waits a real 300ms per tick.
  @observe_interval 300

  # How long one delivered event's channel acknowledgement is awaited before
  # the tick gives up on it and retries on the next scheduled poll (see
  # `deliver_events/3`).
  @event_ack_timeout 5_000

  @terminal_event_types ~w(blocked failed verification_completed)

  @doc "The protocol version this worker announces (kept in sync with `WorkerProtocol.version/0`)."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "The full capability set this worker announces (kept in sync with `WorkerProtocol.capabilities/0`)."
  @spec capabilities() :: [String.t()]
  def capabilities, do: @capabilities

  @doc """
  Starts the gateway connection for one loaded worker configuration.

  `opts` may override `:protocol_version` and `:capabilities` — production
  callers (including `SddOrchestrator.Worker.Supervisor`) never pass either
  and always announce the full, current contract above; the override exists
  so tests can exercise a refused announcement against the real channel.
  """
  @spec start_link(Configuration.t(), keyword()) :: GenServer.on_start()
  def start_link(%Configuration{} = config, opts \\ []) do
    Slipstream.start_link(__MODULE__, {config, opts})
  end

  @impl Slipstream
  def init({%Configuration{} = config, opts}) do
    socket = new_socket() |> assign(:config, config) |> assign(:opts, opts)
    {:ok, socket, {:continue, :connect_gateway}}
  end

  # Deferred to `handle_continue/2` (rather than done inline in `init/1`) so
  # the credential-exchange HTTP call never blocks
  # `SddOrchestrator.Worker.Supervisor.start_link/1` while this child starts.
  @impl true
  def handle_continue(:connect_gateway, socket) do
    %{config: config, opts: opts} = socket.assigns

    case establish(config, opts) do
      {:ok, connecting_socket} ->
        {:noreply, connecting_socket}

      {:error, reason} ->
        Logger.error(
          "worker gateway refused to start for #{describe_scope(scope(config))}: " <>
            inspect(reason)
        )

        {:stop, :normal, socket}
    end
  end

  # A connected transport is not an attached worker: the join has not been
  # answered yet and can still be refused. So this records "connected, not yet
  # attached" and nothing stronger — `handle_join/3` below is the only place
  # that may claim a connection.
  @impl Slipstream
  def handle_connect(socket) do
    Logger.info(
      "worker gateway transport connected for #{describe_scope(socket.assigns.scope)}; " <>
        "joining #{socket.assigns.topic} (not attached until the join is accepted)"
    )

    # specs/36-local-worker-native-distribution Task 2: reported into
    # `ConnectionStatus` as a side effect only — does not influence this
    # callback's own control flow or return value. See its moduledoc.
    ConnectionStatus.set_connecting()

    {:ok, join(socket, socket.assigns.topic, socket.assigns.join_params)}
  end

  # Fires on every successful join, first connect and every reconnect alike —
  # pushing this worker's authoritative reconciliation snapshot here (rather
  # than only in answer to an explicit "reconcile" command) is what gives the
  # control plane the worker's real view immediately on every (re)join.
  @impl Slipstream
  def handle_join(topic, response, socket) do
    Logger.info("worker gateway joined #{topic} and is reachable; contract=#{inspect(response)}")

    # The one place a connection may be claimed: an accepted join is exactly
    # the control plane having attached this worker. Side effect only, like
    # every other `ConnectionStatus` write here.
    ConnectionStatus.set_connected()

    socket = push_reconcile_snapshot(topic, socket)
    {:ok, socket}
  end

  # A join refusal (unsupported protocol version or a missing required
  # capability) is answered by the control plane exactly the same way every
  # time this exact announcement is retried, so it is reported once — clearly
  # distinguishable from a transient disconnect below — and never rejoined.
  # A genuine mid-session topic close (e.g. the channel process crashing after
  # a successful join) is a different shape and is rejoined instead.
  @impl Slipstream
  def handle_topic_close(topic, {:failed_to_join, response}, socket) do
    reason = refusal_reason(response)

    Logger.error(
      "worker gateway JOIN REFUSED for #{topic}: reason=#{reason} " <>
        "(control plane rejected the protocol version or a required capability; not retrying)"
    )

    # Reported as the refusal it is. Never `:connected`, and never retried as
    # though it had succeeded — the return value below is unchanged.
    ConnectionStatus.set_refused(reason)

    {:ok, socket}
  end

  def handle_topic_close(topic, reason, socket) do
    Logger.warning("worker gateway topic closed for #{topic}: #{inspect(reason)}; rejoining")

    # The transport may still be up, but the attachment is gone, so this stops
    # reading as connected until a rejoin is accepted.
    ConnectionStatus.set_disconnected({:topic_closed, reason})

    case rejoin(socket, topic) do
      {:ok, rejoining_socket} -> {:ok, rejoining_socket}
      {:error, :never_joined} -> {:ok, socket}
    end
  end

  # A transport-level drop reconnects and, via `handle_connect/1` above,
  # rejoins the same topic with the same already-obtained gateway credential
  # — never a new one, and never a different project or capability set.
  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("worker gateway connection dropped: #{inspect(reason)}; reconnecting")

    # specs/36-local-worker-native-distribution Task 2: see the matching
    # note in `handle_connect/1` above — side effect only.
    ConnectionStatus.set_disconnected(reason)

    case reconnect(socket) do
      {:ok, reconnecting_socket} -> {:ok, reconnecting_socket}
      {:error, stop_reason} -> {:stop, stop_reason, socket}
    end
  end

  # Validates, acknowledges exactly once, and durably records every command
  # operation via `SddOrchestrator.Worker.CommandHandler`, then performs
  # whatever this worker's own later effect is for an accepted one: `start`,
  # `resume`, and `retry` all prepare execution the same way (`ExecutionPreparer`
  # is operation-agnostic); `cancel` stops the running agent and releases the
  # lock; `reconcile` answers with this worker's authoritative attempt
  # snapshot. A rejected or duplicate acknowledgement triggers no further
  # effect.
  @impl Slipstream
  def handle_message(topic, "command", message, socket) do
    ack = CommandHandler.handle_command(message, @protocol_version, socket.assigns.home)

    case push(socket, topic, "acknowledge", ack) do
      {:ok, _ref} ->
        socket =
          if ack["status"] == "accepted",
            do: handle_accepted_command(topic, message, socket),
            else: socket

        {:ok, socket}

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to push an acknowledgement for command " <>
            "#{inspect(message["command_id"])}: #{inspect(reason)}"
        )

        {:ok, socket}
    end
  end

  # A folder-picker request from the control plane
  # (specs/40-worker-repository-selection Task 3). Everything that needs the
  # chosen path happens inside `SddOrchestrator.Worker.RepositorySelection`, on
  # this Mac; this callback only hands the request over and gives it a way to
  # answer. The reply runs later, in that process, so it sends the payload back
  # here rather than pushing from a process the socket does not belong to — the
  # same deferred-push shape `handle_info({:observe_agent, _}, socket)` uses.
  def handle_message(topic, "repository_selection", message, socket) do
    connection = self()
    reply = fn payload -> send(connection, {:repository_selection_result, topic, payload}) end

    RepositorySelection.open(message, reply, socket.assigns.home)

    {:ok, socket}
  end

  # The control plane stopped waiting (the requester left, or the window ended),
  # so the panel is closed and nothing is answered.
  def handle_message(_topic, "repository_selection_cancel", message, socket) do
    case message do
      %{"request_id" => request_id} when is_binary(request_id) ->
        RepositorySelection.close(request_id)

      _unusable ->
        Logger.info("worker gateway ignoring a repository selection cancel with no request id")
    end

    {:ok, socket}
  end

  # This Mac now serves a project. The whole answer is a second connection,
  # dialled from a copy of this configuration that names the project, so every
  # credential, join, registry, and command path stays the one already proved.
  def handle_message(_topic, "project_bound", %{"project_id" => project_id}, socket)
      when is_binary(project_id) do
    {:ok, open_project_connection(socket, project_id)}
  end

  # The project is no longer this Mac's. The connection for it is closed, which
  # takes it out of the control plane's project-keyed registry with it.
  def handle_message(_topic, "project_unbound", %{"project_id" => project_id}, socket)
      when is_binary(project_id) do
    {:ok, close_project_connection(socket, project_id)}
  end

  # Any other inbound push is observed and ignored rather than crashing the
  # process on an unrecognized message.
  def handle_message(topic, event, message, socket) do
    Logger.info(
      "worker gateway ignoring unhandled push #{inspect(event)} on #{topic}: #{inspect(message)}"
    )

    {:ok, socket}
  end

  # Opening is idempotent per project, and deliberately so. A worker re-reads
  # every binding for its Mac each time it attaches, and a worker configured
  # with a project is already connected for it, so a notice for something
  # already served must cost nothing rather than open a rival connection.
  defp open_project_connection(socket, project_id) do
    cond do
      project_id == socket.assigns.config.project_id -> socket
      Map.has_key?(socket.assigns.project_connections, project_id) -> socket
      true -> start_project_connection(socket, project_id)
    end
  end

  # A connection that refuses to start is this project's problem alone. It is
  # reported and left, because killing this connection would cost the worker its
  # Mac attachment and every other project with it.
  defp start_project_connection(socket, project_id) do
    %Configuration{} = configured = socket.assigns.config
    config = %Configuration{configured | project_id: project_id}

    case ProjectConnections.open(
           socket.assigns.project_connection_supervisor,
           config,
           socket.assigns.opts
         ) do
      {:ok, pid} when is_pid(pid) ->
        Process.monitor(pid)
        Logger.info("worker gateway opened a project connection for project #{project_id}")

        assign(
          socket,
          :project_connections,
          Map.put(socket.assigns.project_connections, project_id, pid)
        )

      other ->
        Logger.error(
          "worker gateway could not open a project connection for project " <>
            "#{project_id}: #{refusal_summary(other)}"
        )

        socket
    end
  end

  # A refusal is named, never inspected whole. A supervisor's own error term can
  # quote the start call that failed, and that call carries this worker's
  # configuration and its credential with it.
  defp refusal_summary({:error, {:already_started, _pid}}), do: "already_started"
  defp refusal_summary({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp refusal_summary(:ignore), do: "ignored"
  defp refusal_summary(_other), do: "refused"

  defp close_project_connection(socket, project_id) do
    case Map.pop(socket.assigns.project_connections, project_id) do
      {nil, _connections} ->
        socket

      {pid, connections} ->
        ProjectConnections.close(socket.assigns.project_connection_supervisor, pid)
        Logger.info("worker gateway closed the project connection for project #{project_id}")
        assign(socket, :project_connections, connections)
    end
  end

  # A project connection that stopped on its own must stop counting as open, or
  # the next notice for that project would be dismissed as a duplicate and the
  # worker would stay unreachable for it.
  defp drop_project_connection(socket, pid) do
    assign(
      socket,
      :project_connections,
      socket.assigns.project_connections
      |> Enum.reject(fn {_project_id, open} -> open == pid end)
      |> Map.new()
    )
  end

  defp handle_accepted_command(topic, %{"operation" => "cancel"} = message, socket),
    do: handle_cancel(topic, message, socket)

  defp handle_accepted_command(topic, %{"operation" => "reconcile"}, socket),
    do: push_reconcile_snapshot(topic, socket)

  defp handle_accepted_command(topic, message, socket),
    do: prepare_execution(topic, message, socket)

  # Stops the running agent (if this connection is the one holding it),
  # records the durable cooperative stop request any other process-holder
  # would observe, then finishes the attempt as "canceled" — releasing the
  # lock and recording the terminal lifecycle exactly like every other
  # terminal transition (`finish_attempt/3`). No further observation tick is
  # scheduled; a stray already-scheduled one is guarded against separately
  # (see `attempt_still_running?/2`).
  defp handle_cancel(topic, message, socket) do
    request_stop(message)
    socket = stop_launch(socket)

    push_heartbeat(topic, "stopping", socket)
    finish_attempt(message, "canceled", socket)

    socket
  end

  # The process that cancels a run is not necessarily the process that holds
  # the lock (see `SddOrchestrator.Delivery.Worker.ProcessLock`'s own
  # moduledoc) — this durable stop-request file is how a holder in another
  # process, or another VM entirely, learns to stop at its own next safe
  # point, regardless of whether this same connection also holds the launch.
  defp request_stop(message) do
    case workspace_path(message["project_id"], message["run_id"]) do
      {:ok, workspace} ->
        lock = %ProcessLock{
          workspace: workspace,
          run_id: message["run_id"],
          fence_token: message["fence_token"],
          os_pid: "n/a",
          acquired_at: DateTime.utc_now()
        }

        case ProcessLock.request_stop(lock) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "worker gateway failed to record a stop request for run " <>
                "#{inspect(message["run_id"])}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.error(
          "worker gateway could not resolve the workspace to request a stop for run " <>
            "#{inspect(message["run_id"])}: #{inspect(reason)}"
        )
    end
  end

  # The common case: this same connection is the one that launched the
  # agent, so cancellation stops it directly rather than only waiting for
  # the cooperative stop request above to be observed. An already-dead
  # process (`:noproc`) is not an error — the agent may have exited on its
  # own between the cancel arriving and this call.
  #
  # `Process.unlink/1` first is not optional: `AgentAdapter.launch/3` starts
  # the agent's `handle.reference` process linked to whichever process calls
  # it — this connection itself — and `GatewayConnection` does not trap
  # exits (neither it nor `Slipstream` sets that flag). Confirmed
  # empirically: without unlinking first, `GenServer.stop/3` terminating a
  # genuinely still-running, still-linked process delivers this same
  # connection an untrapped exit signal — not something a `catch :exit`
  # around the `GenServer.stop/3` call itself can intercept, since a link's
  # exit signal is asynchronous and bypasses the calling code path entirely
  # — which kills this connection process too. Unlinking first is the same
  # idiom this codebase's own test helpers already use before deliberately
  # stopping a linked process (see every test file's `stop_gateway/1`).
  defp stop_launch(socket) do
    case socket.assigns[:launch] do
      %{handle: %{reference: pid}} when is_pid(pid) ->
        Process.unlink(pid)

        try do
          GenServer.stop(pid, :shutdown, 5_000)
        catch
          :exit, _reason -> :ok
        end

      _no_launch_here ->
        :ok
    end

    socket
  end

  # Mirrors `AgentObserver.finish/3`'s own duplication of `Workspace`'s
  # private `run_path/2` formula (`Path.join([root, project_id, run_id])`) —
  # `Workspace` is consumed unchanged from specs/07, so no public helper can
  # be added there, and this two-field join is a stable, already-documented
  # path convention rather than an implementation detail likely to drift.
  defp workspace_path(project_id, run_id) do
    with {:ok, root} <- Workspace.root() do
      {:ok, Path.join([root, project_id, run_id])}
    end
  end

  # Pushes this worker's authoritative attempt snapshot as a separate
  # client-initiated "reconcile" message — distinct from the acknowledgement
  # every command already receives. Used both to answer an explicit
  # "reconcile" command and, unconditionally, on every successful join (see
  # `handle_join/3`).
  defp push_reconcile_snapshot(topic, socket) do
    snapshot = build_reconcile_snapshot(socket)

    case push(socket, topic, "reconcile", snapshot) do
      {:ok, _ref} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to push a reconciliation snapshot: #{inspect(reason)}"
        )
    end

    socket
  end

  defp build_reconcile_snapshot(socket) do
    %{
      "type" => "reconciliation_snapshot",
      "protocol_version" => @protocol_version,
      "worker_id" => socket.assigns.config.worker_id,
      "observed_at" => now_iso8601(),
      "attempts" => snapshot_attempts(socket)
    }
  end

  defp snapshot_attempts(socket) do
    case RunState.load(socket.assigns.home) do
      {:ok, %{current: %RunState{} = current}} ->
        [snapshot_attempt(current)]

      {:ok, %{current: nil}} ->
        []

      {:error, reason} ->
        Logger.error(
          "worker gateway could not read local run state to build a reconciliation snapshot: " <>
            inspect(reason)
        )

        []
    end
  end

  defp snapshot_attempt(%RunState{} = current) do
    %{
      "run_id" => current.run_id,
      "attempt_number" => current.attempt_number,
      "command_id" => current.command_id,
      "fence_token" => current.fence_token,
      "last_sequence" => current.last_sequence,
      "branch" => current.branch,
      "state" => attempt_wire_state(current.lifecycle)
    }
  end

  # There is no dedicated "succeeded" wire attempt-state: the snapshot's own
  # job is only to say whether this worker still considers something
  # running, and by the time verification completed the lock is already
  # released and nothing further is running — "stopped" reflects that
  # accurately. The success fact itself was already carried by the
  # attempt's own already-delivered `verification_completed` *event*; this
  # snapshot is not a second channel for it.
  defp attempt_wire_state("accepted"), do: "running"
  defp attempt_wire_state("blocked"), do: "blocked"
  defp attempt_wire_state("canceled"), do: "canceled"
  defp attempt_wire_state("stopped"), do: "stopped"
  defp attempt_wire_state("failed"), do: "failed"
  defp attempt_wire_state("verification_completed"), do: "stopped"

  # Fires once per attempt's observation tick (see `start_agent_observation/3`
  # and `AgentObserver.poll/3`): reobserves the launched agent, delivers
  # whatever it produced in order, and either reschedules, stops on
  # supersession or a clean agent exit, or transitions the attempt to its
  # terminal state.
  #
  # `AgentAdapter.observe/2` (via each adapter's `Session.drain/1`) is a
  # destructive read: whatever it returns is gone from the adapter's own
  # buffer the instant it's returned, win or lose, acknowledged or not. So a
  # tick that already has undelivered events from a *previous* tick's
  # partial failure (`socket.assigns.pending`) must finish delivering those
  # first — polling again before they're flushed would draw fresh content
  # under the sequence numbers the lost ones were supposed to carry,
  # permanently losing whatever wasn't acknowledged (data loss, not merely a
  # delay), and could silently drop a terminal event and leave the attempt
  # stuck "accepted" forever. Only once `pending` is empty does this poll
  # the adapter for anything new.
  @impl Slipstream
  def handle_info({:observe_agent, envelope}, socket) do
    case Map.get(socket.assigns, :pending) do
      %{events: events, terminal: terminal} when events != [] ->
        continue_delivery(socket, envelope, events, terminal)

      _none_pending ->
        poll_and_deliver(socket, envelope)
    end
  end

  # The finished folder-picker answer, sent here by
  # `SddOrchestrator.Worker.RepositorySelection` because only this process owns
  # the socket. The payload holds identities and a folder name; never a path.
  def handle_info({:repository_selection_result, topic, payload}, socket) do
    case push(socket, topic, "repository_selection_result", payload) do
      {:ok, _ref} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to push a repository selection result for request " <>
            "#{inspect(payload["request_id"])}: #{inspect(reason)}"
        )
    end

    {:noreply, socket}
  end

  # A project connection is temporary, so one that goes down stays down. Only
  # the record of it being open is cleared here, which is what lets a later
  # `project_bound` notice open it again.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    {:noreply, drop_project_connection(socket, pid)}
  end

  defp poll_and_deliver(socket, envelope) do
    if attempt_still_running?(socket, envelope) do
      do_poll_and_deliver(socket, envelope)
    else
      Logger.info(
        "worker gateway stopping agent observation for command " <>
          "#{inspect(envelope["command_id"])}: attempt already reached a terminal lifecycle"
      )

      {:noreply, socket}
    end
  end

  # `AgentObserver.poll/3`'s own `current?/2` check answers one question —
  # does this envelope still name the current attempt (supersession)? This
  # answers the separate one: has this exact still-current attempt already
  # reached a terminal lifecycle through some other path (a cancel that
  # completed between this tick being scheduled and firing)? A stray tick
  # for either reason must do nothing: no reschedule, no adapter call. Only
  # the second question belongs here — the first stays `AgentObserver`'s own,
  # handled below exactly as before.
  defp attempt_still_running?(socket, envelope) do
    case RunState.load(socket.assigns.home) do
      {:ok, %{current: %RunState{} = current}} ->
        not (same_attempt?(current, envelope) and current.lifecycle != "accepted")

      {:ok, %{current: nil}} ->
        true

      {:error, _reason} ->
        true
    end
  end

  defp same_attempt?(%RunState{} = current, envelope) do
    current.run_id == envelope["run_id"] and
      current.attempt_number == envelope["attempt_number"] and
      current.fence_token == envelope["fence_token"]
  end

  defp do_poll_and_deliver(socket, envelope) do
    case AgentObserver.poll(envelope, socket.assigns.launch, socket.assigns.home) do
      {:ok, %{current?: false}} ->
        Logger.info(
          "worker gateway stopping agent observation for command " <>
            "#{inspect(envelope["command_id"])}: attempt superseded"
        )

        {:noreply, socket}

      {:ok, %{current?: true, observation: observation}} ->
        log_dropped(envelope, observation.dropped)
        continue_delivery(socket, envelope, observation.events, observation.terminal)

      {:error, :agent_exited} ->
        Logger.info(
          "worker gateway agent observation ended for command " <>
            "#{inspect(envelope["command_id"])}: the agent exited cleanly; running its " <>
            "required checks"
        )

        run_required_checks(socket, envelope)

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to poll the agent for command " <>
            "#{inspect(envelope["command_id"])}: #{inspect(reason)}"
        )

        {:noreply, socket}
    end
  end

  # Fires once the agent's own observation loop has nothing further to
  # observe and reported no terminal event of its own — the hand-off point
  # `AgentObserver`'s Task 8 moduledoc names as this task's own to fill.
  # Verification completion is proved here, from the attempt's own
  # required-check contract, and never asserted by the agent (see
  # `RequiredCheckRunner`). A runner-level failure (an unparseable manifest, an
  # unprovable working directory, unreadable run state, or an unresolvable
  # `HEAD`) is refused and logged exactly like `prepare_execution/3`'s own
  # refusal branch: no event delivered, no lock touched, nothing forced into
  # a terminal state.
  defp run_required_checks(socket, envelope) do
    case RequiredCheckRunner.run(envelope, socket.assigns.home, check_runner_opts(socket)) do
      {:ok, %{events: events, terminal: terminal}} ->
        continue_delivery(socket, envelope, events, terminal)

      {:error, reason} ->
        Logger.error(
          "worker refused to run required checks for command " <>
            "#{inspect(envelope["command_id"])}: #{inspect(reason)}"
        )

        {:noreply, socket}
    end
  end

  # `RequiredCheckRunner` uploads each check's captured output through the
  # same signed gateway credential this socket already obtained in
  # `establish/2` (never a second one) and the same control-plane address the
  # socket itself dialed. `:req_options` is a test-only seam — production
  # never sets it — that lets a test stub the artifact transport without a
  # live control plane, threaded from `establish/2`'s own `opts[:req_options]`.
  defp check_runner_opts(socket) do
    [
      artifact_base_url: socket.assigns.config.control_plane_address,
      artifact_token: socket.assigns.gateway_credential
    ]
    |> maybe_put(:check_timeout_ms, socket.assigns[:check_timeout_ms])
    |> maybe_put(:req_options, socket.assigns[:artifact_req_options])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # An accepted command is prepared for execution only after its
  # acknowledgement is on the wire — the acknowledgement is this worker's
  # answer to the command itself, while workspace preparation is a separate,
  # later effect the control plane observes as an event. Returns the
  # (possibly updated, e.g. carrying the launched agent) socket unchanged on
  # any refusal, since nothing exists yet to observe.
  defp prepare_execution(topic, message, socket) do
    case ExecutionPreparer.prepare(message, socket.assigns.home) do
      {:ok, event} ->
        case push(socket, topic, "event", event) do
          {:ok, _ref} ->
            start_agent_observation(topic, message, socket)

          {:error, reason} ->
            Logger.error(
              "worker gateway failed to push the workspace_ready event for command " <>
                "#{inspect(message["command_id"])}: #{inspect(reason)}"
            )

            socket
        end

      {:error, reason} ->
        Logger.error(
          "worker refused to prepare execution for command " <>
            "#{inspect(message["command_id"])}: #{inspect(reason)}"
        )

        socket
    end
  end

  # Launches the attempt's agent (Task 8), announces it with a "running"
  # heartbeat, and schedules the first observation tick. An agent that fails
  # to launch has nothing to observe — refused and logged, no tick scheduled,
  # socket unchanged.
  defp start_agent_observation(topic, envelope, socket) do
    case AgentObserver.start(envelope, socket.assigns.home) do
      {:ok, launch} ->
        push_heartbeat(topic, "running", socket)
        Process.send_after(self(), {:observe_agent, envelope}, socket.assigns.observe_interval)
        assign(socket, :launch, launch)

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to launch the agent for command " <>
            "#{inspect(envelope["command_id"])}: #{inspect(reason)}"
        )

        socket
    end
  end

  # Delivers one batch of events (fresh from this tick's poll, or carried
  # over as `pending` from a tick that could not finish delivering them):
  # every event in order, each awaited for its acknowledgement before the
  # next is pushed. A push or ack failure stops delivering further events
  # *this tick* without advancing past the failure — the undelivered
  # remainder (including the batch's own terminal marker, if any) is kept in
  # `socket.assigns.pending` for the next tick to retry first, rather than
  # discarded (see `handle_info/2`'s moduledoc-style comment on why that
  # would lose data). Only once a batch is fully delivered does a terminal
  # marker trigger the attempt's terminal transition, or, absent one, the
  # next tick schedule.
  defp continue_delivery(socket, envelope, events, terminal) do
    case deliver_events(socket, envelope, events) do
      :ok ->
        socket = assign(socket, :pending, nil)

        if terminal in @terminal_event_types do
          push_heartbeat(socket.assigns.topic, "stopping", socket)
          finish_attempt(envelope, terminal, socket)
          {:noreply, socket}
        else
          reschedule(socket, envelope)
        end

      {:partial, remaining} ->
        socket = assign(socket, :pending, %{events: remaining, terminal: terminal})
        reschedule(socket, envelope)
    end
  end

  defp deliver_events(_socket, _envelope, []), do: :ok

  defp deliver_events(socket, envelope, [event | rest] = events) do
    case push_and_await(socket, event) do
      :ok ->
        AgentObserver.record_sequence(envelope, event["sequence"], socket.assigns.home)
        deliver_events(socket, envelope, rest)

      :error ->
        {:partial, events}
    end
  end

  defp push_and_await(socket, event) do
    case push(socket, socket.assigns.topic, "event", event) do
      {:ok, ref} ->
        case await_reply(ref, @event_ack_timeout) do
          :ok ->
            :ok

          {:ok, _response} ->
            :ok

          reply ->
            Logger.warning(
              "worker gateway event sequence #{event["sequence"]} for command " <>
                "#{inspect(event["command_id"])} was not acknowledged: #{inspect(reply)}"
            )

            :error
        end

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to push event sequence #{event["sequence"]} for command " <>
            "#{inspect(event["command_id"])}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp finish_attempt(envelope, terminal, socket) do
    case AgentObserver.finish(envelope, terminal, socket.assigns.home) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to finish attempt for command " <>
            "#{inspect(envelope["command_id"])} as #{terminal}: #{inspect(reason)}"
        )
    end
  end

  defp reschedule(socket, envelope) do
    Process.send_after(self(), {:observe_agent, envelope}, socket.assigns.observe_interval)
    {:noreply, socket}
  end

  defp log_dropped(_envelope, []), do: :ok

  defp log_dropped(envelope, dropped) do
    Logger.warning(
      "worker gateway dropped #{length(dropped)} agent event(s) for command " <>
        "#{inspect(envelope["command_id"])} as outside the agent's allowed vocabulary: " <>
        inspect(dropped)
    )
  end

  # Reloaded fresh on every call (never carried between ticks) so a
  # heartbeat's `last_sequence` and other fields always reflect the most
  # recently durably recorded state, matching `AgentObserver`'s own
  # never-trust-stale-state discipline.
  defp push_heartbeat(topic, state, socket) do
    case RunState.load(socket.assigns.home) do
      {:ok, %{current: %RunState{} = current}} ->
        heartbeat = %{
          "type" => "heartbeat",
          "protocol_version" => @protocol_version,
          "run_id" => current.run_id,
          "attempt_number" => current.attempt_number,
          "fence_token" => current.fence_token,
          "last_sequence" => current.last_sequence,
          "state" => state,
          "worker_id" => socket.assigns.config.worker_id,
          "observed_at" => now_iso8601()
        }

        case push(socket, topic, "heartbeat", heartbeat) do
          {:ok, _ref} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "worker gateway failed to push a #{state} heartbeat for run " <>
                "#{inspect(current.run_id)}: #{inspect(reason)}"
            )
        end

      _unavailable ->
        Logger.error("worker gateway could not read local run state to push a #{state} heartbeat")
    end
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp establish(%Configuration{} = config, opts) do
    scope = scope(config)

    with {:ok, token} <- fetch_gateway_credential(config),
         {:ok, uri} <- websocket_uri(config.control_plane_address, token) do
      join_params = %{
        "protocol_version" => Keyword.get(opts, :protocol_version, @protocol_version),
        "capabilities" => Keyword.get(opts, :capabilities, @capabilities)
      }

      socket =
        new_socket()
        |> assign(:config, config)
        |> assign(:scope, scope)
        |> assign_scope_target(scope)
        |> assign(:topic, topic(scope))
        |> assign(:join_params, join_params)
        |> assign(:home, Keyword.get(opts, :home))
        |> assign(:observe_interval, Keyword.get(opts, :observe_interval, @observe_interval))
        |> assign(:check_timeout_ms, Keyword.get(opts, :check_timeout_ms))
        |> assign(:gateway_credential, token)
        |> assign(:artifact_req_options, Keyword.get(opts, :req_options))
        # Kept whole so a project connection opened later starts on the same
        # terms as this one, including whatever seam a test is driving.
        |> assign(:opts, opts)
        |> assign(
          :project_connection_supervisor,
          Keyword.get(opts, :project_connections, ProjectConnections)
        )
        |> assign(:project_connections, %{})

      case connect(socket, uri: uri) do
        {:ok, connecting_socket} -> {:ok, connecting_socket}
        {:error, reason} -> {:error, {:invalid_websocket_configuration, reason}}
      end
    end
  end

  # The scope this worker is configured for, decided once from the stored
  # configuration. A worker paired from the Mac app has no project and is
  # authorized for its device workspace alone.
  defp scope(%Configuration{project_id: project_id}) when is_binary(project_id),
    do: {:project, project_id}

  defp scope(%Configuration{device_workspace_id: device_workspace_id}),
    do: {:device_workspace, device_workspace_id}

  defp topic({:project, project_id}), do: "worker:" <> project_id

  # Must match `SddOrchestratorWeb.WorkerWorkspaceChannel`'s own topic prefix.
  defp topic({:device_workspace, device_workspace_id}),
    do: "worker_workspace:" <> device_workspace_id

  defp assign_scope_target(socket, {:project, project_id}),
    do: assign(socket, :project_id, project_id)

  defp assign_scope_target(socket, {:device_workspace, device_workspace_id}),
    do: assign(socket, :device_workspace_id, device_workspace_id)

  defp describe_scope({:project, project_id}), do: "project #{project_id}"

  defp describe_scope({:device_workspace, device_workspace_id}),
    do: "device workspace #{device_workspace_id}"

  # A worker whose own credential is refused (revoked, rotated away, or
  # unbound for this project) can never connect — this is a hard startup
  # refusal, not a connection that dropped, so it never reaches the socket.
  defp fetch_gateway_credential(%Configuration{} = config) do
    url = config.control_plane_address <> @gateway_credential_path

    case Req.post(url,
           auth: {:bearer, config.worker_credential},
           json: credential_request_body(config)
         ) do
      {:ok, %{status: 200, body: %{"token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:gateway_credential_refused, status, body}}

      {:error, reason} ->
        {:error, {:gateway_credential_transport_error, reason}}
    end
  end

  # The control plane's workspace exchange is guarded on `project_id` being
  # absent, not empty: a request carrying `"project_id" => nil` is still asking
  # about a project it cannot name, and is refused. A projectless worker
  # therefore omits the key rather than sending it blank.
  defp credential_request_body(%Configuration{project_id: nil}), do: %{}

  defp credential_request_body(%Configuration{project_id: project_id}),
    do: %{"project_id" => project_id}

  # Slipstream requires a ws(s):// URI. A missing or unrecognized scheme in
  # the stored control-plane address is a configuration problem, refused the
  # same way as a bad credential rather than guessed at.
  defp websocket_uri(control_plane_address, token) do
    uri = URI.parse(control_plane_address)

    case websocket_scheme(uri.scheme) do
      {:ok, scheme} ->
        ws = %URI{
          uri
          | scheme: scheme,
            path: (uri.path || "") <> @websocket_path,
            query: URI.encode_query(%{"token" => token})
        }

        {:ok, URI.to_string(ws)}

      :error ->
        {:error, {:invalid_control_plane_address, control_plane_address}}
    end
  end

  defp websocket_scheme("http"), do: {:ok, "ws"}
  defp websocket_scheme("https"), do: {:ok, "wss"}
  defp websocket_scheme("ws"), do: {:ok, "ws"}
  defp websocket_scheme("wss"), do: {:ok, "wss"}
  defp websocket_scheme(_other), do: :error

  defp refusal_reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp refusal_reason(other), do: inspect(other)
end
