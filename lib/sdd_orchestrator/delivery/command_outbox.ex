defmodule SddOrchestrator.Delivery.CommandOutbox do
  @moduledoc """
  The durable outbox every worker instruction passes through.

  Enqueueing is a contribution to the caller's transaction, so a command can
  never exist for a state change that rolled back, and a state change can never
  commit without its command. Claiming uses `FOR UPDATE SKIP LOCKED` with an
  expiring lease, so several dispatchers — or several application instances —
  can drain the queue at once without two of them delivering the same command.

  Nothing here treats process memory as authoritative. A restart loses no
  pending work: the queue is rows, and an abandoned claim returns to it when
  its lease expires.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SddOrchestrator.Delivery.RunCommand
  alias SddOrchestrator.Repo

  @default_claim_seconds 60
  @default_batch 20

  @spec default_claim_seconds() :: pos_integer()
  def default_claim_seconds, do: @default_claim_seconds

  @doc """
  Enqueues one command, or returns the recorded one when the ID already exists.

  This is what makes duplicate dispatch harmless: the same instruction produced
  twice is one row, and the second caller sees the first row's recorded state
  and result rather than starting another process.
  """
  @spec enqueue(map()) :: {:ok, RunCommand.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(attrs) do
    Multi.new()
    |> enqueue_multi(:command, attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{command: command}} -> {:ok, command}
      {:error, :command, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Adds one idempotent enqueue to the caller's transaction.

  `attrs` may be a map or a one-argument function of the transaction's changes,
  so a command can name a run or attempt created earlier in the same
  transaction.
  """
  @spec enqueue_multi(Multi.t(), Multi.name(), map() | (map() -> map())) :: Multi.t()
  def enqueue_multi(multi, name, attrs) do
    Multi.run(multi, name, fn repo, changes ->
      attrs = resolve(attrs, changes)

      # The primary key is supplied by the caller, so `on_conflict` cannot tell
      # an insert from a conflict here: it would hand back the unpersisted
      # struct as though it had been written. The recorded row is read first
      # instead, and the insert race falls back to reading it.
      case recorded(repo, attrs) do
        {:ok, command} -> confirm_same_instruction(command, attrs)
        :error -> insert_new(repo, attrs)
      end
    end)
  end

  @doc "Returns the recorded command for one stable ID."
  @spec fetch(Ecto.UUID.t()) :: {:ok, RunCommand.t()} | :error
  def fetch(command_id) do
    case Repo.get(RunCommand, command_id) do
      nil -> :error
      command -> {:ok, command}
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  @doc """
  Claims up to `:limit` due commands for one dispatcher.

  Claiming happens inside one transaction that locks the selected rows with
  `SKIP LOCKED`, so a concurrent dispatcher takes different rows instead of
  blocking or duplicating.
  """
  @spec claim(String.t(), keyword()) :: [RunCommand.t()]
  def claim(owner, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, @default_batch)
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_claim_seconds)
    expires_at = DateTime.add(now, lease_seconds, :second)

    {:ok, claimed} =
      Repo.transaction(fn ->
        claimable(now)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()
        |> Enum.map(fn command ->
          command
          |> RunCommand.claim_changeset(owner, expires_at)
          |> Repo.update!()
        end)
      end)

    claimed
  end

  @doc "Records one delivery attempt for a claimed command."
  @spec mark_delivered(RunCommand.t(), keyword()) ::
          {:ok, RunCommand.t()} | {:error, Ecto.Changeset.t()}
  def mark_delivered(%RunCommand{} = command, opts \\ []) do
    command
    |> RunCommand.delivered_changeset(Keyword.get(opts, :now, DateTime.utc_now()))
    |> Repo.update()
  end

  @doc """
  Records the worker's acknowledgement and result.

  Acknowledging a command that is already acknowledged returns the recorded
  result unchanged, so a duplicate acknowledgement from a reconnecting worker
  is absorbed rather than overwriting the first answer.
  """
  @spec acknowledge(Ecto.UUID.t() | RunCommand.t(), map(), keyword()) ::
          {:ok, RunCommand.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def acknowledge(command, result \\ %{}, opts \\ [])

  def acknowledge(%RunCommand{state: "acknowledged"} = command, _result, _opts),
    do: {:ok, command}

  def acknowledge(%RunCommand{} = command, result, opts) do
    command
    |> RunCommand.acknowledge_changeset(result, Keyword.get(opts, :now, DateTime.utc_now()))
    |> Repo.update()
  end

  def acknowledge(command_id, result, opts) do
    case fetch(command_id) do
      {:ok, command} -> acknowledge(command, result, opts)
      :error -> {:error, :not_found}
    end
  end

  @doc "Records a terminal delivery failure."
  @spec fail(RunCommand.t(), String.t(), keyword()) ::
          {:ok, RunCommand.t()} | {:error, Ecto.Changeset.t()}
  def fail(%RunCommand{} = command, failure_code, opts \\ []) do
    command
    |> RunCommand.failed_changeset(failure_code, Keyword.get(opts, :now, DateTime.utc_now()))
    |> Repo.update()
  end

  @doc """
  Returns commands whose claim lease expired to the pending queue.

  This is the restart path: a dispatcher that died mid-delivery leaves claimed
  rows behind, and nothing else would ever pick them up.
  """
  @spec release_expired(keyword()) :: non_neg_integer()
  def release_expired(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {released, _returned} =
      RunCommand
      |> where([c], c.state in ["claimed", "delivered"])
      |> where([c], not is_nil(c.claim_expires_at) and c.claim_expires_at <= ^now)
      |> Repo.update_all(
        set: [claimed_by: nil, claim_expires_at: nil, state: "pending", due_at: now]
      )

    released
  end

  @doc "Lists the run's commands in due order, newest last."
  @spec for_run(Ecto.UUID.t()) :: [RunCommand.t()]
  def for_run(run_id) do
    RunCommand
    |> where([c], c.run_id == ^run_id)
    |> order_by([c], asc: c.due_at, asc: c.inserted_at)
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  @doc "Counts the commands currently waiting to be claimed."
  @spec pending_count(keyword()) :: non_neg_integer()
  def pending_count(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    now |> claimable() |> Repo.aggregate(:count)
  end

  defp claimable(now) do
    RunCommand
    |> where([c], c.due_at <= ^now)
    |> where(
      [c],
      c.state == "pending" or
        (c.state in ["claimed", "delivered"] and c.claim_expires_at <= ^now)
    )
    |> order_by([c], asc: c.due_at, asc: c.inserted_at)
  end

  defp insert_new(repo, attrs) do
    %RunCommand{}
    |> RunCommand.enqueue_changeset(attrs)
    |> repo.insert()
  rescue
    # Two callers enqueued the same instruction at once. The row that won is the
    # recorded answer for both of them.
    Ecto.ConstraintError ->
      case recorded(repo, attrs) do
        {:ok, command} -> confirm_same_instruction(command, attrs)
        :error -> {:error, :not_found}
      end
  end

  defp recorded(repo, attrs) do
    case Map.get(attrs, :id) || Map.get(attrs, "id") do
      nil -> :error
      id -> repo.get(RunCommand, id) |> then(&if(&1, do: {:ok, &1}, else: :error))
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  # The stored row wins, but a caller reusing one ID for a different instruction
  # is a bug worth surfacing rather than silently dropping.
  defp confirm_same_instruction(command, attrs) do
    operation = Map.get(attrs, :operation) || Map.get(attrs, "operation")

    if is_nil(operation) or command.operation == operation do
      {:ok, command}
    else
      {:error, :command_id_reused}
    end
  end

  defp resolve(attrs, changes) when is_function(attrs, 1), do: attrs.(changes)
  defp resolve(attrs, _changes), do: attrs
end
