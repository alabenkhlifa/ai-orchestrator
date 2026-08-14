defmodule SddOrchestrator.Privacy.ParticipationEmailDeliveryRetentionTest do
  @moduledoc """
  Task 1 proof for AC-01.

  A finalized ("sent" or "failed") `ParticipationEmailDelivery` row is deleted
  30 days after its authoritative attempt or completion time (`delivered_at`
  when present, otherwise `attempted_at`). A "pending" row is never selected,
  the delete never cascades into invitation, participant, profile, revocation,
  or account state, and the shared runner's lock, restart, reconciliation, and
  provider-owned identity-lifecycle rule all keep working alongside it.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.Participation.{
    Invitations,
    ParticipationEmailDelivery,
    ParticipationRevocation,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner}

  @day 24 * 60 * 60
  @window 30 * @day

  setup do
    previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

    Application.put_env(
      :sdd_orchestrator,
      :participation_email_delivery,
      ParticipationDeliveryDouble
    )

    ParticipationDeliveryDouble.succeed()

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    :ok
  end

  describe "30-day finalized diagnostic cleanup" do
    test "deletes a sent row at the 30-day boundary and keeps a day-29 sent row" do
      now = truncated_now()

      due =
        delivery_fixture(status: "sent", delivered_at: DateTime.add(now, -@window, :second))

      just_inside =
        delivery_fixture(
          status: "sent",
          delivered_at: DateTime.add(now, -@window + 1, :second)
        )

      assert %{expired_participation_email_delivery_diagnostics: 1} = Retention.prune_all(now)

      refute Repo.get(ParticipationEmailDelivery, due.id)
      assert Repo.get(ParticipationEmailDelivery, just_inside.id)
    end

    test "deletes a failed row at the 30-day boundary using attempted_at and keeps a day-29 failed row" do
      now = truncated_now()

      due =
        delivery_fixture(
          status: "failed",
          attempted_at: DateTime.add(now, -@window, :second),
          delivered_at: nil
        )

      just_inside =
        delivery_fixture(
          status: "failed",
          attempted_at: DateTime.add(now, -@window + 1, :second),
          delivered_at: nil
        )

      assert %{expired_participation_email_delivery_diagnostics: 1} = Retention.prune_all(now)

      refute Repo.get(ParticipationEmailDelivery, due.id)
      assert Repo.get(ParticipationEmailDelivery, just_inside.id)
    end

    test "never selects a pending row regardless of age" do
      now = truncated_now()

      pending =
        delivery_fixture(
          status: "pending",
          attempted_at: DateTime.add(now, -@window - @day, :second),
          delivered_at: nil
        )

      assert %{expired_participation_email_delivery_diagnostics: 0} = Retention.prune_all(now)
      assert Repo.get(ParticipationEmailDelivery, pending.id)
    end

    test "uses delivered_at as authoritative over attempted_at when a sent row carries both" do
      now = truncated_now()

      # attempted_at alone is well past the window, but delivered_at (the
      # authoritative completion time for a sent row) is still inside it.
      survives =
        delivery_fixture(
          status: "sent",
          attempted_at: DateTime.add(now, -@window - @day, :second),
          delivered_at: DateTime.add(now, -@window + 1, :second)
        )

      assert %{expired_participation_email_delivery_diagnostics: 0} = Retention.prune_all(now)
      assert Repo.get(ParticipationEmailDelivery, survives.id)

      # Once delivered_at itself crosses the boundary, the row becomes due.
      Repo.update_all(
        from(d in ParticipationEmailDelivery, where: d.id == ^survives.id),
        set: [delivered_at: DateTime.add(now, -@window, :second)]
      )

      assert %{expired_participation_email_delivery_diagnostics: 1} = Retention.prune_all(now)
      refute Repo.get(ParticipationEmailDelivery, survives.id)
    end

    test "falls back to attempted_at for a finalized row recorded with no delivered_at" do
      now = truncated_now()

      due =
        delivery_fixture(
          status: "failed",
          attempted_at: DateTime.add(now, -@window, :second),
          delivered_at: nil
        )

      assert %{expired_participation_email_delivery_diagnostics: 1} = Retention.prune_all(now)
      refute Repo.get(ParticipationEmailDelivery, due.id)
    end

    test "re-running the prune is idempotent" do
      now = truncated_now()

      delivery_fixture(status: "sent", delivered_at: DateTime.add(now, -@window, :second))

      delivery_fixture(
        status: "failed",
        attempted_at: DateTime.add(now, -@window, :second),
        delivered_at: nil
      )

      assert %{expired_participation_email_delivery_diagnostics: 2} = Retention.prune_all(now)
      assert %{expired_participation_email_delivery_diagnostics: 0} = Retention.prune_all(now)
    end

    test "a row not yet due in one pass is reconciled once it crosses the boundary" do
      now = truncated_now()

      due_soon =
        delivery_fixture(status: "sent", delivered_at: DateTime.add(now, -@window + 60, :second))

      assert %{expired_participation_email_delivery_diagnostics: 0} = Retention.prune_all(now)
      assert Repo.get(ParticipationEmailDelivery, due_soon.id)

      later = DateTime.add(now, 120, :second)
      assert %{expired_participation_email_delivery_diagnostics: 1} = Retention.prune_all(later)
      refute Repo.get(ParticipationEmailDelivery, due_soon.id)
    end
  end

  describe "unchanged participation state" do
    test "deleting due diagnostics referencing an invitation and a revocation touches neither them nor the participant, profile, or account" do
      now = truncated_now()
      context = owned_project()

      {:ok, %{invitation: invitation}} =
        Invitations.create(context.project, context.account.id, unique_address())

      active = active_participant(context.project)

      {:ok, %{participant: departed, revocation: revocation}} =
        Revocations.leave(
          context.project,
          active.identity.account.id,
          active.identity.hosted_identity.id,
          now
        )

      profile =
        Repo.get_by!(ProjectMemberProfile,
          project_id: context.project.id,
          account_id: context.account.id
        )

      invitation_diagnostic =
        delivery_fixture(
          event_type: "invitation_canceled",
          subject_ref: invitation.id,
          status: "sent",
          delivered_at: DateTime.add(now, -@window, :second)
        )

      revocation_diagnostic =
        delivery_fixture(
          event_type: "participant_removed",
          subject_ref: revocation.id,
          status: "failed",
          attempted_at: DateTime.add(now, -@window, :second),
          delivered_at: nil
        )

      assert %{expired_participation_email_delivery_diagnostics: 2} = Retention.prune_all(now)

      refute Repo.get(ParticipationEmailDelivery, invitation_diagnostic.id)
      refute Repo.get(ParticipationEmailDelivery, revocation_diagnostic.id)

      kept_invitation = Repo.get!(ProjectInvitation, invitation.id)
      assert kept_invitation.id == invitation.id
      assert kept_invitation.status == invitation.status

      kept_participant = Repo.get!(ProjectParticipant, departed.id)
      assert kept_participant.state == "departed"
      assert kept_participant.hosted_identity_id == departed.hosted_identity_id

      kept_profile = Repo.get!(ProjectMemberProfile, profile.id)
      assert kept_profile.display_name == profile.display_name

      kept_revocation = Repo.get!(ParticipationRevocation, revocation.id)
      assert kept_revocation.former_hosted_identity_id == revocation.former_hosted_identity_id
      assert kept_revocation.former_account_id == revocation.former_account_id

      assert Repo.get!(Account, context.account.id)
      assert Repo.get!(Account, active.identity.account.id)
    end
  end

  describe "locked retention workflow" do
    test "the advisory lock prevents concurrent diagnostic cleanup" do
      now = truncated_now()

      due = delivery_fixture(status: "sent", delivered_at: DateTime.add(now, -@window, :second))

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
      assert Repo.get(ParticipationEmailDelivery, due.id)

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_advisory_unlock($1)",
                 [RetentionPruner.advisory_lock_key()]
               )

      assert %{expired_participation_email_delivery_diagnostics: 1} =
               RetentionPruner.prune_with_lock(now)

      refute Repo.get(ParticipationEmailDelivery, due.id)
    end

    test "the supervisor restarts and a reconciliation pass still clears the diagnostic" do
      now = truncated_now()

      due = delivery_fixture(status: "sent", delivered_at: DateTime.add(now, -@window, :second))

      first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})
      Process.exit(first_pid, :kill)

      assert_eventually(fn ->
        case Process.whereis(RetentionPruner) do
          pid when is_pid(pid) -> pid != first_pid
          _not_restarted -> false
        end
      end)

      assert %{expired_participation_email_delivery_diagnostics: 1} =
               RetentionPruner.prune_with_lock(now)

      refute Repo.get(ParticipationEmailDelivery, due.id)
    end
  end

  describe "identity-lifecycle compatibility" do
    test "the provider-owned revocation-link rule keeps running and touches only its own fields" do
      now = truncated_now()
      context = owned_project()
      active = active_participant(context.project)

      {:ok, %{revocation: revocation}} =
        Revocations.leave(
          context.project,
          active.identity.account.id,
          active.identity.hosted_identity.id,
          DateTime.add(now, -@window, :second)
        )

      diagnostic =
        delivery_fixture(
          event_type: "participant_removed",
          subject_ref: revocation.id,
          status: "sent",
          delivered_at: DateTime.add(now, -@window, :second)
        )

      results = Retention.prune_all(now)

      assert %{
               participation_revocation_links: 1,
               expired_participation_email_delivery_diagnostics: 1
             } = results

      refute Repo.get(ParticipationEmailDelivery, diagnostic.id)

      released = Repo.get!(ParticipationRevocation, revocation.id)
      assert is_nil(released.former_hosted_identity_id)
      assert is_nil(released.former_account_id)
      assert released.id == revocation.id
      assert released.project_id == context.project.id
      assert released.project_participant_id == revocation.project_participant_id
      assert released.owner_account_id == revocation.owner_account_id
      assert released.reason == revocation.reason
      assert released.occurred_at == revocation.occurred_at
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

  defp delivery_fixture(attrs) do
    attrs = Map.new(attrs)
    base_time = Map.get(attrs, :attempted_at, truncated_now())

    defaults = %{
      event_type: "invitation",
      subject_ref: Ecto.UUID.generate(),
      event_version: 1,
      recipient_address: unique_address(),
      status: "sent",
      attempted_at: base_time,
      delivered_at: base_time
    }

    %ParticipationEmailDelivery{}
    |> ParticipationEmailDelivery.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp unique_address, do: "diagnostic-#{System.unique_integer([:positive])}@example.com"

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
