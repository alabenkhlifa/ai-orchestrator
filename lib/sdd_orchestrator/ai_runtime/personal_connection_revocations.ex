defmodule SddOrchestrator.AIRuntime.PersonalConnectionRevocations do
  @moduledoc """
  System-level reconciliation of outstanding worker-local credential removals.

  Requesting revocation denies new work immediately, but the credential itself
  can only be removed by the worker that holds it. When that worker is
  unreachable the connection stays pending with one typed reason, and this
  module is what eventually finishes the job: it retries the bounded removal,
  advances the connection to acknowledged when the worker confirms, and lets
  retention delete the opaque reference once the terminal window passes.

  Every entry point is idempotent and safe to run concurrently. A sweep holds a
  PostgreSQL advisory lock on one checked-out connection, so several application
  instances do not send the same worker the same removal request at once, and a
  contended sweep yields instead of duplicating work. Each individual write also
  re-reads its row under a row lock, so a lost lock could still not corrupt a
  connection's state.

  A worker that never returns leaves its connection pending indefinitely. That
  is deliberate: acknowledging an unproven removal would claim a credential was
  destroyed when nothing observed it. Account erasure and service termination
  remove the control-plane reference regardless, and report the removal as
  outstanding rather than done.
  """

  import Ecto.Query

  require Logger

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.AIRuntime.{PersonalAIConnection, PersonalConnections}
  alias SddOrchestrator.Repo

  # A stable, arbitrary key so every instance contends for the same lock.
  @advisory_lock_key 613_477_218

  @default_batch_limit 25

  # A sweep contacts many workers in one pass while holding a database
  # connection, so it waits far less on each than an interactive request does.
  @default_timeout_ms 5_000

  @type summary :: %{
          connections: non_neg_integer(),
          acknowledged: non_neg_integer(),
          outstanding: non_neg_integer(),
          outstanding_reasons: [atom()]
        }

  @doc false
  @spec advisory_lock_key() :: pos_integer()
  def advisory_lock_key, do: @advisory_lock_key

  @doc """
  Retries every outstanding worker-local credential removal, oldest attempt first.

  Returns `{:ok, summary}`, or `:locked` when another instance is already
  sweeping. Options accept `:adapter`, `:limit`, and any adapter option.
  """
  @spec reconcile(DateTime.t(), keyword()) :: {:ok, summary()} | :locked
  def reconcile(now \\ DateTime.utc_now(), opts \\ []) do
    with_advisory_lock(fn -> reconcile_pending(now, opts) end)
  end

  @doc """
  Ends the personal AI connection service for every non-terminal connection.

  Requests revocation, asks each worker to remove its local credential, and
  schedules deletion of every reference the workers acknowledge. Scope it to one
  account with `account: account_or_id`. Returns `:locked` when a sweep is
  already running.
  """
  @spec terminate_service(keyword()) :: {:ok, summary()} | :locked
  def terminate_service(opts \\ []) do
    now = Keyword.get(opts, :at, DateTime.utc_now()) |> DateTime.truncate(:second)

    with_advisory_lock(fn -> terminate_non_terminal(now, opts) end)
  end

  @doc """
  Requests worker-local credential removal for one account being erased.

  Erasure never waits for a device. Every connection is asked, the outcome is
  summarized for the erasure response, and the control-plane references are
  deleted by the caller's transaction whether or not a worker answered. Nothing
  about the outstanding request is retained, because retaining it would keep
  data about an erased account.
  """
  @spec request_account_credential_removal(Ecto.UUID.t(), keyword()) :: summary()
  def request_account_credential_removal(account_id, opts \\ []) when is_binary(account_id) do
    opts = Keyword.put_new(opts, :timeout_ms, @default_timeout_ms)
    now = Keyword.get(opts, :at, DateTime.utc_now()) |> DateTime.truncate(:second)

    account_id
    |> account_connections()
    |> Enum.map(&revoke_connection(&1, now, opts))
    |> summarize()
  end

  defp reconcile_pending(now, opts) do
    opts = Keyword.put_new(opts, :timeout_ms, @default_timeout_ms)
    batch_limit = Keyword.get(opts, :limit, @default_batch_limit)

    {:ok,
     PersonalAIConnection
     |> where([connection], connection.revocation_state == "requested")
     |> order_by([connection],
       asc_nulls_first: connection.credential_removal_attempted_at,
       asc: connection.id
     )
     |> limit(^batch_limit)
     |> Repo.all()
     |> Enum.map(&PersonalConnections.reconcile_revocation(&1, Keyword.put(opts, :at, now)))
     |> summarize()}
  end

  defp terminate_non_terminal(now, opts) do
    opts = Keyword.put_new(opts, :timeout_ms, @default_timeout_ms)

    {:ok,
     opts
     |> revocable_connections()
     |> Enum.map(&revoke_connection(&1, now, opts))
     |> summarize()}
  end

  defp revoke_connection(connection, now, opts) do
    opts = Keyword.put(opts, :at, now)

    case PersonalConnections.request_revocation(connection.account_id, connection.id, opts) do
      {:ok, updated} -> updated
      {:error, _gone} -> connection
    end
  end

  defp revocable_connections(opts) do
    query =
      from connection in PersonalAIConnection,
        where: connection.revocation_state != "acknowledged",
        order_by: [asc: connection.id]

    case Keyword.fetch(opts, :account) do
      {:ok, %Account{id: account_id}} ->
        Repo.all(scope_to_account(query, account_id))

      {:ok, account_id} when is_binary(account_id) ->
        Repo.all(scope_to_account(query, account_id))

      :error ->
        Repo.all(query)
    end
  end

  defp scope_to_account(query, account_id) do
    where(query, [connection], connection.account_id == ^account_id)
  end

  defp account_connections(account_id) do
    Repo.all(
      from connection in PersonalAIConnection,
        where: connection.account_id == ^account_id,
        order_by: [asc: connection.id]
    )
  end

  # Only counts and typed reasons leave this module. A summary never names a
  # connection, a worker, or a profile.
  defp summarize(connections) do
    {acknowledged, outstanding} =
      Enum.split_with(connections, &(&1.revocation_state == "acknowledged"))

    reasons =
      outstanding
      |> Enum.map(& &1.credential_removal_failure_reason)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.to_existing_atom/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      connections: length(connections),
      acknowledged: length(acknowledged),
      outstanding: length(outstanding),
      outstanding_reasons: reasons
    }
  end

  # The lock is session-scoped, so it must be taken and released on the same
  # checked-out connection.
  defp with_advisory_lock(sweep) do
    Repo.checkout(fn ->
      case Repo.query("SELECT pg_try_advisory_lock($1)", [@advisory_lock_key]) do
        {:ok, %{rows: [[true]]}} ->
          try do
            sweep.()
          after
            Repo.query("SELECT pg_advisory_unlock($1)", [@advisory_lock_key])
          end

        {:ok, _not_acquired} ->
          :locked

        {:error, reason} ->
          Logger.warning(
            "personal connection revocation sweep could not acquire advisory lock: " <>
              inspect(reason)
          )

          :locked
      end
    end)
  end
end
