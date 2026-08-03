defmodule SddOrchestrator.AIRuntime.QuotaAdapter.CodexNotificationHandler do
  @moduledoc """
  Worker-local consumer for Codex rate-limit update notifications.

  One handler is bound to one worker-local connection profile and one App
  Server process. A sparse `account/rateLimits/updated` notification is only a
  trigger: the handler validates it, performs a complete quota refetch, and
  delivers the normalized result to an explicit worker-local callback. Sparse
  payload fields are never merged or projected as a complete snapshot.
  """

  use GenServer

  alias SddOrchestrator.AIRuntime.{CodexAppServer, QuotaAdapter}
  alias SddOrchestrator.AIRuntime.QuotaAdapter.Codex

  @type safe_delivery :: %{
          connection_ref: String.t(),
          trigger: :complete_rate_limit_refetch,
          result: {:ok, QuotaAdapter.result()} | {:error, QuotaAdapter.error()}
        }

  @doc "Starts one worker-local handler before it is bound as an App Server target."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

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
        {CodexAppServer, :notification, server, "account/rateLimits/updated", params},
        %{app_server: server} = state
      ) do
    result =
      with {:ok, :refetch} <- Codex.handle_notification("account/rateLimits/updated", params) do
        fetch_options = Keyword.put(state.fetch_options, :server, state.app_server)
        Codex.fetch(state.account, state.connection, fetch_options)
      else
        {:error, reason} -> {:error, QuotaAdapter.normalize_error(reason)}
      end

    deliver(state, result)
    {:noreply, state}
  end

  def handle_info({CodexAppServer, :notification, _server, _method, _params}, state),
    do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

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
      trigger: :complete_rate_limit_refetch,
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
end
