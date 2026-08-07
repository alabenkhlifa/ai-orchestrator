defmodule SddOrchestrator.Worker.GatewayConnection do
  @moduledoc """
  Dials the control plane's `/worker` gateway, joins this worker's execution
  target, and reports refusal or reconnects on drop.

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
  """

  use Slipstream, restart: :temporary

  require Logger

  alias SddOrchestrator.Worker.CommandHandler
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ExecutionPreparer

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
  )

  @capabilities Enum.sort(@required_capabilities ++ @optional_capabilities)

  @gateway_credential_path "/worker/gateway_credentials"
  @websocket_path "/worker/websocket"

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
          "worker gateway refused to start for project #{inspect(config.project_id)}: " <>
            inspect(reason)
        )

        {:stop, :normal, socket}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info(
      "worker gateway connected for project #{socket.assigns.project_id}; " <>
        "joining #{socket.assigns.topic}"
    )

    {:ok, join(socket, socket.assigns.topic, socket.assigns.join_params)}
  end

  @impl Slipstream
  def handle_join(topic, response, socket) do
    Logger.info("worker gateway joined #{topic} and is reachable; contract=#{inspect(response)}")
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
    Logger.error(
      "worker gateway JOIN REFUSED for #{topic}: reason=#{refusal_reason(response)} " <>
        "(control plane rejected the protocol version or a required capability; not retrying)"
    )

    {:ok, socket}
  end

  def handle_topic_close(topic, reason, socket) do
    Logger.warning("worker gateway topic closed for #{topic}: #{inspect(reason)}; rejoining")

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

    case reconnect(socket) do
      {:ok, reconnecting_socket} -> {:ok, reconnecting_socket}
      {:error, stop_reason} -> {:stop, stop_reason, socket}
    end
  end

  # Validates, acknowledges exactly once, and durably records a "start"
  # command via `SddOrchestrator.Worker.CommandHandler`; a `cancel`,
  # `resume`, `retry`, or `reconcile` command is refused cleanly rather than
  # crashing this process, since their full behaviour is later work.
  @impl Slipstream
  def handle_message(topic, "command", message, socket) do
    ack = CommandHandler.handle_command(message, @protocol_version, socket.assigns.home)

    case push(socket, topic, "acknowledge", ack) do
      {:ok, _ref} ->
        if ack["status"] == "accepted", do: prepare_execution(topic, message, socket)
        {:ok, socket}

      {:error, reason} ->
        Logger.error(
          "worker gateway failed to push an acknowledgement for command " <>
            "#{inspect(message["command_id"])}: #{inspect(reason)}"
        )

        {:ok, socket}
    end
  end

  # Any other inbound push is observed and ignored rather than crashing the
  # process on an unrecognized message.
  def handle_message(topic, event, message, socket) do
    Logger.info(
      "worker gateway ignoring unhandled push #{inspect(event)} on #{topic}: #{inspect(message)}"
    )

    {:ok, socket}
  end

  # An accepted command is prepared for execution only after its
  # acknowledgement is on the wire — the acknowledgement is this worker's
  # answer to the command itself, while workspace preparation is a separate,
  # later effect the control plane observes as an event.
  defp prepare_execution(topic, message, socket) do
    case ExecutionPreparer.prepare(message, socket.assigns.home) do
      {:ok, event} ->
        case push(socket, topic, "event", event) do
          {:ok, _ref} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "worker gateway failed to push the workspace_ready event for command " <>
                "#{inspect(message["command_id"])}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.error(
          "worker refused to prepare execution for command " <>
            "#{inspect(message["command_id"])}: #{inspect(reason)}"
        )
    end
  end

  defp establish(%Configuration{} = config, opts) do
    with {:ok, token} <- fetch_gateway_credential(config),
         {:ok, uri} <- websocket_uri(config.control_plane_address, token) do
      topic = "worker:" <> config.project_id

      join_params = %{
        "protocol_version" => Keyword.get(opts, :protocol_version, @protocol_version),
        "capabilities" => Keyword.get(opts, :capabilities, @capabilities)
      }

      socket =
        new_socket()
        |> assign(:project_id, config.project_id)
        |> assign(:topic, topic)
        |> assign(:join_params, join_params)
        |> assign(:home, Keyword.get(opts, :home))

      case connect(socket, uri: uri) do
        {:ok, connecting_socket} -> {:ok, connecting_socket}
        {:error, reason} -> {:error, {:invalid_websocket_configuration, reason}}
      end
    end
  end

  # A worker whose own credential is refused (revoked, rotated away, or
  # unbound for this project) can never connect — this is a hard startup
  # refusal, not a connection that dropped, so it never reaches the socket.
  defp fetch_gateway_credential(%Configuration{} = config) do
    url = config.control_plane_address <> @gateway_credential_path

    case Req.post(url,
           auth: {:bearer, config.worker_credential},
           json: %{"project_id" => config.project_id}
         ) do
      {:ok, %{status: 200, body: %{"token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:gateway_credential_refused, status, body}}

      {:error, reason} ->
        {:error, {:gateway_credential_transport_error, reason}}
    end
  end

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
