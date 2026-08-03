defmodule SddOrchestrator.AIRuntime.CodexAppServer do
  @moduledoc """
  Version-checked worker-local adapter for the Codex App Server.

  The adapter owns one linked standard-input and standard-output process,
  performs the required initialization handshake, admits only the documented
  account and discovery methods needed by the runtime foundation, and
  normalizes every failure to a typed result. Raw App Server errors, stderr,
  credentials, and authenticated account material are never logged here.

  A worker supervisor starts this GenServer for one worker-local Codex profile.
  If the App Server process exits, pending callers fail and a fresh process is
  initialized before the adapter becomes available again.
  """

  use GenServer

  alias SddOrchestrator.AIRuntime.CodexAppServer.{Compatibility, StdioProcess}

  @request_methods ~w(
    account/login/start
    account/login/cancel
    account/rateLimits/read
    account/read
    account/usage/read
    model/list
  )

  @notification_methods ~w(
    account/login/completed
    account/rateLimits/updated
    thread/tokenUsage/updated
  )

  @login_types ~w(apiKey chatgpt chatgptDeviceCode)
  @default_timeout_ms 15_000
  @default_max_response_bytes 256 * 1_024
  @default_restart_delay_ms 10
  @max_discarded_ids 256
  @initialize_id 0

  @credential_keys ~w(
    accesstoken api_key apikey authorization cookie credential password
    refreshtoken secret token
  )

  @typedoc "The only failures exposed outside the worker-local adapter."
  @type error ::
          :unsupported_version
          | :unsupported_schema_digest
          | :unsupported_transport
          | :unsupported_method
          | :unsupported_auth_mode
          | :invalid_request
          | :process_unavailable
          | :not_initialized
          | :initialization_failed
          | :timeout
          | :cancelled
          | :process_crashed
          | :malformed_response
          | :response_too_large
          | :credential_content
          | :app_server_error

  @type server :: GenServer.server()

  @doc "Starts one adapter after verifying its installed-version/schema pair."
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, error()}
  def start_link(opts) do
    version = Keyword.get(opts, :codex_version)
    digest = Keyword.get(opts, :schema_digest)
    registry = Keyword.get(opts, :compatibility_registry, configured_registry())
    transport = Keyword.get(opts, :transport, :stdio)

    with :ok <- validate_transport(transport),
         :ok <- Compatibility.verify(version, digest, registry),
         {:ok, pid} <- start_adapter(opts) do
      case await_ready(pid, Keyword.get(opts, :initialization_timeout_ms, @default_timeout_ms)) do
        :ok ->
          {:ok, pid}

        {:error, reason} ->
          stop(pid)
          {:error, reason}
      end
    end
  end

  @doc "Waits until the current App Server process completes initialization."
  @spec await_ready(server(), pos_integer()) :: :ok | {:error, error()}
  def await_ready(server, timeout_ms \\ @default_timeout_ms) do
    GenServer.call(server, :await_ready, timeout_ms + 100)
  catch
    :exit, _reason -> {:error, :process_unavailable}
  end

  @doc "Stops this adapter and its worker-local App Server process."
  @spec stop(server()) :: :ok
  def stop(server) do
    if Process.alive?(server), do: GenServer.stop(server, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "Calls one allowlisted App Server method with a bounded deadline."
  @spec request(server(), String.t(), map() | nil, keyword()) ::
          {:ok, map() | list() | String.t() | number() | boolean() | nil} | {:error, error()}
  def request(server, method, params \\ %{}, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    GenServer.call(server, {:request, method, params, opts}, timeout_ms + 100)
  catch
    :exit, _reason -> {:error, :process_unavailable}
  end

  @doc "Starts the worker-local managed ChatGPT browser login."
  def login_chatgpt(server, opts \\ []) do
    params = %{
      "type" => "chatgpt",
      "useHostedLoginSuccessPage" => Keyword.get(opts, :hosted_success_page, true)
    }

    request(server, "account/login/start", params, opts)
  end

  @doc "Starts the worker-local managed ChatGPT device-code login."
  def login_chatgpt_device_code(server, opts \\ []) do
    request(server, "account/login/start", %{"type" => "chatgptDeviceCode"}, opts)
  end

  @doc "Starts worker-local API-key login; the key is never retained in state."
  def login_api_key(server, api_key, opts \\ [])

  def login_api_key(server, api_key, opts) when is_binary(api_key) do
    request(server, "account/login/start", %{"type" => "apiKey", "apiKey" => api_key}, opts)
  end

  def login_api_key(_server, _api_key, _opts), do: {:error, :invalid_request}

  @doc "Cancels one App Server login through the documented login method."
  def cancel_login(server, login_id, opts \\ [])

  def cancel_login(server, login_id, opts) when is_binary(login_id) do
    request(server, "account/login/cancel", %{"loginId" => login_id}, opts)
  end

  def cancel_login(_server, _login_id, _opts), do: {:error, :invalid_request}

  @doc "Cancels one locally pending request without projecting a late response."
  @spec cancel(server(), non_neg_integer()) ::
          :ok | {:error, :invalid_request | :process_unavailable}
  def cancel(server, request_id) do
    GenServer.call(server, {:cancel, request_id})
  catch
    :exit, _reason -> {:error, :process_unavailable}
  end

  @doc "The exact documented methods this adapter may call."
  def request_methods, do: @request_methods

  @doc "The exact notifications this adapter may project to its worker-local owner."
  def notification_methods, do: @notification_methods

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      process_module: Keyword.get(opts, :process_module, StdioProcess),
      process_options: Keyword.get(opts, :process_options, []),
      process: nil,
      ready?: false,
      ready_waiters: [],
      pending: %{},
      discarded_ids: MapSet.new(),
      next_id: 1,
      buffer: <<>>,
      max_response_bytes: Keyword.get(opts, :max_response_bytes, @default_max_response_bytes),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      initialization_timeout_ms:
        Keyword.get(opts, :initialization_timeout_ms, @default_timeout_ms),
      restart_delay_ms: Keyword.get(opts, :restart_delay_ms, @default_restart_delay_ms),
      notification_target: Keyword.get(opts, :notification_target),
      client_info:
        Keyword.get(opts, :client_info, %{
          "name" => "sdd_orchestrator",
          "title" => "SDD Orchestrator",
          "version" => "1"
        }),
      stopping?: false
    }

    case start_process(state) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:stop, :process_unavailable}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, %{ready?: true} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  def handle_call({:request, _method, _params, _opts}, _from, %{ready?: false} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call({:request, method, params, opts}, from, state) do
    timeout_ms = Keyword.get(opts, :timeout_ms, state.timeout_ms)
    requested_id = Keyword.get(opts, :request_id)

    with :ok <- validate_request(method, params, timeout_ms),
         {:ok, id, state} <- allocate_id(requested_id, state),
         :ok <- write_frame(state, %{"id" => id, "method" => method, "params" => params}) do
      timer = Process.send_after(self(), {:request_timeout, id}, timeout_ms)
      pending = Map.put(state.pending, id, %{from: from, timer: timer})
      {:noreply, %{state | pending: pending}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, request_id}, _from, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:reply, {:error, :invalid_request}, state}

      {%{from: from, timer: timer}, pending} when is_integer(request_id) and request_id > 0 ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, :cancelled})

        state = %{
          state
          | pending: pending,
            discarded_ids: remember_discarded(state.discarded_ids, request_id)
        }

        {:reply, :ok, state}

      {_not_cancellable, _pending} ->
        {:reply, {:error, :invalid_request}, state}
    end
  end

  @impl true
  def handle_info(
        {:codex_app_server_process, process, :stdout, bytes},
        %{process: process} = state
      ) do
    {:noreply, consume_stdout(bytes, state)}
  end

  def handle_info(
        {:codex_app_server_process, process, :stderr, _bytes},
        %{process: process} = state
      ) do
    # Stderr may contain credentials, raw account identity, or raw provider
    # errors. It is intentionally neither logged nor sent to another process.
    {:noreply, state}
  end

  def handle_info(
        {:codex_app_server_process, process, :exit, _status},
        %{process: process} = state
      ) do
    {:noreply, process_failed(state, :process_crashed)}
  end

  def handle_info({:EXIT, process, _reason}, %{process: process} = state) do
    {:noreply, process_failed(state, :process_crashed)}
  end

  def handle_info({:request_timeout, @initialize_id}, state) do
    {:noreply, protocol_failed(state, :initialization_failed)}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :timeout})

        {:noreply,
         %{
           state
           | pending: pending,
             discarded_ids: remember_discarded(state.discarded_ids, id)
         }}
    end
  end

  def handle_info(:restart_process, %{stopping?: false, process: nil} = state) do
    case start_process(state) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> {:noreply, schedule_restart(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.process, do: state.process_module.stop(state.process)
    :ok
  end

  defp start_adapter(opts) do
    genserver_opts = Keyword.take(opts, [:name, :debug, :spawn_opt, :hibernate_after])
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  defp start_process(state) do
    opts = Keyword.put(state.process_options, :owner, self())

    case state.process_module.start_link(opts) do
      {:ok, process} ->
        state = %{state | process: process, ready?: false, buffer: <<>>}

        case begin_initialization(state) do
          {:ok, state} -> {:ok, state}
          {:error, _reason} -> {:error, :process_unavailable}
        end

      {:error, _reason} ->
        {:error, :process_unavailable}
    end
  end

  defp begin_initialization(state) do
    frame = %{
      "id" => @initialize_id,
      "method" => "initialize",
      "params" => %{"clientInfo" => state.client_info}
    }

    with :ok <- write_frame(state, frame) do
      timer =
        Process.send_after(
          self(),
          {:request_timeout, @initialize_id},
          state.initialization_timeout_ms
        )

      pending = Map.put(state.pending, @initialize_id, %{kind: :initialize, timer: timer})
      {:ok, %{state | pending: pending}}
    end
  end

  defp write_frame(%{process: process, process_module: process_module}, frame) do
    case Jason.encode(frame) do
      {:ok, encoded} ->
        result =
          try do
            process_module.write(process, encoded <> "\n")
          catch
            :exit, _reason -> {:error, :process_unavailable}
          end

        case result do
          :ok -> :ok
          {:error, _reason} -> {:error, :process_unavailable}
        end

      {:error, _reason} ->
        {:error, :invalid_request}
    end
  end

  defp consume_stdout(bytes, state) when is_binary(bytes) do
    parts = :binary.split(state.buffer <> bytes, "\n", [:global])
    {lines, [remainder]} = Enum.split(parts, -1)

    cond do
      byte_size(remainder) > state.max_response_bytes ->
        protocol_failed(%{state | buffer: <<>>}, :response_too_large)

      true ->
        Enum.reduce_while(lines, %{state | buffer: remainder}, fn line, current ->
          cond do
            line == <<>> ->
              {:cont, current}

            byte_size(line) > current.max_response_bytes ->
              {:halt, protocol_failed(%{current | buffer: <<>>}, :response_too_large)}

            true ->
              case Jason.decode(line) do
                {:ok, frame} when is_map(frame) ->
                  updated = receive_frame(frame, current)
                  if updated.process, do: {:cont, updated}, else: {:halt, updated}

                _invalid ->
                  {:halt, protocol_failed(current, :malformed_response)}
              end
          end
        end)
    end
  end

  defp consume_stdout(_bytes, state), do: protocol_failed(state, :malformed_response)

  defp receive_frame(%{"id" => id, "result" => result} = frame, state)
       when map_size(frame) == 2 and is_integer(id) and id >= 0 do
    if credential_shaped?(result) do
      resolve_response(id, {:error, :credential_content}, state)
    else
      resolve_response(id, {:ok, result}, state)
    end
  end

  defp receive_frame(%{"id" => id, "error" => error} = frame, state)
       when map_size(frame) == 2 and is_integer(id) and id >= 0 and is_map(error) do
    reason = if credential_shaped?(error), do: :credential_content, else: :app_server_error
    resolve_response(id, {:error, reason}, state)
  end

  defp receive_frame(%{"method" => method, "params" => params} = frame, state)
       when map_size(frame) == 2 and is_binary(method) and is_map(params) do
    if method in @notification_methods and not credential_shaped?(params) do
      if is_pid(state.notification_target) do
        send(state.notification_target, {__MODULE__, :notification, method, params})
      end

      state
    else
      protocol_failed(state, :malformed_response)
    end
  end

  defp receive_frame(_frame, state), do: protocol_failed(state, :malformed_response)

  defp resolve_response(id, reply, state) do
    cond do
      MapSet.member?(state.discarded_ids, id) ->
        %{state | discarded_ids: MapSet.delete(state.discarded_ids, id)}

      id == @initialize_id ->
        resolve_initialization(reply, state)

      true ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            protocol_failed(state, :malformed_response)

          {%{from: from, timer: timer}, pending} ->
            Process.cancel_timer(timer)
            GenServer.reply(from, reply)
            %{state | pending: pending}
        end
    end
  end

  defp resolve_initialization({:ok, result}, state) when is_map(result) do
    case Map.pop(state.pending, @initialize_id) do
      {%{kind: :initialize, timer: timer}, pending} ->
        Process.cancel_timer(timer)

        case write_frame(%{state | pending: pending}, %{
               "method" => "initialized",
               "params" => %{}
             }) do
          :ok ->
            Enum.each(state.ready_waiters, &GenServer.reply(&1, :ok))
            %{state | pending: pending, ready?: true, ready_waiters: []}

          {:error, _reason} ->
            protocol_failed(%{state | pending: pending}, :initialization_failed)
        end

      _missing ->
        protocol_failed(state, :malformed_response)
    end
  end

  defp resolve_initialization({:error, _reason}, state) do
    protocol_failed(state, :initialization_failed)
  end

  defp resolve_initialization(_invalid, state) do
    protocol_failed(state, :initialization_failed)
  end

  defp validate_request(method, params, timeout_ms) do
    cond do
      method not in @request_methods -> {:error, :unsupported_method}
      not (is_map(params) or is_nil(params)) -> {:error, :invalid_request}
      not is_integer(timeout_ms) or timeout_ms <= 0 -> {:error, :invalid_request}
      method == "account/login/start" -> validate_login(params)
      credential_shaped?(params) -> {:error, :invalid_request}
      true -> :ok
    end
  end

  defp validate_login(%{"type" => type} = params) when type in @login_types do
    case type do
      "apiKey" ->
        if keys_are?(params, ~w(apiKey type)) and is_binary(params["apiKey"]) and
             byte_size(params["apiKey"]) > 0,
           do: :ok,
           else: {:error, :invalid_request}

      "chatgpt" ->
        if keys_within?(
             params,
             ~w(appBrand codexStreamlinedLogin type useHostedLoginSuccessPage)
           ),
           do: :ok,
           else: {:error, :unsupported_auth_mode}

      "chatgptDeviceCode" ->
        if keys_are?(params, ~w(type)),
          do: :ok,
          else: {:error, :unsupported_auth_mode}
    end
  end

  defp validate_login(%{"type" => _unsupported}), do: {:error, :unsupported_auth_mode}
  defp validate_login(_params), do: {:error, :invalid_request}

  defp allocate_id(nil, state), do: {:ok, state.next_id, %{state | next_id: state.next_id + 1}}

  defp allocate_id(id, state) when is_integer(id) and id > 0 do
    if Map.has_key?(state.pending, id) or MapSet.member?(state.discarded_ids, id) do
      {:error, :invalid_request}
    else
      {:ok, id, %{state | next_id: max(state.next_id, id + 1)}}
    end
  end

  defp allocate_id(_id, _state), do: {:error, :invalid_request}

  defp protocol_failed(state, reason) do
    state
    |> fail_all(reason)
    |> stop_current_process()
    |> schedule_restart()
  end

  defp process_failed(state, reason) do
    state
    |> Map.put(:process, nil)
    |> Map.put(:ready?, false)
    |> Map.put(:buffer, <<>>)
    |> fail_all(reason)
    |> schedule_restart()
  end

  defp fail_all(state, reason) do
    Enum.each(state.pending, fn
      {@initialize_id, %{timer: timer}} ->
        Process.cancel_timer(timer)

      {_id, %{from: from, timer: timer}} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, reason})
    end)

    Enum.each(state.ready_waiters, &GenServer.reply(&1, {:error, reason}))

    %{state | pending: %{}, ready_waiters: [], ready?: false, buffer: <<>>}
  end

  defp stop_current_process(%{process: nil} = state), do: state

  defp stop_current_process(state) do
    process = state.process
    state = %{state | process: nil}
    state.process_module.stop(process)
    state
  end

  defp schedule_restart(%{stopping?: true} = state), do: state

  defp schedule_restart(state) do
    Process.send_after(self(), :restart_process, state.restart_delay_ms)
    state
  end

  defp credential_shaped?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} -> credential_key?(key) or credential_shaped?(nested) end)
  end

  defp credential_shaped?(value) when is_list(value), do: Enum.any?(value, &credential_shaped?/1)

  defp credential_shaped?(value) when is_binary(value) do
    Regex.match?(~r/\bBearer\s+\S+/i, value) or
      Regex.match?(~r/\bsk-[A-Za-z0-9_-]{8,}\b/, value) or
      Regex.match?(~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, value)
  end

  defp credential_shaped?(_value), do: false

  defp credential_key?(key) when is_atom(key), do: credential_key?(Atom.to_string(key))

  defp credential_key?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    normalized in Enum.map(@credential_keys, &String.replace(&1, "_", ""))
  end

  defp credential_key?(_key), do: false

  defp keys_are?(map, keys), do: map |> Map.keys() |> Enum.sort() == Enum.sort(keys)

  defp keys_within?(map, keys), do: Enum.all?(Map.keys(map), &(&1 in keys))

  defp remember_discarded(discarded_ids, id) do
    discarded_ids = MapSet.put(discarded_ids, id)

    if MapSet.size(discarded_ids) > @max_discarded_ids do
      MapSet.delete(discarded_ids, Enum.min(discarded_ids))
    else
      discarded_ids
    end
  end

  defp validate_transport(:stdio), do: :ok
  defp validate_transport(_transport), do: {:error, :unsupported_transport}

  defp configured_registry do
    Application.get_env(:sdd_orchestrator, :codex_app_server_compatibility, %{})
  end
end
