defmodule SddOrchestrator.Privacy.ParticipationAccessControlsTest do
  @moduledoc """
  Proof for specs/26 Task 2 (AC-02): participation access returns only the
  approved project-scoped owner or participant view, or the minimized
  operations metadata view, and every stale, removed, departed, absent, or
  cross-project identity is denied identically without disclosing content or
  identity existence.

  The owner and participant reads are proved by exercising the already-
  approved, already-applied Slice 08 surfaces —
  `SddOrchestrator.Participation.Boundary` (the published
  `capability:project-participation-boundary` contract) and
  `SddOrchestrator.Participation.members/3` — at the privacy-specification
  level, mirroring how specs/18 Task 2 proved its AC-02 over the
  already-approved `ParticipantGuard` instead of rebuilding it. This does not
  duplicate Slice 08's own exhaustive coverage (`boundary_test.exs`,
  `members_test.exs`); it proves the same contract holds from this
  specification's own vantage point, including that authorization runs
  before any optional profile lookup (design.md's "Authorization Before
  Presentation").

  The minimized operations metadata view
  (`SddOrchestrator.Privacy.ParticipationOperationsAccess`) is genuinely new:
  no such view existed anywhere in the codebase before this task. Its field
  shape is bounded by the Task 1 `ParticipationProcessingInventory`
  `:minimized_operations` classification and further narrowed to exclude
  every email address and credential-digest field the inventory happens to
  also classify `:minimized_operations` — see that module's moduledoc.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Boundary, Invitations, Revocations}
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.ParticipationOperationsAccess

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

  describe "AC-02 owner and participant project-scoped reads" do
    test "the owner sees membership-management data, including every member's email" do
      %{project: project, account: owner_account} = joined()

      entries = Participation.members(project, :owner, owner_account.id)

      assert length(entries) == 2
      assert Enum.all?(entries, & &1.email)
    end

    test "a participant sees only their own email, never another participant's" do
      %{project: project, identity: identity} = joined()
      other_identity = ParticipationFixtures.invited_identity_fixture()
      ParticipationFixtures.participant_fixture(project, other_identity.hosted_identity)

      ParticipationFixtures.member_profile_fixture(project, other_identity.account, %{
        role: "participant",
        display_name: "Other Member"
      })

      entries = Participation.members(project, :participant, identity.account.id)

      own = Enum.find(entries, &(&1.account_id == identity.account.id))
      other = Enum.find(entries, &(&1.account_id == other_identity.account.id))

      assert own.email
      refute other.email
    end

    test "the owner and the participant each resolve their own current-member entry with no email field" do
      %{project: project, owner_actor: owner_actor, participant_actor: participant_actor} =
        joined()

      assert {:ok, owner_member} = Boundary.current_member(project.id, owner_actor)
      assert {:ok, participant_member} = Boundary.current_member(project.id, participant_actor)

      assert owner_member.role == :owner
      assert participant_member.role == :participant
      refute Map.has_key?(owner_member, :email)
      refute Map.has_key?(participant_member, :email)
    end
  end

  describe "AC-02 stale, removed, departed, absent, and cross-project denial is uniform and account-neutral" do
    test "an absent, stale, and cross-project identity all deny identically" do
      %{project: project} = joined()
      %{participant_actor: cross_actor} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      stale_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      absent = Boundary.current_member(project.id, %{})
      stale = Boundary.current_member(project.id, stale_actor)
      cross_project = Boundary.current_member(project.id, cross_actor)
      unknown_project = Boundary.current_member(Ecto.UUID.generate(), stale_actor)

      results = [absent, stale, cross_project, unknown_project]

      assert Enum.uniq(results) == [{:error, :not_a_member}]
    end

    test "a removed participant is denied immediately" do
      %{project: project, account: owner_account, participant_actor: actor, identity: identity} =
        joined()

      assert {:ok, _member} = Boundary.current_member(project.id, actor)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert Boundary.current_member(project.id, actor) == {:error, :not_a_member}
    end

    test "a departed (voluntary leave) participant denies identically to removal" do
      %{project: project, participant_actor: actor, identity: identity} = joined()

      {:ok, _left} =
        Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      assert Boundary.current_member(project.id, actor) == {:error, :not_a_member}
    end
  end

  describe "AC-02 no unauthorized content or profile lookup" do
    test "a denied actor never triggers a project-member-profile read, while an authorized one does" do
      %{project: project, participant_actor: actor} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      denied_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      test_pid = self()
      handler_id = {:participation_profile_probe, make_ref()}

      :telemetry.attach(
        handler_id,
        [:sdd_orchestrator, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          sql = to_string(metadata[:query] || "")
          if String.contains?(sql, "project_member_profiles"), do: send(test_pid, :profile_query)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert Boundary.current_member(project.id, denied_actor) == {:error, :not_a_member}
      refute_received :profile_query

      assert {:ok, _member} = Boundary.current_member(project.id, actor)
      assert_received :profile_query
    end
  end

  describe "AC-02 minimized operations metadata view" do
    test "the view's field set is bounded by the Task 1 minimized-operations classification" do
      classified = ParticipationOperationsAccess.inventory_minimized_operations_fields()

      for field <- ParticipationOperationsAccess.allowed_fields() do
        assert {:participation_email_delivery, field} in classified
      end
    end

    test "the view never surfaces an email, display name, or invitation credential field" do
      forbidden = [:recipient_address, :email_digest, :token_digest, :token_salt, :delivery_email]

      for field <- forbidden do
        refute field in ParticipationOperationsAccess.allowed_fields()
      end
    end

    test "returns only minimized service and security metadata, scoped to one project" do
      %{project: project, account: owner_account} = ParticipationFixtures.hosted_project_fixture()

      %{project: other_project, account: other_owner_account} =
        ParticipationFixtures.hosted_project_fixture()

      {:ok, %{invitation: invitation}} =
        Invitations.create(project, owner_account.id, "invitee@example.com")

      {:ok, _other} =
        Invitations.create(other_project, other_owner_account.id, "someone-else@example.com")

      assert [entry] = ParticipationOperationsAccess.metadata_for_project(project.id)

      assert entry.subject_ref == invitation.id
      assert entry.event_type == "invitation"
      assert entry.status in ["sent", "failed"]

      assert Enum.sort(Map.keys(entry)) ==
               Enum.sort(ParticipationOperationsAccess.allowed_fields())

      refute Map.has_key?(entry, :recipient_address)
      refute Map.has_key?(entry, :display_name)
    end

    test "a departure's delivery diagnostics are scoped through the revocation handoff, not the invitation" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      entries = ParticipationOperationsAccess.metadata_for_project(project.id)
      removal_entry = Enum.find(entries, &(&1.event_type == "participant_removed"))

      assert removal_entry
      assert removal_entry.subject_ref == revocation.id
    end

    test "an unknown or empty project returns an empty list rather than a distinguishing error" do
      assert ParticipationOperationsAccess.metadata_for_project(Ecto.UUID.generate()) == []
      assert ParticipationOperationsAccess.metadata_for_project("not-a-uuid") == []
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
      owner_actor: %{account_id: result.account.id, hosted_identity_id: nil},
      participant_actor: %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }
    })
  end
end
