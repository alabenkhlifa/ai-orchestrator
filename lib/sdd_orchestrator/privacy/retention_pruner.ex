defmodule SddOrchestrator.Privacy.RetentionPruner do
  @moduledoc """
  Supervised, hourly retention pruner.

  Runs `Retention.prune_all/1` on a fixed interval under a PostgreSQL advisory lock,
  so that when several application instances run, only one prunes at a time and the
  work stays idempotent. The pruner is started by the application supervisor except
  where `config :sdd_orchestrator, :start_retention_pruner` is false (the test
  environment drives `Retention` directly instead).
  """
  use GenServer

  require Logger

  alias SddOrchestrator.Privacy.Retention
  alias SddOrchestrator.Repo

  # A stable, arbitrary key so every instance contends for the same advisory lock.
  @advisory_lock_key 748_213_905
  @default_interval :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_with_lock()
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :prune, interval)

  @doc """
  Acquires the advisory lock, prunes, and releases it. Returns the per-category
  delete counts, or `:locked` when another instance holds the lock.
  """
  @spec prune_with_lock() :: %{atom() => non_neg_integer()} | :locked
  def prune_with_lock do
    case Repo.query("SELECT pg_try_advisory_lock($1)", [@advisory_lock_key]) do
      {:ok, %{rows: [[true]]}} ->
        try do
          Retention.prune_all()
        after
          Repo.query("SELECT pg_advisory_unlock($1)", [@advisory_lock_key])
        end

      {:ok, _not_acquired} ->
        :locked

      {:error, reason} ->
        Logger.warning("retention pruner could not acquire advisory lock: #{inspect(reason)}")
        :locked
    end
  end
end
