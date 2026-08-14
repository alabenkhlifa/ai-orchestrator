defmodule SddOrchestrator.Privacy.ParticipationBackupLifecycleTest do
  @moduledoc """
  Proof for specs/28 Task 1 (AC-01): participation encrypted-backup lifecycle
  expiry, and tombstone-first recovery ordering.

  The 35-day/encrypted/recovery-only contract is asserted to come straight
  from `SddOrchestrator.Privacy.DeploymentPrivacyProfile` rather than a
  second, duplicated constant. The core proof is ordering: a recovery read
  for an identity link that is still active in the primary store succeeds
  and reflects current state; a recovery read for a link the primary store
  has already tombstoned (a departed-and-link-released participant, an
  anonymized member profile, or an acknowledged revocation handoff) is
  refused even when the simulated backup content passed to the call still
  carries the old, stale identity value. Recovery is also proven closed to
  ordinary product reads and to ordinary (metadata-scope) support reads,
  reusing the same specs/26 Task 3 exceptional support-access boundary
  rather than a second access-control mechanism. Finally, the module is
  proven to introduce no new authoritative participation entity.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ParticipationFixtures

  alias SddOrchestrator.Participation.{
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.Privacy.{
    DeploymentPrivacyProfile,
    ParticipationBackupLifecycle,
    ParticipationSupportAccess
  }

  describe "AC-01 backup lifecycle contract mirrors the shared deployment contract" do
    test "the participation contract is read from DeploymentPrivacyProfile, not duplicated" do
      assert ParticipationBackupLifecycle.contract() ==
               DeploymentPrivacyProfile.backup_lifecycle_contract()
    end

    test "the contract is encrypted, recovery-only, expires within 35 days, and requires deletion propagation" do
      contract = ParticipationBackupLifecycle.contract()

      assert contract.encrypted == true
      assert contract.maximum_expiry_days == 35
      assert contract.restore_scope == :approved_recovery_only
      assert contract.deletion_propagation == :required
    end

    test "maximum_expiry_days/0 matches the contract's own ceiling" do
      assert ParticipationBackupLifecycle.maximum_expiry_days() == 35

      assert ParticipationBackupLifecycle.maximum_expiry_days() ==
               ParticipationBackupLifecycle.contract().maximum_expiry_days
    end

    test "the recovery handoff is read from DeploymentPrivacyProfile.backup_handoff(:access)" do
      assert ParticipationBackupLifecycle.recovery_handoff() ==
               DeploymentPrivacyProfile.backup_handoff(:access)

      assert ParticipationBackupLifecycle.recovery_handoff().action == :access

      assert ParticipationBackupLifecycle.recovery_handoff().restore_scope ==
               :approved_recovery_only
    end
  end

  describe "AC-01 tombstone-first recovery: project_participant" do
    test "a still-active identity link recovers, reflecting current state rather than the backup snapshot" do
      %{project: project, identity: identity, participant: participant} = active_participant()
      elevation = content_elevation(project)
      stale_snapshot = %{hosted_identity_id: Ecto.UUID.generate()}

      assert {:ok, result} =
               ParticipationBackupLifecycle.recover(
                 :project_participant,
                 project.id,
                 participant.id,
                 stale_snapshot,
                 elevation.id
               )

      assert result.hosted_identity_id == identity.hosted_identity.id
      refute result.hosted_identity_id == stale_snapshot.hosted_identity_id
      assert result.source == :current_primary_store
    end

    test "a departed, link-released participant is refused even though the backup snapshot still has the old identity" do
      %{project: project, identity: identity, participant: participant} =
        departed_and_released_participant()

      elevation = content_elevation(project)
      stale_snapshot = %{hosted_identity_id: identity.hosted_identity.id}

      assert is_nil(participant.hosted_identity_id)

      assert ParticipationBackupLifecycle.recover(
               :project_participant,
               project.id,
               participant.id,
               stale_snapshot,
               elevation.id
             ) == {:error, :tombstoned}
    end
  end

  describe "AC-01 tombstone-first recovery: project_member_profile" do
    test "an active profile recovers, reflecting current state" do
      %{project: project, account: account, profile: profile} = active_member_profile()
      elevation = content_elevation(project)

      assert {:ok, result} =
               ParticipationBackupLifecycle.recover(
                 :project_member_profile,
                 project.id,
                 profile.id,
                 %{account_id: Ecto.UUID.generate()},
                 elevation.id
               )

      assert result.account_id == account.id
      assert result.state == "active"
    end

    test "an anonymized profile is refused even though the backup snapshot still has the old account link" do
      %{project: project, account: account, profile: profile} = anonymized_member_profile()
      elevation = content_elevation(project)

      assert profile.state == "anonymized"
      assert is_nil(profile.account_id)

      assert ParticipationBackupLifecycle.recover(
               :project_member_profile,
               project.id,
               profile.id,
               %{account_id: account.id},
               elevation.id
             ) == {:error, :tombstoned}
    end
  end

  describe "AC-01 tombstone-first recovery: participation_revocation" do
    test "a not-yet-acknowledged handoff recovers, reflecting the current former-identity links" do
      %{project: project, identity: identity, revocation: revocation} =
        departed_unacknowledged()

      elevation = content_elevation(project)

      assert {:ok, result} =
               ParticipationBackupLifecycle.recover(
                 :participation_revocation,
                 project.id,
                 revocation.id,
                 %{former_hosted_identity_id: Ecto.UUID.generate()},
                 elevation.id
               )

      assert result.former_hosted_identity_id == identity.hosted_identity.id
      assert result.former_account_id == identity.account.id
    end

    test "an acknowledged handoff is refused even though the backup snapshot still has the old former-identity links" do
      %{project: project, identity: identity, revocation: revocation} = acknowledged_revocation()
      elevation = content_elevation(project)

      stale_snapshot = %{
        former_hosted_identity_id: identity.hosted_identity.id,
        former_account_id: identity.account.id
      }

      assert is_nil(revocation.former_hosted_identity_id)
      assert is_nil(revocation.former_account_id)

      assert ParticipationBackupLifecycle.recover(
               :participation_revocation,
               project.id,
               revocation.id,
               stale_snapshot,
               elevation.id
             ) == {:error, :tombstoned}
    end
  end

  describe "AC-01 restore ordering" do
    test "an unknown entity id inside a real project is refused as not found, never fabricated from the snapshot" do
      %{project: project} = project_fixture()
      elevation = content_elevation(project)

      assert ParticipationBackupLifecycle.recover(
               :project_participant,
               project.id,
               Ecto.UUID.generate(),
               %{hosted_identity_id: Ecto.UUID.generate()},
               elevation.id
             ) == {:error, :not_found}
    end
  end

  describe "AC-01 recovery-only: closed to product and ordinary support reads" do
    test "no elevation at all is refused (recovery is not an ordinary product read)" do
      %{project: project, participant: participant} = active_participant()

      assert ParticipationBackupLifecycle.recover(
               :project_participant,
               project.id,
               participant.id,
               %{},
               nil
             ) == {:error, :unauthorized}
    end

    test "an ordinary, metadata-scope support elevation is refused" do
      %{project: project, participant: participant} = active_participant()
      elevation = metadata_elevation(project)

      assert ParticipationBackupLifecycle.recover(
               :project_participant,
               project.id,
               participant.id,
               %{},
               elevation.id
             ) == {:error, :unauthorized}
    end

    test "a content-scoped elevation bound to a different project is refused" do
      %{project: project, participant: participant} = active_participant()
      %{project: other_project} = project_fixture()
      elevation = content_elevation(other_project)

      assert ParticipationBackupLifecycle.recover(
               :project_participant,
               project.id,
               participant.id,
               %{},
               elevation.id
             ) == {:error, :unauthorized}
    end
  end

  describe "AC-01 no new authoritative participation entity" do
    test "the module is not backed by an Ecto schema of its own" do
      refute function_exported?(ParticipationBackupLifecycle, :__schema__, 1)
    end
  end

  defp project_fixture do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    %{project: result.project}
  end

  defp active_participant do
    %{project: project} = project_fixture()
    identity = ParticipationFixtures.invited_identity_fixture()
    participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Participant")
    })

    %{project: project, identity: identity, participant: participant}
  end

  defp departed_and_released_participant do
    %{project: project, identity: identity} = active_participant()

    {:ok, %{participant: departed}} =
      Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

    {:ok, released} =
      departed
      |> ProjectParticipant.identity_release_changeset()
      |> Repo.update()

    %{project: project, identity: identity, participant: released}
  end

  defp active_member_profile do
    %{project: project} = project_fixture()
    account = AccountsFixtures.account_fixture()

    profile =
      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "participant",
        display_name: ParticipationFixtures.unique_display_name("Member")
      })

    %{project: project, account: account, profile: profile}
  end

  defp anonymized_member_profile do
    %{project: project, account: account, profile: profile} = active_member_profile()

    {:ok, anonymized} =
      profile
      |> ProjectMemberProfile.anonymization_changeset()
      |> Repo.update()

    %{project: project, account: account, profile: anonymized}
  end

  defp departed_unacknowledged do
    %{project: project, identity: identity} = active_participant()

    {:ok, %{revocation: revocation}} =
      Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

    %{project: project, identity: identity, revocation: revocation}
  end

  defp acknowledged_revocation do
    %{project: project, identity: identity, revocation: revocation} = departed_unacknowledged()

    {:ok, acknowledged} =
      Revocations.acknowledge(revocation.id, "specs-28-task-1", DateTime.utc_now())

    %{project: project, identity: identity, revocation: acknowledged}
  end

  defp content_elevation(project), do: elevation_fixture(project, :content)
  defp metadata_elevation(project), do: elevation_fixture(project, :metadata)

  defp elevation_fixture(project, scope) do
    operations_account = AccountsFixtures.account_fixture()

    {:ok, elevation} =
      ParticipationSupportAccess.issue(%{
        operations_account_id: operations_account.id,
        project_id: project.id,
        purpose: :incident_diagnosis,
        scope: scope,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    elevation
  end
end
