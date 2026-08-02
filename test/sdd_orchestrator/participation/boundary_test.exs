defmodule SddOrchestrator.Participation.BoundaryTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Boundary, Capabilities, Revocations}
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

  @member_keys [:account_id, :display_name, :hosted_identity_id, :presentation_state, :role]

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

  describe "current membership" do
    test "returns the owner and each active participant as a minimum result" do
      %{project: project, account: owner_account, identity: identity} = joined()

      assert {:ok, owner} = Boundary.owner(project.id)
      assert owner.role == :owner
      assert owner.account_id == owner_account.id
      assert owner.display_name =~ "Owner"
      assert owner.presentation_state == :present

      assert [participant] = Boundary.current_participants(project.id)
      assert participant.role == :participant
      assert participant.account_id == identity.account.id
      assert participant.hosted_identity_id == identity.hosted_identity.id
      assert participant.display_name == "Member Label"
      assert participant.presentation_state == :present

      assert [first, second] = Boundary.current_members(project.id)
      assert first.role == :owner
      assert second.role == :participant
    end

    test "never exposes an email address or any other field" do
      %{project: project, identity: identity} = joined()

      for member <- Boundary.current_members(project.id) do
        assert Enum.sort(Map.keys(member)) == @member_keys
        refute member.display_name =~ "@"

        for value <- Map.values(member) do
          refute is_binary(value) and String.contains?(value, "@")
        end
      end

      assert {:ok, resolved} =
               Boundary.current_member(project.id, %{
                 account_id: identity.account.id,
                 hosted_identity_id: identity.hosted_identity.id
               })

      assert Enum.sort(Map.keys(resolved)) == @member_keys
      refute Map.has_key?(resolved, :email)
    end

    test "keeps an active participant current and routable when presentation is absent" do
      %{project: project, identity: identity} = joined()

      project.id
      |> Participation.member_profile(identity.account.id)
      |> Repo.delete!()

      actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      assert [participant] = Boundary.current_participants(project.id)
      assert participant.role == :participant
      assert participant.account_id == identity.account.id
      assert participant.hosted_identity_id == identity.hosted_identity.id
      assert participant.presentation_state == :absent
      assert participant.display_name == "Project participant"
      refute participant.display_name =~ "@"
      refute participant.display_name == identity.external_identity.display_identifier

      assert {:ok, ^participant} = Boundary.current_member(project.id, actor)
      assert Boundary.authorized?(project, actor, :read_project)
      assert [_, ^participant] = Boundary.current_members(project.id)
    end

    test "keeps the immutable owner resolvable when presentation is absent" do
      %{project: project, account: owner_account} = joined()

      project.id
      |> Participation.owner_profile()
      |> Repo.delete!()

      assert {:ok, owner} = Boundary.owner(project.id)
      assert owner.role == :owner
      assert owner.account_id == owner_account.id
      assert owner.presentation_state == :absent
      assert owner.display_name == Participation.default_owner_display_name()
      refute owner.display_name =~ "@"

      assert {:ok, ^owner} =
               Boundary.current_member(project.id, %{account_id: owner_account.id})
    end

    test "denies a stale, absent, or cross-project identity with one result" do
      %{project: project, identity: identity} = joined()
      %{project: other_project} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      assert {:error, :not_a_member} =
               Boundary.current_member(project.id, %{
                 account_id: outsider.account.id,
                 hosted_identity_id: outsider.hosted_identity.id
               })

      assert {:error, :not_a_member} = Boundary.current_member(project.id, %{})
      assert {:error, :not_a_member} = Boundary.current_member(other_project.id, actor)
      assert {:error, :not_a_member} = Boundary.current_member(Ecto.UUID.generate(), actor)

      assert Boundary.current_participants(other_project.id) |> Enum.map(& &1.account_id) != [
               identity.account.id
             ]
    end

    test "reads current state directly, with no cache to invalidate" do
      %{project: project, account: owner_account, identity: identity} = joined()

      actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      assert {:ok, _member} = Boundary.current_member(project.id, actor)
      assert Boundary.authorized?(project, actor, :read_project)
      assert Boundary.capabilities(project, actor) == Capabilities.content_capabilities()

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert {:error, :not_a_member} = Boundary.current_member(project.id, actor)
      refute Boundary.authorized?(project, actor, :read_project)
      assert Boundary.capabilities(project, actor) == []
      assert Boundary.current_participants(project.id) == []
    end

    test "a participant who left is no longer current" do
      %{project: project, identity: identity} = joined()

      actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      {:ok, _left} = Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      assert {:error, :not_a_member} = Boundary.current_member(project.id, actor)
      assert Boundary.current_participants(project.id) == []
      assert {:ok, _owner} = Boundary.owner(project.id)
    end

    test "reading changes no participation state" do
      %{project: project, identity: identity} = joined()

      actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      before_participant =
        Participation.active_participant(project.id, identity.hosted_identity.id)

      Boundary.current_members(project.id)
      Boundary.current_member(project.id, actor)
      Boundary.authorized?(project, actor, :comment)
      Boundary.owner(project.id)

      after_participant =
        Participation.active_participant(project.id, identity.hosted_identity.id)

      assert after_participant.id == before_participant.id
      assert after_participant.state == "active"
      assert after_participant.updated_at == before_participant.updated_at
    end
  end

  describe "revocation producer contract" do
    test "a consumer claims, applies, and acknowledges one versioned handoff" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert [claimed] = Boundary.claim_revocations(project_id: project.id)
      assert claimed.id == revocation.id
      assert claimed.contract_version == Boundary.contract_version()
      assert claimed.project_id == project.id
      assert claimed.former_hosted_identity_id == identity.hosted_identity.id
      assert claimed.owner_account_id == owner_account.id
      assert claimed.last_display_name == "Member Label"
      assert claimed.reason == "removed"

      # A consumer that fails before acknowledging sees the same handoff again.
      assert [again] = Boundary.pending_revocations(project_id: project.id)
      assert again.id == revocation.id

      assert {:ok, acknowledged} = Boundary.acknowledge_revocation(revocation.id, "slice-07")
      assert acknowledged.consumer_ref == "slice-07"
      assert Boundary.pending_revocations(project_id: project.id) == []

      assert {:ok, repeated} = Boundary.acknowledge_revocation(revocation.id, "slice-07")
      assert repeated.acknowledged_at == acknowledged.acknowledged_at
    end

    test "the handoff carries the owner fallback and no consumer state" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert {:ok, owner} = Boundary.owner(project.id)
      assert revocation.owner_account_id == owner.account_id

      fields = revocation |> Map.from_struct() |> Map.keys()

      for consumer_owned <- [:feature_id, :run_id, :question_id, :review_id, :assignment] do
        refute consumer_owned in fields
      end
    end
  end

  describe "notification extension" do
    test "a consumer adds its own event types to the shared store" do
      %{project: project, account: owner_account} = joined()

      assert "delivery" in Boundary.notification_namespaces()

      assert {:ok, notification} =
               Boundary.notify(%{
                 account_id: owner_account.id,
                 event_type: "delivery.run_ready_for_review",
                 subject_ref: Ecto.UUID.generate(),
                 event_version: 3,
                 title: "A run is ready for review",
                 body: "One run finished on #{project.name}.",
                 project_label: project.name,
                 link_path: "/projects/#{project.id}"
               })

      assert notification.event_type == "delivery.run_ready_for_review"
      assert [^notification] = Notifications.list(owner_account.id)

      assert {:error, changeset} =
               Boundary.notify(%{
                 account_id: owner_account.id,
                 event_type: "analytics.usage",
                 subject_ref: Ecto.UUID.generate(),
                 title: "t",
                 body: "b",
                 link_path: "/projects"
               })

      assert "is not an approved notification event" in errors_on(changeset).event_type
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

    Map.put(result, :identity, identity)
  end
end
