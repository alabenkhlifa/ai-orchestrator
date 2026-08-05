defmodule SddOrchestrator.AIRuntime.ObservationAdapter.Codex do
  @moduledoc """
  Worker-local consumer for Codex token-usage and rate-limit notifications.

  One handler is bound to one worker-local connection profile and one App
  Server process. A sparse `thread/tokenUsage/updated` or
  `account/rateLimits/updated` notification is only a trigger: the handler
  validates its shape, performs a complete observation refetch through the
  observation adapter, and delivers the normalized result to an explicit
  worker-local callback.

  Sparse payload fields are never merged, projected, or stored as an
  observation. The notification's own provider-side identifiers, such as the
  thread it names, are read only to decide that the trigger is well formed and
  are never delivered onward.
  """

  use GenServer

  alias SddOrchestrator.AIRuntime.{CodexAppServer, ObservationAdapter}
  alias SddOrchestrator.AIRuntime.ObservationAdapter.RPC

  @notification_methods ~w(thread/tokenUsage/updated account/rateLimits/updated)

  @type safe_delivery :: %{
          connection_ref: String.t(),
          trigger: :complete_observation_refetch,
          result: {:ok, map()} | {:error, ObservationAdapter.error()}
        }

  @doc "The exact notifications this handler accepts as a refetch trigger."
  @spec notification_methods() :: [String.t()]
  def notification_methods, do: @notification_methods

  @doc """
  Validates one sparse notification and reports the action it triggers.

  A notification never carries enough to build an observation, so the only
  action it can produce is a complete refetch.
  """
  @spec handle_notification(String.t(), term()) ::
          {:ok, :refetch} | {:error, :invalid_response}
  def handle_notification("thread/tokenUsage/updated", params) when is_map(params) do
    if exact_keys?(params, ["threadId", "tokenUsage"]) and is_binary(params["threadId"]) and
         is_map(params["tokenUsage"]),
       do: {:ok, :refetch},
       else: {:error, :invalid_response}
  end

  def handle_notification("account/rateLimits/updated", params) when is_map(params) do
    if exact_keys?(params, ["rateLimits"]) and is_map(params["rateLimits"]),
      do: {:ok, :refetch},
      else: {:error, :invalid_response}
  end

  def handle_notification(_method, _params), do: {:error, :invalid_response}

  @doc "Starts one worker-local handler before it is bound as an App Server target."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Binds the handler to the App Server that targets it with notifications."
  @spec bind_app_server(GenServer.server(), CodexAppServer.server()) ::
          :ok | {:error, :invalid_request}
  def bind_app_server(handler, server) do
    GenServer.call(handler, {:bind_app_server, server})
  catch
    :exit, _reason -> {:error, :invalid_request}
  end

  @impl true
  def init(opts) do
    account = Keyword.get(opts, :account)
    connection = Keyword.get(opts, :connection)
    deliver = Keyword.get(opts, :deliver)

    with true <- is_map(account),
         true <- is_map(connection),
         true <- is_binary(Map.get(connection, :worker_profile_ref)),
         true <- Map.get(connection, :provider) == "openai_codex",
         true <- Map.get(connection, :authentication_mode) in ["chatgpt", "api_key"],
         true <- is_function(deliver, 1) do
      {:ok,
       %{
         account: account,
         connection: connection,
         connection_ref: Map.fetch!(connection, :worker_profile_ref),
         app_server: nil,
         adapter: Keyword.get(opts, :adapter, RPC),
         deliver: deliver,
         fetch_options: Keyword.get(opts, :fetch_options, [])
       }}
    else
      _ -> {:stop, :invalid_request}
    end
  end

  @impl true
  def handle_call({:bind_app_server, _server}, _from, %{app_server: current} = state)
      when not is_nil(current) do
    {:reply, {:error, :invalid_request}, state}
  end

  def handle_call({:bind_app_server, server}, _from, state) do
    with {:ok, server_pid} <- resolve_app_server(server),
         true <- CodexAppServer.binding_matches?(server_pid, state.connection_ref) do
      {:reply, :ok, %{state | app_server: server_pid}}
    else
      _ -> {:reply, {:error, :invalid_request}, state}
    end
  end

  @impl true
  def handle_info(
        {CodexAppServer, :notification, server, method, params},
        %{app_server: server} = state
      )
      when method in @notification_methods do
    result =
      case handle_notification(method, params) do
        {:ok, :refetch} -> refetch(state)
        {:error, reason} -> {:error, ObservationAdapter.normalize_error(reason)}
      end

    deliver(state, result)
    {:noreply, state}
  end

  def handle_info({CodexAppServer, :notification, _server, _method, _params}, state),
    do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp refetch(state) do
    case state.adapter.observe(state.account, state.connection, state.fetch_options) do
      {:ok, observation} -> {:ok, observation}
      {:error, reason} -> {:error, ObservationAdapter.normalize_error(reason)}
      _other -> {:error, :invalid_response}
    end
  rescue
    _exception -> {:error, :invalid_response}
  end

  defp resolve_app_server(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> {:ok, pid}
      _other -> {:error, :invalid_request}
    end
  rescue
    _exception -> {:error, :invalid_request}
  catch
    _kind, _reason -> {:error, :invalid_request}
  end

  defp deliver(state, result) do
    delivery = %{
      connection_ref: state.connection_ref,
      trigger: :complete_observation_refetch,
      result: result
    }

    try do
      state.deliver.(delivery)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp exact_keys?(params, expected), do: Enum.sort(Map.keys(params)) == Enum.sort(expected)
end
