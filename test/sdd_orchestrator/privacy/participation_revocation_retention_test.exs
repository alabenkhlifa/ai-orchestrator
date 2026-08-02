defmodule SddOrchestrator.Privacy.ParticipationRevocationRetentionTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    ParticipationRevocation,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner}

  @day 24 * 60 * 60
  @window 30 * @day

  describe "30-day former-identity cleanup" do
    test "clears both links at the boundary and preserves the stable handoff core" do
      now = truncated_now()
      context = owned_project()
      due = depart(context, DateTime.add(now, -@window, :second))
      just_inside = depart(context, DateTime.add(now, -@window + 1, :second))
      active = active_participant(context.project)

      assert %{participation_revocation_links: 1} = Retention.prune_all(now)

      released = Repo.get!(ParticipationRevocation, due.revocation.id)
      assert is_nil(released.former_hosted_identity_id)
      assert is_nil(released.former_account_id)
      assert released.id == due.revocation.id
      assert released.project_id == due.revocation.project_id
      assert released.project_participant_id == due.revocation.project_participant_id
      assert released.owner_account_id == due.revocation.owner_account_id
      assert released.last_display_name == due.revocation.last_display_name
      assert released.reason == due.revocation.reason
      assert released.occurred_at == due.revocation.occurred_at
      assert released.contract_version == due.revocation.contract_version
      assert is_nil(released.acknowledged_at)
      assert is_nil(released.consumer_ref)

      retained = Repo.get!(ParticipationRevocation, just_inside.revocation.id)
      assert retained.former_hosted_identity_id == just_inside.identity.hosted_identity.id
      assert retained.former_account_id == just_inside.identity.account.id

      assert %ProjectParticipant{state: "active", hosted_identity_id: active_identity_id} =
               Repo.get!(ProjectParticipant, active.participant.id)

      assert active_identity_id == active.identity.hosted_identity.id
      assert Participation.active_participant(context.project.id, active_identity_id)
    end

    test "acknowledgement clears immediately and retention leaves its state intact" do
      now = truncated_now()
      context = owned_project()
      %{revocation: revocation} = depart(context, DateTime.add(now, -@window, :second))

      assert {:ok, acknowledged} =
               Revocations.acknowledge(
                 revocation.id,
                 "slice-07",
                 DateTime.add(now, -@day, :second)
               )

      assert is_nil(acknowledged.former_hosted_identity_id)
      assert is_nil(acknowledged.former_account_id)

      assert %{participation_revocation_links: 0} = Retention.prune_all(now)

      retained = Repo.get!(ParticipationRevocation, revocation.id)
      assert retained.acknowledged_at == acknowledged.acknowledged_at
      assert retained.claimed_at == acknowledged.claimed_at
      assert retained.consumer_ref == "slice-07"
      assert retained.id == revocation.id
    end

    test "clears a handoff when either former-identity link remains" do
      now = truncated_now()
      context = owned_project()
      first = depart(context, DateTime.add(now, -@window, :second))
      second = depart(context, DateTime.add(now, -@window, :second))

      Repo.update_all(
        from(r in ParticipationRevocation, where: r.id == ^first.revocation.id),
        set: [former_account_id: nil]
      )

      Repo.update_all(
        from(r in ParticipationRevocation, where: r.id == ^second.revocation.id),
        set: [former_hosted_identity_id: nil]
      )

      assert %{participation_revocation_links: 2} = Retention.prune_all(now)

      for revocation_id <- [first.revocation.id, second.revocation.id] do
        released = Repo.get!(ParticipationRevocation, revocation_id)
        assert is_nil(released.former_hosted_identity_id)
        assert is_nil(released.former_account_id)
      end
    end

    test "a surviving link is reconciled once it crosses the boundary and repeats are no-ops" do
      now = truncated_now()
      context = owned_project()

      %{revocation: revocation} =
        depart(context, DateTime.add(now, -@window + 60, :second))

      assert %{participation_revocation_links: 0} = Retention.prune_all(now)
      assert Repo.get!(ParticipationRevocation, revocation.id).former_account_id

      later = DateTime.add(now, 120, :second)
      assert %{participation_revocation_links: 1} = Retention.prune_all(later)
      assert %{participation_revocation_links: 0} = Retention.prune_all(later)

      released = Repo.get!(ParticipationRevocation, revocation.id)
      assert is_nil(released.former_hosted_identity_id)
      assert is_nil(released.former_account_id)
    end
  end

  describe "locked retention workflow" do
    test "the advisory lock prevents concurrent former-identity cleanup" do
      now = truncated_now()
      context = owned_project()
      %{revocation: revocation} = depart(context, DateTime.add(now, -@window, :second))

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
      assert Repo.get!(ParticipationRevocation, revocation.id).former_account_id

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_advisory_unlock($1)",
                 [RetentionPruner.advisory_lock_key()]
               )

      assert %{participation_revocation_links: 1} = RetentionPruner.prune_with_lock(now)
      assert is_nil(Repo.get!(ParticipationRevocation, revocation.id).former_account_id)
    end

    test "the supervisor restarts and a reconciliation pass still clears the links" do
      now = truncated_now()
      context = owned_project()
      %{revocation: revocation} = depart(context, DateTime.add(now, -@window, :second))

      first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})
      Process.exit(first_pid, :kill)

      assert_eventually(fn ->
        case Process.whereis(RetentionPruner) do
          pid when is_pid(pid) -> pid != first_pid
          _not_restarted -> false
        end
      end)

      assert %{participation_revocation_links: 1} = RetentionPruner.prune_with_lock(now)

      released = Repo.get!(ParticipationRevocation, revocation.id)
      assert is_nil(released.former_hosted_identity_id)
      assert is_nil(released.former_account_id)
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

  defp depart(context, occurred_at) do
    active = active_participant(context.project)

    {:ok, %{participant: participant, revocation: revocation}} =
      Revocations.leave(
        context.project,
        active.identity.account.id,
        active.identity.hosted_identity.id,
        occurred_at
      )

    %{identity: active.identity, participant: participant, revocation: revocation}
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
