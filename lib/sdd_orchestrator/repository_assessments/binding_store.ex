defmodule SddOrchestrator.RepositoryAssessments.BindingStore do
  @moduledoc """
  Transient single-use storage for prepared repository bindings.

  The store is attached lazily to the existing application supervisor so Task 7
  needs no shared application or Endpoint edits. Losing the process invalidates
  every preparation, which is the fail-closed behavior for non-authoritative
  short-lived state.
  """

  use GenServer

  alias SddOrchestrator.RepositoryAssessments.RepositoryBindingPreparation

  @type entry :: %{
          preparation: RepositoryBindingPreparation.t(),
          request: map(),
          adapter: module()
        }

  @spec ensure_started() :: {:ok, pid()} | {:error, term()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_under_application()
      pid -> {:ok, pid}
    end
  end

  @spec put(RepositoryBindingPreparation.t(), map(), module()) :: :ok | {:error, atom()}
  def put(preparation, request, adapter) do
    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:put, preparation, request, adapter})
    end
  end

  @spec take(Ecto.UUID.t(), binary()) :: {:ok, entry()} | {:error, :unknown_or_replayed}
  def take(nonce, fingerprint) do
    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:take, nonce, fingerprint})
    else
      _error -> {:error, :unknown_or_replayed}
    end
  end

  @spec discard(Ecto.UUID.t(), binary()) :: :ok
  def discard(nonce, fingerprint) do
    case take(nonce, fingerprint) do
      {:ok, _entry} -> :ok
      {:error, :unknown_or_replayed} -> :ok
    end
  end

  @doc false
  def reset do
    with {:ok, _pid} <- ensure_started(), do: GenServer.call(__MODULE__, :reset)
  end

  @doc false
  def count do
    with {:ok, _pid} <- ensure_started(), do: GenServer.call(__MODULE__, :count)
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put, preparation, request, adapter}, _from, state) do
    if Map.has_key?(state, preparation.nonce) do
      {:reply, {:error, :nonce_collision}, state}
    else
      entry = %{preparation: preparation, request: request, adapter: adapter}
      {:reply, :ok, Map.put(state, preparation.nonce, entry)}
    end
  end

  @impl true
  def handle_call({:take, nonce, fingerprint}, _from, state) do
    case Map.pop(state, nonce) do
      {nil, unchanged} ->
        {:reply, {:error, :unknown_or_replayed}, unchanged}

      {%{preparation: preparation} = entry, remaining} ->
        if secure_equal?(RepositoryBindingPreparation.fingerprint(preparation), fingerprint) do
          {:reply, {:ok, entry}, remaining}
        else
          {:reply, {:error, :unknown_or_replayed}, remaining}
        end
    end
  end

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  @impl true
  def handle_call(:count, _from, state), do: {:reply, map_size(state), state}

  defp start_under_application do
    case Supervisor.start_child(SddOrchestrator.Supervisor, __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :already_present} -> restart_under_application()
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp restart_under_application do
    case Supervisor.restart_child(SddOrchestrator.Supervisor, __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:running, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false
end
