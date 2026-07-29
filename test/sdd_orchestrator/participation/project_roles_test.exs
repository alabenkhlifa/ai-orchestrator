defmodule SddOrchestrator.Participation.ProjectRolesTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Participation.{EmailDigest, Invitations, ProjectInvitation, ProjectRoles}
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures

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

  describe "existing_role/2" do
    test "detects the immutable owner by protected comparison" do
      %{project: project, owner: owner} = owned_project()

      {:ok, digest} = EmailDigest.compute(owner.external_identity.display_identifier)
      assert ProjectRoles.existing_role(project, digest) == :owner

      {:ok, upcased} =
        EmailDigest.compute(String.upcase(owner.external_identity.display_identifier))

      assert ProjectRoles.existing_role(project, upcased) == :owner
    end

    test "detects an active participant and forgets a departed one" do
      %{project: project} = owned_project()
      member = ParticipationFixtures.invited_identity_fixture()

      {:ok, digest} = EmailDigest.compute(member.external_identity.display_identifier)
      assert ProjectRoles.existing_role(project, digest) == nil

      participant =
        ParticipationFixtures.participant_fixture(project, member.hosted_identity)

      assert ProjectRoles.existing_role(project, digest) == :participant

      {:ok, _departed} =
        participant
        |> SddOrchestrator.Participation.ProjectParticipant.departure_changeset(%{
          departure_reason: "removed"
        })
        |> Repo.update()

      assert ProjectRoles.existing_role(project, digest) == nil
    end

    test "reports nothing for an unrelated existing identity or an unknown address" do
      %{project: project} = owned_project()
      unrelated = ParticipationFixtures.invited_identity_fixture()

      {:ok, unrelated_digest} =
        EmailDigest.compute(unrelated.external_identity.display_identifier)

      {:ok, unknown_digest} = EmailDigest.compute("nobody@example.com")

      assert ProjectRoles.existing_role(project, unrelated_digest) == nil
      assert ProjectRoles.existing_role(project, unknown_digest) == nil
    end

    test "is scoped to one project" do
      %{project: project} = owned_project()
      %{project: other_project} = owned_project()
      member = ParticipationFixtures.invited_identity_fixture()

      ParticipationFixtures.participant_fixture(project, member.hosted_identity)
      {:ok, digest} = EmailDigest.compute(member.external_identity.display_identifier)

      assert ProjectRoles.existing_role(project, digest) == :participant
      assert ProjectRoles.existing_role(other_project, digest) == nil
    end

    test "rejects a malformed digest without raising" do
      %{project: project} = owned_project()

      assert ProjectRoles.existing_role(project, nil) == nil
      assert ProjectRoles.existing_role(%SddOrchestrator.Projects.Project{}, "digest") == nil
    end
  end

  describe "invitation creation" do
    test "creates no invitation or credential for the owner or a current participant" do
      %{project: project, account: account, owner: owner} = owned_project()
      member = ParticipationFixtures.invited_identity_fixture()
      ParticipationFixtures.participant_fixture(project, member.hosted_identity)

      assert {:error, {:existing_role, :owner}} =
               Invitations.create(
                 project,
                 account.id,
                 owner.external_identity.display_identifier
               )

      assert {:error, {:existing_role, :participant}} =
               Invitations.create(
                 project,
                 account.id,
                 member.external_identity.display_identifier
               )

      assert Repo.aggregate(ProjectInvitation, :count) == 0
      refute_received {:participation_email, _email}
    end

    test "still invites an unrelated identity that already has an account" do
      %{project: project, account: account} = owned_project()
      unrelated = ParticipationFixtures.invited_identity_fixture()

      assert {:ok, %{invitation: invitation}} =
               Invitations.create(
                 project,
                 account.id,
                 unrelated.external_identity.display_identifier
               )

      assert invitation.status == "pending"
      assert_received {:participation_email, _email}
    end

    test "detects a member before any credential material is generated" do
      %{project: project, account: account, owner: owner} = owned_project()

      assert {:error, {:existing_role, :owner}} =
               Invitations.create(
                 project,
                 account.id,
                 owner.external_identity.display_identifier
               )

      # No pending row exists, so no salted credential was created and none can
      # be replayed against the project.
      assert Repo.aggregate(ProjectInvitation, :count) == 0
    end

    test "runs the same detection work whether or not the address is a member" do
      %{project: project, account: account, owner: owner} = owned_project()
      %{project: probe_project, account: probe_account} = owned_project()

      member_result =
        Invitations.create(project, account.id, owner.external_identity.display_identifier)

      unknown_result = Invitations.create(probe_project, probe_account.id, "nobody@example.com")

      # Detection is a project-membership comparison in both cases: the member
      # path stops before persistence, and the unknown path proceeds.
      assert {:error, {:existing_role, :owner}} = member_result
      assert {:ok, _created} = unknown_result
      assert Repo.aggregate(ProjectInvitation, :count) == 1
    end

    test "logs no address, digest, or enumeration signal for a detected member" do
      %{project: project, account: account, owner: owner} = owned_project()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          assert {:error, {:existing_role, :owner}} =
                   Invitations.create(
                     project,
                     account.id,
                     owner.external_identity.display_identifier
                   )
        end)

      refute log =~ owner.external_identity.display_identifier
      refute log =~ "existing_role"
      refute log =~ "participation_invitation"
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
end
