defmodule SddOrchestrator.AIRuntime.CodexAppServer.Process do
  @moduledoc """
  Worker-local process boundary used by the Codex App Server adapter.

  Implementations send stdout, stderr, and exit messages to the owner using
  the tuples documented by this behaviour. Tests replace the operating-system
  process with a deterministic double.
  """

  @type option :: {:owner, pid()} | {:executable, String.t()}

  @callback start_link([option() | term()]) :: {:ok, pid()} | {:error, term()}
  @callback write(pid(), binary()) :: :ok | {:error, term()}
  @callback stop(pid()) :: :ok
end

defmodule SddOrchestrator.AIRuntime.CodexAppServer.StdioProcess do
  @moduledoc """
  A linked operating-system process running `codex app-server --stdio`.

  The fixed launcher redirects stderr to the operating-system null device
  before starting Codex. The executable path is passed as a quoted positional
  argument rather than interpolated into the launcher, so stderr cannot leak
  and the path cannot change the command.
  """

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

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    executable = Keyword.get(opts, :executable, "codex")

    with path when is_binary(path) <- System.find_executable(executable),
         port when is_port(port) <- open_port(path) do
      {:ok, %{owner: owner, port: port}}
    else
      _missing -> {:stop, :process_unavailable}
    end
  end

  @impl true
  def handle_call({:write, bytes}, _from, %{port: port} = state) when is_binary(bytes) do
    reply = if Port.command(port, bytes), do: :ok, else: {:error, :process_unavailable}
    {:reply, reply, state}
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{owner: owner, port: port} = state) do
    send(owner, {:codex_app_server_process, self(), :stdout, bytes})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{owner: owner, port: port} = state) do
    send(owner, {:codex_app_server_process, self(), :exit, status})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, _reason -> :ok
  end

  defp open_port(path) do
    Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [
        :binary,
        :exit_status,
        :use_stdio,
        args: [
          ~c"-c",
          ~c"exec \"$1\" app-server --stdio 2>/dev/null",
          ~c"sdd-codex-app-server",
          String.to_charlist(path)
        ]
      ]
    )
  end
end
