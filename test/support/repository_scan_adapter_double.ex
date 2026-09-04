defmodule SddOrchestrator.RepositoryScanAdapterDouble do
  @moduledoc """
  A scripted `RepositoryScanAdapter` for tests that drive a screen.

  The recording cannot live in the calling process dictionary: a LiveView runs
  its scan in a task it starts, which is a different process from the test and
  from the LiveView. It lives in an `Agent` started by `install/1` and reached
  through application environment, the same shape
  `SddOrchestrator.RepositoryScanTransportDouble` uses and for the same reason.

  Tests using this double are `async: false`, because it swaps application
  environment.
  """
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter

  @adapter_key :repository_scan_adapter
  @state_key :repository_scan_adapter_double

  @doc """
  Installs this double as the configured adapter for one test and returns the
  function that restores what was there before. Pass it to `on_exit/1`.
  """
  @spec install(term()) :: (-> :ok)
  def install(outcome) do
    original_adapter = Application.get_env(:sdd_orchestrator, @adapter_key)
    original_state = Application.get_env(:sdd_orchestrator, @state_key)

    {:ok, agent} = Agent.start(fn -> %{outcome: outcome, requests: [], hold: nil} end)

    Application.put_env(:sdd_orchestrator, @state_key, agent)
    Application.put_env(:sdd_orchestrator, @adapter_key, __MODULE__)

    fn ->
      restore(@adapter_key, original_adapter)
      restore(@state_key, original_state)
      stop(agent)
    end
  end

  @doc "Changes the scripted outcome."
  @spec script(term()) :: :ok
  def script(outcome), do: update(&Map.put(&1, :outcome, outcome))

  @doc """
  Makes every later scan block until `release/0`, so a test can see the waiting
  state and press the control that stops it.
  """
  @spec hold() :: :ok
  def hold do
    {:ok, gate} = Agent.start(fn -> :held end)
    update(&Map.put(&1, :hold, gate))
  end

  @doc "Lets a held scan finish."
  @spec release() :: :ok
  def release do
    case read(:hold, nil) do
      gate when is_pid(gate) -> if Process.alive?(gate), do: Agent.stop(gate)
      nil -> :ok
    end

    update(&Map.put(&1, :hold, nil))
  end

  @doc "The requests handed to the adapter, oldest first."
  @spec requests() :: [map()]
  def requests, do: read(:requests, [])

  @impl true
  def scan(request) do
    update(&Map.update!(&1, :requests, fn requests -> requests ++ [request] end))

    case read(:hold, nil) do
      gate when is_pid(gate) -> await(gate)
      nil -> :ok
    end

    read(:outcome, {:error, :worker_unavailable})
  end

  # A held scan waits for the gate agent to stop, which is what `release/0`
  # does. Monitoring rather than polling keeps the wait exact.
  defp await(gate) do
    ref = Process.monitor(gate)

    receive do
      {:DOWN, ^ref, :process, ^gate, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp agent do
    case Application.get_env(:sdd_orchestrator, @state_key) do
      agent when is_pid(agent) -> if Process.alive?(agent), do: agent
      _absent -> nil
    end
  end

  defp read(key, default) do
    case agent() do
      nil -> default
      agent -> Agent.get(agent, &Map.get(&1, key, default))
    end
  catch
    :exit, _reason -> default
  end

  defp update(fun) do
    case agent() do
      nil -> :ok
      agent -> Agent.update(agent, fun)
    end
  catch
    :exit, _reason -> :ok
  end

  defp restore(key, nil), do: Application.delete_env(:sdd_orchestrator, key)
  defp restore(key, value), do: Application.put_env(:sdd_orchestrator, key, value)

  defp stop(agent) do
    if Process.alive?(agent) do
      case Agent.get(agent, & &1.hold) do
        gate when is_pid(gate) -> if Process.alive?(gate), do: Agent.stop(gate)
        _none -> :ok
      end

      Agent.stop(agent)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
