defmodule SddOrchestrator.Privacy.ParticipationRetentionTest do
  @moduledoc """
  Task 20 proof for AC-31.

  Invitation credentials are erased immediately at every terminal transition,
  terminal invitations and departed authorization-to-identity links are removed
  within 30 days, and active participation is retained only while it is active.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Participation.{
    Invitations,
    ParticipationRevocation,
    ProjectInvitation,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner}

  @day 24 * 60 * 60
  @window 30 * @day
  @address "invitee@example.com"

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

  describe "immediate credential erasure at every terminal transition" do
    test "cancellation erases the digest and salt in the same change" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)

      assert invitation.token_digest
      assert invitation.token_salt

      assert {:ok, canceled} = Invitations.cancel(project, account.id, @address)

      assert canceled.status == "canceled"
      assert_credential_erased(canceled.id)
    end

    test "seven-day expiry through the pruner erases the credential and ends usability" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)

      now = truncated_now()
      set_expiry(invitation, DateTime.add(now, -1, :second))

      assert %{expired_invitations: 1} = Retention.prune_all(now)

      expired = Repo.get!(ProjectInvitation, invitation.id)
      assert expired.status == "expired"
      assert expired.terminal_reason == "expired"
      assert_credential_erased(expired.id)
      refute Invitations.usable(invitation.id, now)
    end

    test "acceptance and decline erase the credential through the one terminal funnel" do
      for {status, reason} <- [{"accepted", "accepted"}, {"declined", "declined"}] do
        %{project: project, account: account} = owned_project()

        {:ok, %{invitation: invitation}} =
          Invitations.create(project, account.id, unique_address())

        assert {:ok, terminal} =
                 invitation
                 |> ProjectInvitation.terminal_changeset(status, reason)
                 |> Repo.update()

        assert terminal.status == status
        assert_credential_erased(terminal.id)
      end
    end

    test "the database refuses to let a terminal invitation hold credential material" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)
      {:ok, canceled} = Invitations.cancel(project, account.id, @address)

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(
          from(i in ProjectInvitation, where: i.id == ^canceled.id),
          set: [token_digest: "restored", token_salt: "restored"]
        )
      end

      assert_credential_erased(invitation.id)
    end
  end

  describe "30-day terminal invitation cleanup" do
    test "deletes at the 30-day boundary, keeps a newer terminal row and every pending row" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()

      due = terminal_invitation(project, account, DateTime.add(now, -@window, :second))

      just_inside =
        terminal_invitation(project, account, DateTime.add(now, -@window + 1, :second))

      overdue = terminal_invitation(project, account, DateTime.add(now, -@window - @day, :second))

      {:ok, %{invitation: pending}} = Invitations.create(project, account.id, unique_address())

      assert %{terminal_invitations: 2} = Retention.prune_all(now)

      refute Repo.get(ProjectInvitation, due.id)
      refute Repo.get(ProjectInvitation, overdue.id)
      assert Repo.get(ProjectInvitation, just_inside.id)
      assert Repo.get(ProjectInvitation, pending.id)
    end

    test "a row that survived an earlier pass is reconciled once it crosses the boundary" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()
      terminal_at = DateTime.add(now, -@window + 60, :second)
      invitation = terminal_invitation(project, account, terminal_at)

      assert %{terminal_invitations: 0} = Retention.prune_all(now)
      assert Repo.get(ProjectInvitation, invitation.id)

      later = DateTime.add(now, 120, :second)
      assert %{terminal_invitations: 1} = Retention.prune_all(later)
      refute Repo.get(ProjectInvitation, invitation.id)
    end
  end

  describe "30-day departed authorization-to-identity cleanup" do
    test "erases the departed link at the boundary and preserves active participation" do
      now = truncated_now()
      %{project: project, account: account} = owned_project()

      due = departed_participant(project, account, DateTime.add(now, -@window, :second))

      just_inside =
        departed_participant(project, account, DateTime.add(now, -@window + 1, :second))

      active = active_participant(project)

      assert %{departed_participant_links: 1} = Retention.prune_all(now)

      assert %ProjectParticipant{state: "departed", hosted_identity_id: nil} =
               Repo.get!(ProjectParticipant, due.id)

      assert %ProjectParticipant{hosted_identity_id: still_linked} =
               Repo.get!(ProjectParticipant, just_inside.id)

      assert still_linked

      assert %ProjectParticipant{state: "active", hosted_identity_id: kept} =
               Repo.get!(ProjectParticipant, active.id)

      assert kept == active.hosted_identity_id
    end

    test "keeps the departed row, its departure record, and the Slice 07 handoff" do
      now = truncated_now()
      %{project: project, account: account} = owned_project()
      participant = departed_participant(project, account, DateTime.add(now, -@window, :second))

      revocation = Repo.get_by!(ParticipationRevocation, project_participant_id: participant.id)

      assert %{departed_participant_links: 1} = Retention.prune_all(now)

      kept = Repo.get!(ProjectParticipant, participant.id)
      assert kept.state == "departed"
      assert kept.departure_reason == "removed"
      assert kept.departed_at
      assert is_nil(kept.hosted_identity_id)

      reloaded = Repo.get!(ParticipationRevocation, revocation.id)
      assert reloaded.project_id == project.id
      assert reloaded.project_participant_id == participant.id
    end

    test "an active participant who departs later is erased on the pass that follows" do
      now = truncated_now()
      %{project: project, account: account} = owned_project()
      participant = active_participant(project)

      assert %{departed_participant_links: 0} = Retention.prune_all(now)
      assert Repo.get!(ProjectParticipant, participant.id).hosted_identity_id

      depart(project, account, participant, DateTime.add(now, -@window, :second))

      assert %{departed_participant_links: 1} = Retention.prune_all(now)
      assert is_nil(Repo.get!(ProjectParticipant, participant.id).hosted_identity_id)
    end
  end

  describe "supervised pruning" do
    test "re-running every participation rule is a no-op the second time" do
      now = truncated_now()
      %{project: project, account: account} = owned_project()

      {:ok, %{invitation: pending}} = Invitations.create(project, account.id, unique_address())
      set_expiry(pending, DateTime.add(now, -1, :second))
      terminal_invitation(project, account, DateTime.add(now, -@window - 60, :second))
      departed_participant(project, account, DateTime.add(now, -@window - 60, :second))

      assert %{
               expired_invitations: 1,
               terminal_invitations: 1,
               departed_participant_links: 1
             } = Retention.prune_all(now)

      assert %{
               expired_invitations: 0,
               terminal_invitations: 0,
               departed_participant_links: 0
             } = Retention.prune_all(now)
    end

    test "the advisory lock prevents concurrent participation pruning" do
      now = truncated_now()
      %{project: project, account: account} = owned_project()

      invitation =
        terminal_invitation(project, account, DateTime.add(now, -@window - 60, :second))

      participant = departed_participant(project, account, DateTime.add(now, -@window, :second))

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
      assert Repo.get(ProjectInvitation, invitation.id)
      assert Repo.get!(ProjectParticipant, participant.id).hosted_identity_id

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_advisory_unlock($1)",
                 [RetentionPruner.advisory_lock_key()]
               )

      assert %{terminal_invitations: 1, departed_participant_links: 1} =
               RetentionPruner.prune_with_lock(now)

      refute Repo.get(ProjectInvitation, invitation.id)
      assert is_nil(Repo.get!(ProjectParticipant, participant.id).hosted_identity_id)
    end

    test "the supervisor restarts the pruner and the reconciled prune succeeds" do
      now = truncated_now()
      %{project: project, account: account} = owned_project()

      invitation =
        terminal_invitation(project, account, DateTime.add(now, -@window - 60, :second))

      first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})
      Process.exit(first_pid, :kill)

      assert_eventually(fn ->
        case Process.whereis(RetentionPruner) do
          pid when is_pid(pid) -> pid != first_pid
          _not_restarted -> false
        end
      end)

      assert %{terminal_invitations: 1} = RetentionPruner.prune_with_lock(now)
      refute Repo.get(ProjectInvitation, invitation.id)
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
    invited = ParticipationFixtures.invited_identity_fixture()
    participant = ParticipationFixtures.participant_fixture(project, invited.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, invited.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Participant")
    })

    participant
  end

  defp departed_participant(project, account, departed_at) do
    participant = active_participant(project)
    depart(project, account, participant, departed_at)
    participant
  end

  defp depart(project, account, participant, departed_at) do
    {:ok, _result} =
      Revocations.remove(project, account.id, participant.hosted_identity_id, truncated_now())

    Repo.update_all(
      from(p in ProjectParticipant, where: p.id == ^participant.id),
      set: [departed_at: departed_at]
    )
  end

  defp terminal_invitation(project, account, terminal_at) do
    {:ok, %{invitation: invitation}} =
      Invitations.create(project, account.id, unique_address())

    {:ok, canceled} =
      invitation
      |> ProjectInvitation.terminal_changeset("canceled", "canceled", terminal_at)
      |> Repo.update()

    canceled
  end

  defp assert_credential_erased(invitation_id) do
    stored = Repo.get!(ProjectInvitation, invitation_id)

    assert is_nil(stored.token_digest)
    assert is_nil(stored.token_salt)
    assert stored.terminal_at
    assert stored.terminal_reason
  end

  defp set_expiry(invitation, expires_at) do
    Repo.update_all(
      from(i in ProjectInvitation, where: i.id == ^invitation.id),
      set: [expires_at: expires_at]
    )
  end

  defp unique_address, do: "invitee-#{System.unique_integer([:positive])}@example.com"

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
