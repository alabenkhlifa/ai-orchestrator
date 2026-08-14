defmodule SddOrchestrator.Privacy.ParticipationSecurityLog do
  @moduledoc """
  Fixed, minimized participation operational-security events with a
  retention-capable local sink (specs/27 Task 3, AC-03).

  Every event carries only an allowlisted event type, UTC occurrence time,
  coarse outcome, a fixed reason classification when the outcome requires
  one, and a fresh non-secret correlation identifier — the same closed shape
  `SddOrchestrator.AIRuntime.SecurityLog` uses for the AI-runtime boundary.
  `emit/3` accepts only these closed atoms and a keyword list this module
  reads exactly two keys from (`:reason`, `:occurred_at`); it never accepts
  an arbitrary map, so an invitation credential, email or digest, project or
  specification content, comment, evidence, repository detail, provider
  payload, secret, or unrelated identity can never reach a stored event —
  there is no field, argument, or code path that would carry one through.

  Unlike `AIRuntime.SecurityLog`, whose moduledoc documents that "deployment
  logging infrastructure applies the approved 30-day expiry" as pure
  release-gate evidence with no local deletion capability at all, this
  module also persists each event through
  `SddOrchestrator.Privacy.ParticipationSecurityEvent`, giving
  `SddOrchestrator.Privacy.Retention` a genuinely callable local deletion
  boundary via `prune/1`. This is design.md's "Retention-Capable Structured
  Security Sink" decision: a documented 30-day policy without a callable
  deletion boundary cannot provide deterministic local lifecycle proof.
  Production sink configuration and live enforced expiry remain release-gate
  evidence (specs/27 tasks.md, "Release gates"); this module provides
  deterministic local proof only, exercised directly by `mix test` with no
  live log aggregator or external infrastructure involved.

  The correlation identifier is freshly generated for every event
  (`Ecto.UUID.generate/0`) and is never derived from an account, identity,
  email, project, repository, invitation, participant, notification, device,
  or network value, so it cannot be used to build a stable profile of any of
  those and two events about the same underlying context always get
  different identifiers.
  """

  import Ecto.Query

  require Logger

  alias SddOrchestrator.Privacy.ParticipationSecurityEvent
  alias SddOrchestrator.Repo

  @event_types ParticipationSecurityEvent.event_types()
  @outcomes ParticipationSecurityEvent.outcomes()

  # Reason atoms are unique across the whole vocabulary (each approved reason
  # belongs to exactly one outcome), so classifying a raw `{:error, reason}`
  # result needs no separate per-event-type table.
  @rejected_reasons ParticipationSecurityEvent.reasons(:rejected)
  @denied_reasons ParticipationSecurityEvent.reasons(:denied)

  @doc """
  Records one fixed, minimized participation security event.

  `event_type` and `outcome` must be members of this module's own closed
  vocabularies (`event_types/0`, `outcomes/0`); any other atom fails the
  function clause rather than being logged or stored. `opts` supplies
  `:reason` (required only when `outcome`'s approved-reason list is
  non-empty; see `SddOrchestrator.Privacy.ParticipationSecurityEvent.reasons/1`)
  and an optional `:occurred_at` (defaults to now). Any other key in `opts`
  is never read and so never reaches the event.
  """
  @spec emit(atom(), atom(), keyword()) :: :ok
  def emit(event_type, outcome, opts \\ [])
      when event_type in @event_types and outcome in @outcomes do
    attrs = %{
      event_type: event_type,
      outcome: outcome,
      reason: Keyword.get(opts, :reason),
      occurred_at: occurred_at(opts),
      correlation_id: Ecto.UUID.generate()
    }

    entry =
      %ParticipationSecurityEvent{}
      |> ParticipationSecurityEvent.changeset(attrs)
      |> Repo.insert!()

    Logger.warning(
      "[participation_security] event_type=#{entry.event_type} outcome=#{entry.outcome} " <>
        "reason=#{entry.reason || "none"} correlation_id=#{entry.correlation_id}"
    )

    :ok
  end

  @doc """
  Records one minimized failure event for a participation security-relevant
  operation and returns `result` unchanged.

  Only a non-success emits: `:ok` and any `{:ok, _}` tuple are silent,
  because a completed operation is not itself security-relevant evidence.
  `result` should be `{:error, reason}` where `reason` is one of this
  module's own approved reason atoms for `event_type`'s outcome; any other
  reason is classified `:failed` (no reason recorded) without ever being
  inspected, matched, or interpolated into the event.
  """
  @spec audit(term(), atom(), keyword()) :: term()
  def audit(result, event_type, opts \\ []) when event_type in @event_types do
    unless success?(result) do
      {outcome, reason} = classify(result)
      emit(event_type, outcome, Keyword.put(opts, :reason, reason))
    end

    result
  end

  @doc "The fixed participation security event types."
  @spec event_types() :: [atom()]
  def event_types, do: @event_types

  @doc "The closed, coarse outcome vocabulary."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc """
  Deletes every participation security event at or before `cutoff` and
  returns the deleted row count.

  This is the retention-capable sink's deletion boundary
  `SddOrchestrator.Privacy.Retention` calls. The delete only ever touches
  `participation_security_events`; it never reads or changes any invitation,
  participant, profile, revocation, or account row.
  """
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(cutoff) do
    {count, _} =
      Repo.delete_all(
        from event in ParticipationSecurityEvent, where: event.occurred_at <= ^cutoff
      )

    count
  end

  defp success?(:ok), do: true

  defp success?(result)
       when is_tuple(result) and tuple_size(result) > 0 and elem(result, 0) == :ok,
       do: true

  defp success?(_result), do: false

  defp classify({:error, reason}) when reason in @rejected_reasons, do: {:rejected, reason}
  defp classify({:error, reason}) when reason in @denied_reasons, do: {:denied, reason}
  defp classify(_result), do: {:failed, nil}

  defp occurred_at(opts) do
    case Keyword.get(opts, :occurred_at) do
      %DateTime{} = occurred_at -> occurred_at
      _missing_or_invalid -> DateTime.utc_now()
    end
    |> DateTime.truncate(:second)
  end
end
