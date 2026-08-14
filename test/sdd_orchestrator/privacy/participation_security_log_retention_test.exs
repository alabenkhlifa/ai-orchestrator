defmodule SddOrchestrator.Privacy.ParticipationSecurityLogRetentionTest do
  @moduledoc """
  Task 3 proof for AC-03.

  A fixed, minimized `ParticipationSecurityEvent` carries only an allowlisted
  event type, coarse outcome, fixed reason classification when required, UTC
  occurrence time, and a fresh non-secret correlation identifier. No
  credential, email, digest, project or specification content, comment,
  evidence, repository detail, provider payload, secret, or unrelated
  identity can ever reach it. Events are deleted 30 days after their own
  `occurred_at` through `ParticipationSecurityLog`'s retention-capable local
  sink, and the shared runner's lock, restart, and reconciliation behavior
  all keep working alongside it.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Participation.{ProjectInvitation, ProjectParticipant}
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.{ParticipationSecurityEvent, ParticipationSecurityLog, Retention}
  alias SddOrchestrator.Privacy.RetentionPruner

  @day 24 * 60 * 60
  @window 30 * @day

  describe "closed event-type, outcome, and reason vocabulary" do
    test "every approved event type can be emitted with its approved outcome and reason" do
      now = truncated_now()

      assert :ok =
               ParticipationSecurityLog.emit(:invitation_credential_rejected, :rejected,
                 reason: :invalid_or_expired,
                 occurred_at: now
               )

      assert :ok =
               ParticipationSecurityLog.emit(:invitation_acceptance_rejected, :rejected,
                 reason: :invalid_or_expired,
                 occurred_at: now
               )

      for reason <- [:unauthorized, :not_a_participant, :owner_cannot_leave] do
        assert :ok =
                 ParticipationSecurityLog.emit(:revocation_denied, :denied,
                   reason: reason,
                   occurred_at: now
                 )
      end

      assert :ok =
               ParticipationSecurityLog.emit(:revocation_denied, :failed, occurred_at: now)

      assert Repo.aggregate(ParticipationSecurityEvent, :count) == 6
    end

    test "an unlisted event type or outcome is rejected by the function clause, not stored" do
      # Routed through `String.to_atom/1` and `apply/3` so the compiler cannot
      # statically narrow these to a literal outside the closed vocabularies
      # and treat the call as always-invalid at compile time; the rejection
      # this test proves happens at runtime, via `emit/3`'s own guard clause.
      unlisted_event_type = String.to_atom("invitation_enumeration_attempt")
      unlisted_outcome = String.to_atom("blocked")

      assert_raise FunctionClauseError, fn ->
        apply(ParticipationSecurityLog, :emit, [unlisted_event_type, :rejected, []])
      end

      assert_raise FunctionClauseError, fn ->
        apply(ParticipationSecurityLog, :emit, [:revocation_denied, unlisted_outcome, []])
      end

      assert Repo.aggregate(ParticipationSecurityEvent, :count) == 0
    end

    test "an outcome that requires a reason refuses to persist without one" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        ParticipationSecurityLog.emit(:revocation_denied, :denied, [])
      end
    end

    test "a reason not approved for the given outcome refuses to persist" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        ParticipationSecurityLog.emit(:invitation_credential_rejected, :rejected,
          reason: :unauthorized
        )
      end
    end

    test "audit/3 emits only on failure and classifies the coarse outcome from the reason" do
      now = truncated_now()

      assert {:ok, :ignored} =
               ParticipationSecurityLog.audit(
                 {:ok, :ignored},
                 :invitation_credential_rejected,
                 occurred_at: now
               )

      assert Repo.aggregate(ParticipationSecurityEvent, :count) == 0

      assert {:error, :invalid_or_expired} =
               ParticipationSecurityLog.audit(
                 {:error, :invalid_or_expired},
                 :invitation_credential_rejected,
                 occurred_at: now
               )

      assert [stored] = Repo.all(ParticipationSecurityEvent)
      assert stored.event_type == :invitation_credential_rejected
      assert stored.outcome == :rejected
      assert stored.reason == :invalid_or_expired

      assert {:error, :some_unclassified_reason} =
               ParticipationSecurityLog.audit(
                 {:error, :some_unclassified_reason},
                 :revocation_denied,
                 occurred_at: now
               )

      unclassified =
        ParticipationSecurityEvent
        |> Repo.all()
        |> Enum.find(&(&1.event_type == :revocation_denied))

      assert unclassified.outcome == :failed
      assert is_nil(unclassified.reason)
    end
  end

  describe "structurally impossible forbidden content" do
    test "no forbidden field can be smuggled through emit/3's opts" do
      now = truncated_now()

      assert :ok =
               ParticipationSecurityLog.emit(:invitation_credential_rejected, :rejected,
                 reason: :invalid_or_expired,
                 occurred_at: now,
                 email: "attacker@example.com",
                 invitation_credential: "raw-token-value",
                 project_name: "Secret Project",
                 comment: "leaked comment body",
                 repository: "octocat/leaked-repo",
                 provider_payload: %{token: "sk-leak"},
                 secret: "super-secret",
                 account_id: Ecto.UUID.generate()
               )

      assert [stored] = Repo.all(ParticipationSecurityEvent)
      # `Map.from_struct/1` also carries Ecto's own `:__meta__` bookkeeping
      # key; every other key is one of this schema's own declared fields.
      persisted_keys = stored |> Map.from_struct() |> Map.delete(:__meta__) |> Map.keys()

      assert Enum.sort(persisted_keys) ==
               [
                 :correlation_id,
                 :event_type,
                 :id,
                 :inserted_at,
                 :occurred_at,
                 :outcome,
                 :reason
               ]

      refute inspect(stored) =~ "attacker@example.com"
      refute inspect(stored) =~ "raw-token-value"
      refute inspect(stored) =~ "Secret Project"
      refute inspect(stored) =~ "leaked comment"
      refute inspect(stored) =~ "octocat/leaked-repo"
      refute inspect(stored) =~ "sk-leak"
      refute inspect(stored) =~ "super-secret"
    end

    test "a changeset built directly against the schema also drops every unapproved key" do
      now = truncated_now()

      changeset =
        ParticipationSecurityEvent.changeset(%ParticipationSecurityEvent{}, %{
          event_type: :invitation_credential_rejected,
          outcome: :rejected,
          reason: :invalid_or_expired,
          occurred_at: now,
          correlation_id: Ecto.UUID.generate(),
          email: "smuggled@example.com",
          invitation_credential: "smuggled-token",
          project_content: "smuggled content"
        })

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :email)
      refute Map.has_key?(changeset.changes, :invitation_credential)
      refute Map.has_key?(changeset.changes, :project_content)
    end
  end

  describe "fresh non-secret correlation identifiers" do
    test "two events about the same underlying context get different correlation ids" do
      now = truncated_now()
      shared_reason = :invalid_or_expired

      :ok =
        ParticipationSecurityLog.emit(:invitation_credential_rejected, :rejected,
          reason: shared_reason,
          occurred_at: now
        )

      :ok =
        ParticipationSecurityLog.emit(:invitation_credential_rejected, :rejected,
          reason: shared_reason,
          occurred_at: now
        )

      assert [first, second] =
               ParticipationSecurityEvent |> Repo.all() |> Enum.sort_by(& &1.inserted_at)

      assert first.correlation_id != second.correlation_id
      assert {:ok, _} = Ecto.UUID.cast(first.correlation_id)
      assert {:ok, _} = Ecto.UUID.cast(second.correlation_id)
    end

    test "the correlation id is not derived from any identity, project, or invitation value" do
      context = owned_project()
      identity = ParticipationFixtures.invited_identity_fixture()

      :ok =
        ParticipationSecurityLog.emit(:revocation_denied, :denied, reason: :unauthorized)

      [stored] = Repo.all(ParticipationSecurityEvent)

      refute stored.correlation_id == context.project.id
      refute stored.correlation_id == context.account.id
      refute stored.correlation_id == identity.account.id
      refute stored.correlation_id == identity.hosted_identity.id
    end
  end

  describe "30-day security-log retention" do
    test "deletes an event at the 30-day boundary and keeps a day-29 event" do
      now = truncated_now()

      due = event_fixture(occurred_at: DateTime.add(now, -@window, :second))
      just_inside = event_fixture(occurred_at: DateTime.add(now, -@window + 1, :second))

      assert %{expired_participation_security_events: 1} = Retention.prune_all(now)

      refute Repo.get(ParticipationSecurityEvent, due.id)
      assert Repo.get(ParticipationSecurityEvent, just_inside.id)
    end

    test "prune/1 reports the real deleted count directly" do
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      event_fixture(occurred_at: cutoff)
      event_fixture(occurred_at: cutoff)
      event_fixture(occurred_at: DateTime.add(now, -@window + 1, :second))

      assert ParticipationSecurityLog.prune(cutoff) == 2
      assert Repo.aggregate(ParticipationSecurityEvent, :count) == 1
    end

    test "re-running the prune is idempotent" do
      now = truncated_now()
      event_fixture(occurred_at: DateTime.add(now, -@window, :second))

      assert %{expired_participation_security_events: 1} = Retention.prune_all(now)
      assert %{expired_participation_security_events: 0} = Retention.prune_all(now)
    end

    test "an event not yet due in one pass is reconciled once it crosses the boundary" do
      now = truncated_now()

      due_soon = event_fixture(occurred_at: DateTime.add(now, -@window + 60, :second))

      assert %{expired_participation_security_events: 0} = Retention.prune_all(now)
      assert Repo.get(ParticipationSecurityEvent, due_soon.id)

      later = DateTime.add(now, 120, :second)
      assert %{expired_participation_security_events: 1} = Retention.prune_all(later)
      refute Repo.get(ParticipationSecurityEvent, due_soon.id)
    end
  end

  describe "no participation-state mutation" do
    test "emitting and pruning security events leaves an active participant, invitation, and profile untouched" do
      now = truncated_now()
      context = owned_project()
      active = active_participant(context.project)

      invitation =
        ParticipationFixtures.invited_identity_fixture()
        |> then(fn identity ->
          {:ok, %{invitation: invitation}} =
            SddOrchestrator.Participation.Invitations.create(
              context.project,
              context.account.id,
              identity.external_identity.display_identifier
            )

          invitation
        end)

      due = event_fixture(occurred_at: DateTime.add(now, -@window, :second))

      assert %{expired_participation_security_events: 1} = Retention.prune_all(now)
      refute Repo.get(ParticipationSecurityEvent, due.id)

      kept_participant = Repo.get!(ProjectParticipant, active.participant.id)
      assert kept_participant.state == "active"
      assert kept_participant.hosted_identity_id == active.identity.hosted_identity.id

      kept_invitation = Repo.get!(ProjectInvitation, invitation.id)
      assert kept_invitation.status == "pending"

      assert Repo.get!(Account, context.account.id)
    end
  end

  describe "locked retention workflow" do
    test "the advisory lock prevents concurrent security-log cleanup" do
      now = truncated_now()
      due = event_fixture(occurred_at: DateTime.add(now, -@window, :second))

      {:ok, connection} = Postgrex.start_link(postgrex_options())
      Process.unlink(connection)
      on_exit(fn -> if Process.alive?(connection), do: GenServer.stop(connection) end)

      assert %Postgrex.Result{rows: [[:void]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_advisory_lock($1)",
                 [RetentionPruner.advisory_lock_key()]
               )

      assert :locked = RetentionPruner.prune_with_lock(now)
      assert Repo.get(ParticipationSecurityEvent, due.id)

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_advisory_unlock($1)",
                 [RetentionPruner.advisory_lock_key()]
               )

      assert %{expired_participation_security_events: 1} = RetentionPruner.prune_with_lock(now)
      refute Repo.get(ParticipationSecurityEvent, due.id)
    end

    test "the supervisor restarts and a reconciliation pass still clears the event" do
      now = truncated_now()
      due = event_fixture(occurred_at: DateTime.add(now, -@window, :second))

      first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})
      Process.exit(first_pid, :kill)

      assert_eventually(fn ->
        case Process.whereis(RetentionPruner) do
          pid when is_pid(pid) -> pid != first_pid
          _not_restarted -> false
        end
      end)

      assert %{expired_participation_security_events: 1} = RetentionPruner.prune_with_lock(now)
      refute Repo.get(ParticipationSecurityEvent, due.id)
    end

    test "interruption mid-pass is retried and reconciled by a later run" do
      now = truncated_now()
      due_one = event_fixture(occurred_at: DateTime.add(now, -@window, :second))
      due_two = event_fixture(occurred_at: DateTime.add(now, -@window, :second))

      # Simulate an interrupted pass: only a partial delete happened, as if the
      # process had died between these two due rows.
      Repo.delete!(due_one)
      refute Repo.get(ParticipationSecurityEvent, due_one.id)
      assert Repo.get(ParticipationSecurityEvent, due_two.id)

      assert %{expired_participation_security_events: 1} = RetentionPruner.prune_with_lock(now)
      refute Repo.get(ParticipationSecurityEvent, due_two.id)

      assert %{expired_participation_security_events: 0} = RetentionPruner.prune_with_lock(now)
    end
  end

  defp owned_project do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    result
  end

  defp active_participant(project) do
    identity = ParticipationFixtures.invited_identity_fixture()
    participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Participant")
    })

    %{identity: identity, participant: participant}
  end

  defp event_fixture(attrs) do
    attrs = Map.new(attrs)

    defaults = %{
      event_type: :invitation_credential_rejected,
      outcome: :rejected,
      reason: :invalid_or_expired,
      occurred_at: truncated_now(),
      correlation_id: Ecto.UUID.generate()
    }

    %ParticipationSecurityEvent{}
    |> ParticipationSecurityEvent.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp assert_eventually(check, remaining \\ 300)

  defp assert_eventually(check, remaining) when remaining > 0 do
    if check.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(check, remaining - 1)
    end
  end

  defp assert_eventually(_check, 0), do: flunk("condition did not become true")

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
