defmodule SddOrchestrator.Participation.RevocationsTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Capabilities, ParticipationRevocation, Revocations}
  alias SddOrchestrator.ParticipationFixtures

  describe "remove/4" do
    test "ends authorization and publishes exactly one versioned handoff" do
      %{project: project, account: owner_account, identity: identity, actor: actor} = joined()
      participant = Participation.active_participant(project.id, identity.hosted_identity.id)

      assert {:ok, %{participant: departed, revocation: revocation}} =
               Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert departed.id == participant.id
      assert departed.state == "departed"
      assert departed.departure_reason == "removed"
      assert departed.departed_at

      assert revocation.contract_version == ParticipationRevocation.contract_version()
      assert revocation.project_id == project.id
      assert revocation.project_participant_id == participant.id
      assert revocation.former_hosted_identity_id == identity.hosted_identity.id
      assert revocation.former_account_id == identity.account.id
      assert revocation.owner_account_id == owner_account.id
      assert revocation.last_display_name == "Member Label"
      assert revocation.reason == "removed"
      assert revocation.occurred_at == departed.departed_at
      refute ParticipationRevocation.acknowledged?(revocation)

      # Authorization is gone on the very next decision.
      refute Participation.active_participant(project.id, identity.hosted_identity.id)
      assert Capabilities.capabilities(project, actor) == []

      assert {:error, :unauthorized} =
               Participation.visible_project(
                 project.id,
                 identity.account.id,
                 identity.hosted_identity.id
               )

      assert Repo.aggregate(ParticipationRevocation, :count) == 1
    end

    test "preserves the last accepted label as historical attribution" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, _renamed} =
        Participation.rename_member_profile(
          project,
          identity.account.id,
          identity.hosted_identity.id,
          "Final Label"
        )

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert revocation.last_display_name == "Final Label"

      profile = Participation.member_profile(project.id, identity.account.id)
      assert profile.state == "historical"
      assert profile.display_name == "Final Label"
      assert profile.account_id == identity.account.id
    end

    test "rejects a non-owner, an outsider target, and a repeat" do
      %{project: project, account: owner_account, identity: identity} = joined()
      %{account: other_account} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :unauthorized} =
               Revocations.remove(project, other_account.id, identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Revocations.remove(project, nil, identity.hosted_identity.id)

      assert {:error, :not_a_participant} =
               Revocations.remove(project, owner_account.id, outsider.hosted_identity.id)

      assert {:error, :not_a_participant} = Revocations.remove(project, owner_account.id, nil)

      assert Participation.active_participant(project.id, identity.hosted_identity.id)
      assert Repo.aggregate(ParticipationRevocation, :count) == 0

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert {:error, :not_a_participant} =
               Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert Repo.aggregate(ParticipationRevocation, :count) == 1
    end

    test "produces a distinct handoff for a later departure of a rejoined person" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: first}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      {:ok, %{revocation: second}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert second.id != first.id
      assert second.project_participant_id != first.project_participant_id
      assert Repo.aggregate(ParticipationRevocation, :count) == 2
    end

    test "changes no consumer-owned record" do
      %{project: project, account: owner_account, identity: identity} = joined()

      before_tables = table_counts()

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      after_tables = table_counts()

      # Only participation-owned tables move. Nothing else in the database is
      # touched, so no consumer record can be mutated by a membership action.
      assert Map.drop(after_tables, ["participation_revocations"]) ==
               Map.drop(before_tables, ["participation_revocations"])

      assert after_tables["participation_revocations"] ==
               before_tables["participation_revocations"] + 1
    end
  end

  describe "leave/4" do
    test "a participant ends only their own access and records the same handoff" do
      %{project: project, account: owner_account, identity: identity, actor: actor} = joined()
      other = joined_into(project)

      assert {:ok, %{participant: departed, revocation: revocation}} =
               Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      assert departed.state == "departed"
      assert departed.departure_reason == "left"
      assert revocation.reason == "left"
      assert revocation.owner_account_id == owner_account.id
      assert revocation.last_display_name == "Member Label"

      refute Participation.active_participant(project.id, identity.hosted_identity.id)
      assert Capabilities.capabilities(project, actor) == []

      # Another participant and the owner are unaffected.
      assert Participation.active_participant(project.id, other.hosted_identity.id)
      assert {:ok, owner} = Participation.owner(project)
      assert owner.account_id == owner_account.id
    end

    test "the immutable owner cannot leave their own project" do
      %{project: project, account: owner_account, identity: identity} = joined()

      assert {:error, :owner_cannot_leave} =
               Revocations.leave(project, owner_account.id, nil)

      assert {:error, :owner_cannot_leave} =
               Revocations.leave(project, owner_account.id, identity.hosted_identity.id)

      assert {:ok, owner} = Participation.owner(project)
      assert owner.account_id == owner_account.id
      assert Participation.active_participant(project.id, identity.hosted_identity.id)
      assert Repo.aggregate(ParticipationRevocation, :count) == 0
    end

    test "cannot end another member's participation or repeat itself" do
      %{project: project, identity: identity} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :not_a_participant} =
               Revocations.leave(project, outsider.account.id, outsider.hosted_identity.id)

      assert {:error, :not_a_participant} = Revocations.leave(project, nil, nil)
      assert Participation.active_participant(project.id, identity.hosted_identity.id)

      {:ok, _left} = Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      assert {:error, :not_a_participant} =
               Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      assert Repo.aggregate(ParticipationRevocation, :count) == 1
    end
  end

  describe "claim and acknowledge" do
    test "a handoff stays pending until a consumer acknowledges it" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert [pending] = Revocations.pending()
      assert pending.id == revocation.id

      assert [claimed] = Revocations.claim()
      assert claimed.claimed_at
      refute ParticipationRevocation.acknowledged?(claimed)

      # A consumer that crashed before acknowledging sees the same handoff again.
      assert [again] = Revocations.pending()
      assert again.id == revocation.id

      assert {:ok, acknowledged} = Revocations.acknowledge(revocation.id, "slice-07")
      assert acknowledged.consumer_ref == "slice-07"
      assert ParticipationRevocation.acknowledged?(acknowledged)
      assert Revocations.pending() == []
    end

    test "acknowledging twice keeps the first record" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      {:ok, first} = Revocations.acknowledge(revocation.id, "slice-07")
      {:ok, repeated} = Revocations.acknowledge(revocation.id, "another-consumer")

      assert repeated.acknowledged_at == first.acknowledged_at
      assert repeated.consumer_ref == "slice-07"
    end

    test "an unknown or malformed handoff is not found" do
      assert {:error, :not_found} = Revocations.acknowledge(Ecto.UUID.generate(), "slice-07")
      assert {:error, :not_found} = Revocations.acknowledge("not-an-id", "slice-07")
    end

    test "pending handoffs can be scoped to one project" do
      %{project: project, account: owner_account, identity: identity} = joined()
      other = joined()

      {:ok, _first} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      {:ok, _second} =
        Revocations.remove(
          other.project,
          other.account.id,
          other.identity.hosted_identity.id
        )

      assert length(Revocations.pending()) == 2
      assert [scoped] = Revocations.pending(project_id: project.id)
      assert scoped.project_id == project.id
    end
  end

  defp joined do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
      role: "participant",
      display_name: "Member Label"
    })

    Map.merge(result, %{
      identity: identity,
      actor: %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }
    })
  end

  defp joined_into(project) do
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Other")
    })

    identity
  end

  defp table_counts do
    %{rows: rows} =
      Repo.query!("""
      SELECT relname, n_live_tup FROM pg_stat_user_tables
      """)

    # pg_stat counters are not transactional, so read the real row counts.
    rows
    |> Enum.map(fn [table, _approx] ->
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}")
      {table, count}
    end)
    |> Map.new()
  end
end
