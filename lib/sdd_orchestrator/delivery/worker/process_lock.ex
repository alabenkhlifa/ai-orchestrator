defmodule SddOrchestrator.Delivery.Worker.ProcessLock do
  @moduledoc """
  One current process per run workspace, and one way past a stuck one.

  The lock lives on disk inside the run's own workspace because the holder may
  be a different operating-system process, or the same worker after a restart:
  a lock held only in memory disappears exactly when it is needed. It records
  the holder's operating-system process and the fence token of the attempt that
  claimed it.

  Fencing, not liveness, is the guarantee. A higher fence token always takes the
  lock, because the control plane has already superseded the attempt holding it;
  a lower one never does, so a delayed command from an old attempt can never
  reclaim a workspace that moved on. Liveness only decides whether an equal
  fence may reclaim its own workspace after a crash, and when liveness cannot be
  determined the answer stays "still held" — two agents in one workspace is a
  worse outcome than waiting for the next fence.

  Cancellation is a file rather than a message. The process that cancels a run
  is not the process that holds the lock and may not share a VM with it, so the
  stop request is written where the holder is already looking.
  """

  alias SddOrchestrator.Delivery.CanonicalJson
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.Worker.Workspace

  @lock_file "run.lock"
  @stop_file "run.stop"

  @enforce_keys [:workspace, :run_id, :os_pid, :fence_token, :acquired_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          workspace: String.t(),
          run_id: String.t(),
          os_pid: String.t(),
          fence_token: pos_integer(),
          acquired_at: DateTime.t()
        }

  @type error ::
          :fenced
          | :invalid_fence_token
          | :lock_unreadable
          | :locked
          | Workspace.error()

  @doc """
  Claims this run's workspace for the calling process at one fence token.

  `:alive?` and `:os_pid` exist so the fencing and reclaim rules can be proven
  without arranging real operating-system processes; both default to this
  process and a real liveness probe.
  """
  @spec acquire(ExecutionManifest.t(), pos_integer(), keyword()) :: {:ok, t()} | {:error, error()}
  def acquire(manifest, fence_token, opts \\ [])

  def acquire(%ExecutionManifest{} = manifest, fence_token, opts)
      when is_integer(fence_token) and fence_token > 0 do
    os_pid = Keyword.get(opts, :os_pid, System.pid())

    with {:ok, workspace} <- Workspace.prepare(manifest),
         {:ok, current} <- read_lock(workspace),
         :ok <- claimable(current, fence_token, os_pid, probe(opts)) do
      claim(workspace, manifest.run_id, fence_token, os_pid)
    end
  end

  def acquire(%ExecutionManifest{}, _fence_token, _opts), do: {:error, :invalid_fence_token}
  def acquire(_manifest, _fence_token, _opts), do: {:error, :invalid_manifest}

  @doc """
  Releases a lock this holder still owns.

  A workspace already taken over by a higher fence is left alone: releasing it
  would hand the next attempt's workspace to nobody.
  """
  @spec release(t()) :: :ok | {:error, error()}
  def release(%__MODULE__{} = lock) do
    case read_lock(lock.workspace) do
      {:ok, nil} -> :ok
      {:ok, current} -> release_held(lock, current)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Whether the recorded holder is gone and its workspace can be reclaimed.

  An unreadable record is not reclaimable. Nothing proved the holder gone, and
  a higher fence token remains the way through.
  """
  @spec stale?(t(), keyword()) :: boolean()
  def stale?(%__MODULE__{} = lock, opts \\ []) do
    case read_lock(lock.workspace) do
      {:ok, nil} -> true
      {:ok, current} -> not probe(opts).(current.os_pid)
      {:error, _reason} -> false
    end
  end

  @doc """
  Records that whoever holds this run's workspace should stop.

  A cancel command calls this; the holder observes it through
  `stop_requested?/1` at its own next safe point. Nothing here kills a process,
  because a stop the holder performs itself is the only one that can leave the
  workspace in a state the next attempt can resume from.
  """
  @spec request_stop(t() | ExecutionManifest.t()) :: :ok | {:error, error()}
  def request_stop(%__MODULE__{workspace: workspace, fence_token: fence_token}),
    do: write_stop(workspace, fence_token)

  def request_stop(%ExecutionManifest{} = manifest) do
    with {:ok, workspace} <- Workspace.prepare(manifest),
         {:ok, current} <- read_lock(workspace) do
      write_stop(workspace, current && current.fence_token)
    end
  end

  def request_stop(_target), do: {:error, :invalid_manifest}

  @doc """
  Whether this holder has been asked to stop.

  An unreadable request counts as a request: a cancellation that cannot be read
  must not become a cancellation that never happened.
  """
  @spec stop_requested?(t()) :: boolean()
  def stop_requested?(%__MODULE__{} = lock) do
    case read_stop(lock.workspace) do
      {:ok, nil} -> false
      {:ok, %{fence_token: nil}} -> true
      {:ok, %{fence_token: fence_token}} -> fence_token >= lock.fence_token
      {:error, _reason} -> true
    end
  end

  defp claimable(nil, _fence_token, _os_pid, _probe), do: :ok

  defp claimable(current, fence_token, os_pid, probe) do
    cond do
      fence_token > current.fence_token -> :ok
      fence_token < current.fence_token -> {:error, :fenced}
      current.os_pid == os_pid -> :ok
      probe.(current.os_pid) -> {:error, :locked}
      true -> :ok
    end
  end

  defp claim(workspace, run_id, fence_token, os_pid) do
    lock = %__MODULE__{
      workspace: workspace,
      run_id: run_id,
      os_pid: os_pid,
      fence_token: fence_token,
      acquired_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    with :ok <- write_lock(lock),
         :ok <- clear_superseded_stop(workspace, fence_token) do
      {:ok, lock}
    end
  end

  defp release_held(lock, current) do
    if current.fence_token == lock.fence_token and current.os_pid == lock.os_pid do
      discard(lock.workspace)
    else
      {:error, :fenced}
    end
  end

  defp discard(workspace) do
    case remove(Path.join(workspace, @lock_file)) do
      :ok -> remove(Path.join(workspace, @stop_file))
      {:error, _reason} = error -> error
    end
  end

  # A stop request belonging to a superseded attempt must not stop the attempt
  # that replaced it. One recorded against no holder is kept: it was written for
  # whoever runs here next.
  defp clear_superseded_stop(workspace, fence_token) do
    case read_stop(workspace) do
      {:ok, %{fence_token: recorded}} when is_integer(recorded) and recorded < fence_token ->
        remove(Path.join(workspace, @stop_file))

      _current ->
        :ok
    end
  end

  defp write_lock(%__MODULE__{} = lock) do
    write(Path.join(lock.workspace, @lock_file), %{
      "run_id" => lock.run_id,
      "os_pid" => lock.os_pid,
      "fence_token" => lock.fence_token,
      "acquired_at" => DateTime.to_iso8601(lock.acquired_at)
    })
  end

  defp write_stop(workspace, fence_token) do
    write(Path.join(workspace, @stop_file), %{
      "fence_token" => fence_token,
      "requested_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end

  defp read_lock(workspace) do
    case read(Path.join(workspace, @lock_file)) do
      {:ok, nil} -> {:ok, nil}
      {:ok, contents} -> decode_lock(contents)
      {:error, _reason} -> {:error, :lock_unreadable}
    end
  end

  defp read_stop(workspace) do
    case read(Path.join(workspace, @stop_file)) do
      {:ok, nil} -> {:ok, nil}
      {:ok, contents} -> decode_stop(contents)
      {:error, _reason} -> {:error, :lock_unreadable}
    end
  end

  defp decode_lock(contents) do
    case CanonicalJson.decode(contents) do
      {:ok, %{"run_id" => run_id, "os_pid" => os_pid, "fence_token" => fence_token}}
      when is_binary(run_id) and is_binary(os_pid) and is_integer(fence_token) ->
        {:ok, %{run_id: run_id, os_pid: os_pid, fence_token: fence_token}}

      _unreadable ->
        {:error, :lock_unreadable}
    end
  end

  defp decode_stop(contents) do
    case CanonicalJson.decode(contents) do
      {:ok, %{"fence_token" => fence_token}}
      when is_nil(fence_token) or is_integer(fence_token) ->
        {:ok, %{fence_token: fence_token}}

      _unreadable ->
        {:error, :lock_unreadable}
    end
  end

  # Every path below is the run workspace the caller already proved contained,
  # joined with a fixed file name, so none of these are traversal sinks.
  # Documented false positives.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(path, payload) do
    with {:ok, encoded} <- CanonicalJson.encode(payload),
         :ok <- File.write(path, encoded) do
      :ok
    else
      _failed -> {:error, :workspace_unavailable}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :workspace_unavailable}
    end
  end

  defp probe(opts), do: Keyword.get(opts, :alive?, &alive?/1)

  # The BEAM has no primitive for "is this operating-system process alive", and
  # the holder may live in another VM entirely, so liveness is a signal-free
  # `kill -0` probe. A probe that cannot run at all answers "alive": stealing a
  # lock nobody disproved would put two agents in one workspace.
  # sobelow_skip ["CI.System"]
  defp alive?(os_pid) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _unavailable -> true
  end
end
