defmodule SddOrchestrator.RepositorySelectionTransportDouble do
  @moduledoc """
  A deterministic repository-selection transport for tests.

  Records what the request server handed it and replays a scripted push
  outcome, so the request lifecycle (one outcome per request, expiry,
  cancellation, requester exit, and refusal of a foreign answer) can be proven
  without an attached worker.

  Unlike `SddOrchestrator.CommandTransportDouble`, the recording cannot live in
  the calling process dictionary: the transport is called by
  `SddOrchestrator.RepositorySelection.Server`, which is a different process
  from the test. It lives in an `Agent` started by `install/1` and reached
  through application environment, so the test and the server read and write
  the same recording. Tests using this double are `async: false` for the same
  reason the double exists: it swaps application environment.

  `push/1` answers with the pid of a stand-in worker process, because the
  server monitors what it pushed to. `start_worker/0` starts one and makes it
  current, and a test kills it to prove the `:worker_lost` path.
  """
  @behaviour SddOrchestrator.RepositorySelection.Transport

  @transport_key :repository_selection_transport
  @state_key :repository_selection_transport_double

  @doc """
  Installs this double as the configured transport for one test, starts one
  stand-in worker, and returns the function that restores what was there
  before. Pass it to `on_exit/1`.
  """
  @spec install(term()) :: (-> :ok)
  def install(push_outcome \\ :ok) do
    original_transport = Application.get_env(:sdd_orchestrator, @transport_key)
    original_state = Application.get_env(:sdd_orchestrator, @state_key)

    {:ok, agent} =
      Agent.start(fn -> %{push: push_outcome, pushed: [], cancelled: [], workers: []} end)

    Application.put_env(:sdd_orchestrator, @state_key, agent)
    Application.put_env(:sdd_orchestrator, @transport_key, __MODULE__)
    start_worker()

    fn ->
      restore(@transport_key, original_transport)
      restore(@state_key, original_state)
      stop(agent)
    end
  end

  @doc """
  Changes the scripted push outcome.

  `:ok` pushes to the current stand-in worker. `{:ok, pid}` pushes to a given
  process, and `{:error, reason}` refuses the push.
  """
  @spec script(term()) :: :ok
  def script(push_outcome), do: update(&Map.put(&1, :push, push_outcome))

  @doc "The requests handed to the transport, oldest first."
  @spec pushed() :: [SddOrchestrator.RepositorySelection.SelectionRequest.t()]
  def pushed, do: :pushed |> read([]) |> Enum.reverse()

  @doc "The requests the transport was told to cancel, oldest first."
  @spec cancelled() :: [SddOrchestrator.RepositorySelection.SelectionRequest.t()]
  def cancelled, do: :cancelled |> read([]) |> Enum.reverse()

  @doc "The current stand-in worker process, the pid `push/1` answers with."
  @spec worker() :: pid() | nil
  def worker, do: :workers |> read([]) |> List.first()

  @doc """
  Starts one stand-in worker process and makes it current.

  It does nothing but stay alive, so a test can kill it and prove that losing
  the attachment ends the request.
  """
  @spec start_worker() :: pid()
  def start_worker do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    update(&Map.update!(&1, :workers, fn workers -> [worker | workers] end))
    worker
  end

  @impl true
  def push(request) do
    update(&Map.update!(&1, :pushed, fn pushed -> [request | pushed] end))

    case read(:push, :ok) do
      :ok -> to_worker()
      other -> other
    end
  end

  @impl true
  def cancel(request) do
    update(&Map.update!(&1, :cancelled, fn cancelled -> [request | cancelled] end))
    :ok
  end

  defp to_worker do
    case worker() do
      worker when is_pid(worker) -> {:ok, worker}
      nil -> {:error, :no_worker}
    end
  end

  # The agent is owned by the test, so it can already be gone while the server
  # finishes handling a requester that exited. Recording is then dropped rather
  # than crashing the server.
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
      Enum.each(Agent.get(agent, & &1.workers), &Process.exit(&1, :kill))
      Agent.stop(agent)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
