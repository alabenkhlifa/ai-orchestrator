defmodule SddOrchestrator.Privacy.ParticipationPropagation do
  @moduledoc """
  Propagates one approved participation deletion or anonymization action to
  every configured non-backup destination, and reconciles what has not yet
  been acknowledged (specs/28 Task 2, AC-02, AC-03).

  ## The four fixed destinations

  `SddOrchestrator.Privacy.Rights.anonymize_participation_attribution/3` and
  its verified and project-deletion siblings already declare, in their
  returned `pending_propagation` list, the exact non-backup destinations a
  participation deletion or anonymization action must still reach:
  `:configured_processors`, `:caches`, `:indexes`, and `:exports`. This
  module turns that declarative list into real, dispatched, acknowledgeable
  cleanup state. `propagate/3` issues exactly one request per destination —
  never a different or additional destination — for the given subject and
  action.

  ## Minimum adapter requests, opaque by construction

  Design's "Minimum Adapter Requests" decision: a cleanup mechanism must not
  create another copy of the personal data it removes. `subject_ref` is a
  caller-minted opaque correlation reference for the one approved action,
  never a raw account id, hosted-identity id, participant id, email, or
  display name — see `SddOrchestrator.Privacy.ParticipationCleanupRequest`'s
  moduledoc. Each configured destination owns its own target resolution from
  that opaque reference and reports back only an acknowledgement or a
  normalized failure class through `acknowledge/2` and `fail/3`; this module
  never resolves, stores, or forwards participation content itself.

  ## Idempotent by construction

  A repeat `propagate/3` call for the same `{subject_ref, action}` creates no
  duplicate request: each destination row is inserted under
  `on_conflict: :nothing` against the schema's own
  `(subject_ref, action, destination)` unique index, and the existing row
  (with its already-assigned idempotency key and current state) is returned
  unchanged. The idempotency key itself is a deterministic digest of the
  triple, so a retried external dispatch always carries the same key a
  destination can deduplicate on, even across process restarts.

  ## Reconciliation: retry lock, restart, and recovery

  `reconcile/2` claims every `:pending` or `:retry_pending` request — whether
  freshly issued or left over from an interrupted earlier pass — dispatches
  it through a caller-supplied (or configured) adapter callback, and applies
  `acknowledge/2` or `fail/3` to the result. It runs under a dedicated
  PostgreSQL advisory lock, distinct from every other sweep's key in this
  codebase, mirroring `SddOrchestrator.Privacy.RetentionPruner.prune_with_lock/1`
  and `SddOrchestrator.AIRuntime.PersonalConnectionRevocations.reconcile/2`:
  a concurrent reconciler returns `:locked` rather than duplicating dispatch,
  and an interrupted pass leaves rows in `:pending` or `:retry_pending` for
  the next pass to find and retry — nothing is lost or double-applied.

  ## Access denial independent of cleanup completion

  Design's "Access Denial Independent Of Cleanup Completion" decision: this
  module never reads, writes, or otherwise touches
  `SddOrchestrator.Participation.Boundary`,
  `SddOrchestrator.Participation.member_role/3`, or any other primary
  participation authorization or presentation path. Primary authorization
  and presentation are already closed by the time propagation runs — see
  `SddOrchestrator.Participation.Revocations.leave/4` and
  `SddOrchestrator.Privacy.Rights.anonymize_participation_attribution/3` —
  and stay closed regardless of how many of the four destinations have
  acknowledged.
  """

  import Ecto.Query

  require Logger

  alias SddOrchestrator.Privacy.ParticipationCleanupRequest
  alias SddOrchestrator.Repo

  # A stable, arbitrary key so every instance contends for the same advisory
  # lock. Deliberately distinct from every other sweep's key in this codebase
  # (`RetentionPruner`, `Retention`'s per-sweep keys,
  # `PersonalConnectionRevocations`), so a contended reconciliation pass
  # neither waits on nor silently suppresses any of them.
  @advisory_lock_key 902_774_531

  @default_batch_limit 50

  @typedoc "One reconciliation pass's per-outcome counts."
  @type reconciliation_summary :: %{
          claimed: non_neg_integer(),
          acknowledged: non_neg_integer(),
          retry_pending: non_neg_integer()
        }

  @doc false
  @spec advisory_lock_key() :: pos_integer()
  def advisory_lock_key, do: @advisory_lock_key

  @doc "The fixed, closed set of non-backup cleanup destinations."
  @spec destinations() :: [atom()]
  def destinations, do: ParticipationCleanupRequest.destinations()

  @doc """
  Issues one idempotent cleanup request per configured destination for one
  approved deletion or anonymization action.

  `subject_ref` is a caller-minted opaque UUID correlating this call's
  destination rows; it carries no participation content. Returns the four
  requests in a stable, destination-sorted order. Calling this again for the
  same `subject_ref` and `action` creates no duplicate rows and returns the
  same requests, unchanged, reflecting whatever acknowledgement or retry
  progress has been made since.
  """
  @spec propagate(Ecto.UUID.t(), :delete | :anonymize, keyword()) ::
          {:ok, [ParticipationCleanupRequest.t()]}
  def propagate(subject_ref, action, opts \\ [])
      when is_binary(subject_ref) and action in [:delete, :anonymize] do
    now = Keyword.get(opts, :at, DateTime.utc_now())

    Enum.each(destinations(), &issue_one(subject_ref, action, &1, now))

    {:ok, requests_for(subject_ref, action)}
  end

  @doc """
  Lists every cleanup request issued for one subject and action, ordered to
  match `destinations/0`'s fixed order rather than incidental storage or
  alphabetical order.
  """
  @spec requests_for(Ecto.UUID.t(), :delete | :anonymize) :: [ParticipationCleanupRequest.t()]
  def requests_for(subject_ref, action) when is_binary(subject_ref) do
    order = destinations() |> Enum.with_index() |> Map.new()

    from(request in ParticipationCleanupRequest,
      where: request.subject_ref == ^subject_ref and request.action == ^action
    )
    |> Repo.all()
    |> Enum.sort_by(&Map.fetch!(order, &1.destination))
  end

  @doc """
  Acknowledges one cleanup request: the destination confirmed the cleanup
  action completed. Returns `{:error, :not_found}` for an unknown id.
  """
  @spec acknowledge(Ecto.UUID.t(), keyword()) ::
          {:ok, ParticipationCleanupRequest.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def acknowledge(request_id, opts \\ []) when is_binary(request_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(request_id),
         %ParticipationCleanupRequest{} = request <- Repo.get(ParticipationCleanupRequest, uuid) do
      now = Keyword.get(opts, :at, DateTime.utc_now())

      request
      |> ParticipationCleanupRequest.acknowledge_changeset(%{
        acknowledged_at: now,
        last_attempted_at: now
      })
      |> Repo.update()
    else
      _absent_or_invalid -> {:error, :not_found}
    end
  end

  @doc """
  Transitions one cleanup request to restricted retry-pending state after a
  normalized destination failure. Returns `{:error, :not_found}` for an
  unknown id and `{:error, :already_acknowledged}` for a request that already
  succeeded — a completed request is never re-opened by a late failure
  report.
  """
  @spec fail(Ecto.UUID.t(), atom(), keyword()) ::
          {:ok, ParticipationCleanupRequest.t()}
          | {:error, :not_found | :already_acknowledged | Ecto.Changeset.t()}
  def fail(request_id, failure_reason, opts \\ [])
      when is_binary(request_id) and
             failure_reason in [:timeout, :destination_unavailable, :rejected, :transient_error] do
    with {:ok, uuid} <- Ecto.UUID.cast(request_id),
         %ParticipationCleanupRequest{} = request <- Repo.get(ParticipationCleanupRequest, uuid) do
      case request.state do
        :acknowledged ->
          {:error, :already_acknowledged}

        _incomplete ->
          now = Keyword.get(opts, :at, DateTime.utc_now())

          request
          |> ParticipationCleanupRequest.retry_changeset(%{
            failure_reason: failure_reason,
            last_attempted_at: now
          })
          |> Repo.update()
      end
    else
      _absent_or_invalid -> {:error, :not_found}
    end
  end

  @doc """
  Claims every incomplete request — freshly issued or left over from an
  interrupted earlier pass — and dispatches each through an adapter.

  Accepts `:adapter`, a 1-arity function `(ParticipationCleanupRequest.t() ->
  :ok | {:error, failure_reason})`; defaults to
  `config :sdd_orchestrator, :participation_cleanup_adapter` when configured,
  or a stub that reports every destination as `:destination_unavailable`
  when no real adapter is configured yet — configuring live destination
  adapters is deferred to a later slice (see design.md's Risks). Accepts
  `:limit` (default #{@default_batch_limit}) and `:at`. Returns `:locked`
  when another instance already holds the reconciliation lock, so a
  contended pass dispatches nothing rather than duplicating work.
  """
  @spec reconcile(DateTime.t(), keyword()) :: {:ok, reconciliation_summary()} | :locked
  def reconcile(now \\ DateTime.utc_now(), opts \\ []) do
    with_advisory_lock(fn -> reconcile_claimed(now, opts) end)
  end

  defp issue_one(subject_ref, action, destination, now) do
    attrs = %{
      subject_ref: subject_ref,
      action: action,
      destination: destination,
      idempotency_key:
        ParticipationCleanupRequest.idempotency_key(subject_ref, action, destination),
      requested_at: now
    }

    %ParticipationCleanupRequest{}
    |> ParticipationCleanupRequest.issue_changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:subject_ref, :action, :destination]
    )
  end

  defp reconcile_claimed(now, opts) do
    limit = Keyword.get(opts, :limit, @default_batch_limit)
    adapter = Keyword.get(opts, :adapter, configured_adapter())

    claimed =
      from(request in ParticipationCleanupRequest,
        where: request.state in [:pending, :retry_pending],
        order_by: [asc_nulls_first: request.last_attempted_at, asc: request.id],
        limit: ^limit
      )
      |> Repo.all()

    results = Enum.map(claimed, &dispatch(&1, adapter, now))

    {:ok,
     %{
       claimed: length(claimed),
       acknowledged: Enum.count(results, &(&1 == :acknowledged)),
       retry_pending: Enum.count(results, &(&1 == :retry_pending))
     }}
  end

  defp dispatch(%ParticipationCleanupRequest{} = request, adapter, now) do
    case adapter.(request) do
      :ok ->
        {:ok, acknowledged} =
          request
          |> ParticipationCleanupRequest.acknowledge_changeset(%{
            acknowledged_at: now,
            last_attempted_at: now
          })
          |> Repo.update()

        _ = acknowledged
        :acknowledged

      {:error, failure_reason} ->
        {:ok, retried} =
          request
          |> ParticipationCleanupRequest.retry_changeset(%{
            failure_reason: failure_reason,
            last_attempted_at: now
          })
          |> Repo.update()

        _ = retried
        :retry_pending
    end
  end

  defp configured_adapter do
    Application.get_env(:sdd_orchestrator, :participation_cleanup_adapter, &stub_adapter/1)
  end

  # No live destination adapters are configured for the first release (see
  # design.md's Risks: "A configured destination may never acknowledge
  # cleanup"). Reporting a normalized, retryable failure keeps every claimed
  # request truthfully retry-pending instead of silently fabricating success.
  defp stub_adapter(%ParticipationCleanupRequest{}), do: {:error, :destination_unavailable}

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
            "participation cleanup reconciliation could not acquire advisory lock: " <>
              inspect(reason)
          )

          :locked
      end
    end)
  end
end
