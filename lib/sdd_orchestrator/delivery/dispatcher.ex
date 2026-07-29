defmodule SddOrchestrator.Delivery.Dispatcher do
  @moduledoc """
  Supervised delivery of due worker commands.

  The dispatcher holds no authoritative state. On every tick it returns expired
  claims to the queue, claims a bounded batch, and hands each command to the
  configured transport. If it crashes or the node restarts, the next tick — on
  this instance or another — finds exactly the same rows, because the queue is
  the database and not this process.

  A command whose transport reports no connected worker is deliberately left
  claimed with a short lease rather than failed: the work is still wanted, and
  it becomes due again as soon as the lease expires.
  """
  use GenServer

  require Logger

  alias SddOrchestrator.Delivery.{CommandOutbox, CommandTransport}

  @default_interval :timer.seconds(5)
  @default_batch 20
  @default_lease_seconds 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one dispatch cycle now and returns what it did."
  @spec dispatch_now(keyword()) :: %{released: non_neg_integer(), delivered: non_neg_integer()}
  def dispatch_now(opts \\ []), do: run_cycle(options(opts))

  @impl true
  def init(opts) do
    options = options(opts)
    schedule(options.interval)
    {:ok, options}
  end

  @impl true
  def handle_info(:dispatch, options) do
    safe_cycle(options)
    schedule(options.interval)
    {:noreply, options}
  end

  @impl true
  def handle_call(:dispatch_now, _from, options), do: {:reply, run_cycle(options), options}

  defp schedule(interval), do: Process.send_after(self(), :dispatch, interval)

  defp safe_cycle(options) do
    run_cycle(options)
  rescue
    error ->
      # A dispatch failure must never take the supervisor down with it; the
      # rows are untouched and the next tick retries them.
      Logger.warning("[delivery_dispatcher] cycle failed: #{inspect(error.__struct__)}")
      %{released: 0, delivered: 0}
  end

  defp run_cycle(options) do
    released = CommandOutbox.release_expired()

    delivered =
      options.owner
      |> CommandOutbox.claim(limit: options.batch, lease_seconds: options.lease_seconds)
      |> Enum.count(&deliver(&1))

    %{released: released, delivered: delivered}
  end

  defp deliver(command) do
    case CommandTransport.deliver(command) do
      :ok ->
        {:ok, _delivered} = CommandOutbox.mark_delivered(command)
        true

      {:error, reason} ->
        # The command keeps its claim and becomes due again when the lease
        # expires. Nothing is lost and nothing is delivered twice meanwhile.
        Logger.debug("[delivery_dispatcher] #{command.operation} not delivered: #{reason}")
        false
    end
  end

  defp options(opts) do
    %{
      interval: Keyword.get(opts, :interval, @default_interval),
      batch: Keyword.get(opts, :batch, @default_batch),
      lease_seconds: Keyword.get(opts, :lease_seconds, @default_lease_seconds),
      owner: Keyword.get(opts, :owner, default_owner())
    }
  end

  # The claim owner identifies the instance, so an operator can see which node
  # holds a lease without it meaning anything to the authoritative state.
  defp default_owner, do: "dispatcher@#{node()}"
end
