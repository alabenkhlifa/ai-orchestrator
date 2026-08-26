defmodule SddOrchestrator.Privacy.DeliverySecurityLog do
  @moduledoc """
  Fixed, minimized guided-delivery (Slice 07) operational-security events with
  a persisted local sink (specs/19 Task 4).

  `SddOrchestrator.Privacy.DeliveryContentBoundaryAudit` already refuses
  anything but four allowlisted keys, but it writes to `Logger` and nowhere
  else: there is no closed event-type vocabulary (its `event/2` accepts any
  atom), no correlation identifier, and no stored row — so nothing a retention
  rule could ever scan or delete. This module is that missing sink.

  Every event carries only an allowlisted event type, UTC occurrence time,
  coarse outcome, a fixed reason classification when the outcome requires one,
  and a fresh non-secret correlation identifier — the same closed shape
  `SddOrchestrator.Privacy.ParticipationSecurityLog` uses for the
  participation boundary and `SddOrchestrator.AIRuntime.SecurityLog` uses for
  the AI-runtime boundary.

  ## Minimization

  `emit/3` reads `opts` through `Map.take/2` on `allowed_opt_keys/0`
  (`:reason`, `:occurred_at`) — the same allowlist discipline
  `DeliveryContentBoundaryAudit` applies to its own payload — and then builds
  a fixed attribute map. A caller-supplied `:project_id`, `:feature_id`,
  `:run_id`, `:attempt_id`, `:command_id`, `:account_id`, `:worker_id`,
  `:correlation_id`, `:email`, `:token`, `:prompt`, `:question`, or
  `:artifact` is therefore dropped twice over: once by the allowlist, and
  again by `SddOrchestrator.Privacy.DeliverySecurityEvent`'s changeset, which
  declares no field that could hold one. Specification content, comment text,
  a blocking question or its answer, evidence bytes, a preview link, a
  credential, or an email has no field, argument, or code path to reach a
  stored event.

  The correlation identifier is freshly generated for every event
  (`Ecto.UUID.generate/0`) and is never derived from a project, feature, run,
  attempt, command, participant, worker, provider, or account value, so it
  cannot be used to build a stable profile of any of those and two events
  about the same underlying context always get different identifiers. A
  derived value would be a stable pseudonymous identifier and is forbidden;
  that is why `emit/3` does not accept one.

  ## Closed vocabulary, typed refusal

  `event_types/0` covers the five guided-delivery security categories: worker
  command handling, provider/agent adapter interaction, delivery
  authorization, the artifact/evidence boundary, and retention. The reason
  atoms are the refusals those boundaries actually produce today —
  `SddOrchestrator.Privacy.DeliveryContentBoundary`'s
  `:credential_detected` / `:email_detected` / `:raw_event_detected`,
  `SddOrchestrator.Delivery.SecretBoundary`'s `:secret_field_rejected` /
  `:secret_material_rejected`, `SddOrchestrator.Delivery.ParticipantGuard`'s
  `:unauthorized`, and `SddOrchestrator.Delivery.ArtifactStore`'s
  non-enumerable `:not_found`.

  Anything outside those vocabularies is refused with a typed `{:error, _}`
  result rather than raising or being stored: a mis-declared call site must
  never take down a delivery request, and must never quietly widen the trail
  either.

  ## Expiry

  `prune/1` is this sink's deletion boundary, and it is the only one:
  `SddOrchestrator.Privacy.Retention` supplies the 30-day window and the call
  and owns nothing about the statement, exactly as it delegates to
  `SddOrchestrator.Privacy.ParticipationSecurityLog.prune/1` for the
  participation boundary. The delete selects on `occurred_at` alone. It takes
  no project filter, because a row carries no project identifier to filter on
  — that absence is the minimization decision this schema was built around,
  not an omission to repair — and it takes no event-type filter either,
  because all five event types serve one operational-review purpose under one
  window, so a type-aware selector would only let one category outlive it.

  Expiring this log changes nothing authoritative. The statement names
  `delivery_security_events` and no other table: no project authorization or
  access state, no feature or run state, no accepted evidence, and no other
  `delivery_*` row is read, updated, or deleted by it.

  Production sink configuration and live enforced expiry remain release-gate
  evidence; this module provides deterministic local proof only.
  """

  import Ecto.Query

  require Logger

  alias SddOrchestrator.Privacy.DeliverySecurityEvent
  alias SddOrchestrator.Repo

  @event_types DeliverySecurityEvent.event_types()
  @outcomes DeliverySecurityEvent.outcomes()

  # Reason atoms are unique across the whole vocabulary (each approved reason
  # belongs to exactly one outcome), so classifying a raw `{:error, reason}`
  # result needs no separate per-event-type table.
  @rejected_reasons DeliverySecurityEvent.reasons(:rejected)
  @denied_reasons DeliverySecurityEvent.reasons(:denied)

  # Only these keys may be read out of an `emit/3` option list. Anything else —
  # in particular a project, feature, run, attempt, command, participant, or
  # worker identifier, or the content that triggered the refusal — is dropped
  # before an attribute map is ever built.
  @allowed_opt_keys ~w(reason occurred_at)a

  @type refusal ::
          {:error, :unapproved_event_type}
          | {:error, :unapproved_outcome}
          | {:error, :unapproved_reason}

  @doc """
  Records one fixed, minimized guided-delivery security event.

  `event_type` and `outcome` must be members of this module's own closed
  vocabularies (`event_types/0`, `outcomes/0`); any other atom returns a typed
  refusal without storing or logging an event. `opts` supplies `:reason`
  (required only when `outcome`'s approved-reason list is non-empty; see
  `SddOrchestrator.Privacy.DeliverySecurityEvent.reasons/1`) and an optional
  `:occurred_at` (defaults to now). Every other key is dropped by
  `allowed_opt_keys/0` and so never reaches the event.
  """
  @spec emit(atom(), atom(), keyword()) :: :ok | refusal()
  def emit(event_type, outcome, opts \\ [])

  def emit(event_type, outcome, opts)
      when event_type in @event_types and outcome in @outcomes do
    minimized = opts |> Map.new() |> Map.take(@allowed_opt_keys)

    attrs = %{
      event_type: event_type,
      outcome: outcome,
      reason: Map.get(minimized, :reason),
      occurred_at: occurred_at(minimized),
      correlation_id: Ecto.UUID.generate()
    }

    %DeliverySecurityEvent{}
    |> DeliverySecurityEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, entry} -> record(entry)
      {:error, _changeset} -> refuse(:unapproved_reason)
    end
  end

  def emit(event_type, _outcome, _opts) when event_type not in @event_types,
    do: refuse(:unapproved_event_type)

  def emit(_event_type, _outcome, _opts), do: refuse(:unapproved_outcome)

  @doc """
  Records one minimized failure event for a guided-delivery security-relevant
  operation and returns `result` unchanged.

  Only a non-success emits: `:ok` and any `{:ok, _}` tuple are silent, because
  a completed operation is not itself security-relevant evidence. `result`
  should be `{:error, reason}` where `reason` is one of this module's own
  approved reason atoms for `event_type`'s outcome; any other reason is
  classified `:failed` (no reason recorded) without ever being inspected,
  matched, or interpolated into the event.

  `result` is passed through unchanged even when `event_type` is outside the
  closed vocabulary; that call is refused the same way `emit/3` refuses it.
  """
  @spec audit(term(), atom(), keyword()) :: term()
  def audit(result, event_type, opts \\ [])

  def audit(result, event_type, opts) when event_type in @event_types do
    unless success?(result) do
      {outcome, reason} = classify(result)
      emit(event_type, outcome, Keyword.put(opts, :reason, reason))
    end

    result
  end

  def audit(result, _event_type, _opts) do
    refuse(:unapproved_event_type)

    result
  end

  @doc "The fixed guided-delivery security event types."
  @spec event_types() :: [atom()]
  def event_types, do: @event_types

  @doc "The closed, coarse outcome vocabulary."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc "The reason atoms approved for `outcome`; empty when that outcome requires none."
  @spec reasons(atom()) :: [atom()]
  def reasons(outcome), do: DeliverySecurityEvent.reasons(outcome)

  @doc "The complete allowlist of option keys `emit/3` may read from a caller."
  @spec allowed_opt_keys() :: [atom()]
  def allowed_opt_keys, do: @allowed_opt_keys

  @doc """
  Deletes every guided-delivery security event at or before `cutoff` and
  returns the deleted row count.

  This is the retention-capable sink's deletion boundary
  `SddOrchestrator.Privacy.Retention` calls; the window is that module's, the
  statement is this one's. `occurred_at` is the only selector — see this
  module's "Expiry" — and the delete only ever touches
  `delivery_security_events`. It never reads or changes a project, feature,
  run, attempt, command, evidence, artifact, preview, participant, or account
  row.
  """
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(cutoff) do
    {count, _} =
      Repo.delete_all(from event in DeliverySecurityEvent, where: event.occurred_at <= ^cutoff)

    count
  end

  defp record(entry) do
    Logger.warning(
      "[delivery_security] event_type=#{entry.event_type} outcome=#{entry.outcome} " <>
        "reason=#{entry.reason || "none"} correlation_id=#{entry.correlation_id}"
    )

    :ok
  end

  # The refused value itself is never interpolated: a mis-declared call site is
  # named by the class of violation, not by the atom or option it supplied.
  defp refuse(reason) do
    Logger.warning("[delivery_security] refused=#{reason}")

    {:error, reason}
  end

  defp success?(:ok), do: true

  defp success?(result)
       when is_tuple(result) and tuple_size(result) > 0 and elem(result, 0) == :ok,
       do: true

  defp success?(_result), do: false

  defp classify({:error, reason}) when reason in @rejected_reasons, do: {:rejected, reason}
  defp classify({:error, reason}) when reason in @denied_reasons, do: {:denied, reason}
  defp classify(_result), do: {:failed, nil}

  defp occurred_at(minimized) do
    case Map.get(minimized, :occurred_at) do
      %DateTime{} = occurred_at -> occurred_at
      _missing_or_invalid -> DateTime.utc_now()
    end
    |> DateTime.truncate(:second)
  end
end
