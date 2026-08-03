defmodule SddOrchestrator.CodexAppServerProcessDouble do
  @moduledoc false

  use GenServer

  @behaviour SddOrchestrator.AIRuntime.CodexAppServer.Process

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def write(process, bytes), do: GenServer.call(process, {:write, bytes})

  @impl true
  def stop(process) do
    if Process.alive?(process), do: GenServer.stop(process, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def respond(process, id, result) do
    stdout(process, %{"id" => id, "result" => result})
  end

  def error(process, id, error) do
    stdout(process, %{"id" => id, "error" => error})
  end

  def notify(process, method, params) do
    stdout(process, %{"method" => method, "params" => params})
  end

  def stdout(process, frame) when is_map(frame) do
    raw_stdout(process, Jason.encode!(frame) <> "\n")
  end

  def raw_stdout(process, bytes), do: GenServer.call(process, {:stdout, bytes})
  def stderr(process, bytes), do: GenServer.call(process, {:stderr, bytes})
  def crash(process), do: GenServer.cast(process, :crash)

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {__MODULE__, :started, self()})

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       test_pid: test_pid,
       initialize_result:
         Keyword.get(opts, :initialize_result, %{
           "userAgent" => "codex-test",
           "platformFamily" => "unix",
           "platformOs" => "test"
         })
     }}
  end

  @impl true
  def handle_call({:write, bytes}, _from, state) do
    case Jason.decode(String.trim_trailing(bytes, "\n")) do
      {:ok, frame} ->
        send(state.test_pid, {__MODULE__, :write, self(), frame})

        if frame["method"] == "initialize" do
          send(
            state.owner,
            {:codex_app_server_process, self(), :stdout,
             Jason.encode!(%{"id" => frame["id"], "result" => state.initialize_result}) <>
               "\n"}
          )
        end

        {:reply, :ok, state}

      {:error, _reason} ->
        {:reply, {:error, :invalid_write}, state}
    end
  end

  def handle_call({:stdout, bytes}, _from, state) do
    send(state.owner, {:codex_app_server_process, self(), :stdout, bytes})
    {:reply, :ok, state}
  end

  def handle_call({:stderr, bytes}, _from, state) do
    send(state.owner, {:codex_app_server_process, self(), :stderr, bytes})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:crash, state), do: {:stop, :normal, state}
end
