defmodule SddOrchestrator.Privacy.ParticipationGovernanceTest do
  @moduledoc """
  Proof for specs/29 (participation-completion) Task 1, AC-01, AC-02, AC-03.

  Two things are proven here, matching `SddOrchestrator.Privacy.ParticipationGovernance`'s
  own scope split:

    * Registry integrity — the literal seven-capability provider registry
      matches specs/29's `tasks.md` `Requires:` list exactly, and a
      deliberately broken variant (missing, duplicate, stale, or malformed)
      is rejected by `validate_providers/1` and blocks `readiness/1`
      publication, proving AC-01's rejection logic actually runs rather than
      the real registry merely happening to be complete.

    * Cross-provider compatibility — the substantive part. One integration
      scenario exercises the real boundary functions of every one of the
      seven ready providers together (specs/08, specs/25, specs/26,
      specs/27, specs/28), proving the seams between them: nothing conflicts,
      no rule double-fires, access denial is immediate and independent of
      retention or propagation completion, and backup recovery always
      tombstones over a stale snapshot. No single provider's own test suite
      exercises this composition — each proves its own contract in
      isolation, and this file is the one place that exercises all seven
      together in one lifecycle (mirroring, at full slice scale, what
      `SddOrchestrator.Participation.IdentityLifecycleCompatibilityTest` did
      for specs/25's own three tasks).
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.{AccountsFixtures, Participation, ParticipationFixtures}

  alias SddOrchestrator.Participation.{
    Acceptance,
    Boundary,
    Invitations,
    ParticipationEmailDelivery,
    ParticipationRevocation,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.Notifications.AccountNotification

  alias SddOrchestrator.Privacy.{
    ParticipationBackupLifecycle,
    ParticipationCleanupRequest,
    ParticipationContentBoundary,
    ParticipationDataUsePolicy,
    ParticipationGovernance,
    ParticipationOperationsAccess,
    ParticipationProcessingInventory,
    ParticipationPropagation,
    ParticipationSecurityEvent,
    ParticipationSecurityLog,
    ParticipationSupportAccess,
    Retention
  }

  @day 24 * 60 * 60

  @expected_providers [
    %{
      capability: "project-participation-boundary",
      specification: "specs/08-project-participation",
      task: "Task 4"
    },
    %{
      capability: "project-owner-display-profile",
      specification: "specs/08-project-participation",
      task: "Task 34"
    },
    %{
      capability: "project-participation-recipient-routing",
      specification: "specs/08-project-participation",
      task: "Task 36"
    },
    %{
      capability: "participation-identity-lifecycle",
      specification: "specs/25-participation-identity-lifecycle",
      task: "Task 4"
    },
    %{
      capability: "participation-processing-controls",
      specification: "specs/26-participation-data-protection-controls",
      task: "Task 5"
    },
    %{
      capability: "participation-operational-retention",
      specification: "specs/27-participation-operational-retention",
      task: "Task 3"
    },
    %{
      capability: "participation-deletion-recovery",
      specification: "specs/28-participation-deletion-and-recovery",
      task: "Task 2"
    }
  ]

  describe "registry integrity" do
    test "declares exactly the seven capabilities tasks.md requires, matching it exactly" do
      assert ParticipationGovernance.required_providers() == @expected_providers
      assert length(ParticipationGovernance.required_providers()) == 7

      assert ParticipationGovernance.capability_names() ==
               Enum.map(@expected_providers, & &1.capability)
    end

    test "no duplicate capability names in the real registry" do
      capabilities = Enum.map(ParticipationGovernance.required_providers(), & &1.capability)
      assert Enum.uniq(capabilities) == capabilities
    end

    test "no duplicate specification+task provider references in the real registry" do
      references =
        Enum.map(ParticipationGovernance.required_providers(), &{&1.specification, &1.task})

      assert Enum.uniq(references) == references
    end

    test "validate_providers/1 accepts the real registry" do
      assert ParticipationGovernance.validate_providers(
               ParticipationGovernance.required_providers()
             ) ==
               :ok
    end

    test "published_capability/0 names the sole capability this specification provides" do
      assert ParticipationGovernance.published_capability() == "project-participation-governance"
    end
  end

  describe "AC-01 missing, duplicate, stale, and malformed provider rejection" do
    test "rejects a registry missing a required capability" do
      [_dropped | rest] = ParticipationGovernance.required_providers()

      assert {:error, reasons} = ParticipationGovernance.validate_providers(rest)

      assert {:capability_set_mismatch,
              %{missing: ["project-participation-boundary"], unexpected: []}} in reasons
    end

    test "rejects a registry with an unexpected capability name outside the required seven" do
      extra = %{
        capability: "unrelated-capability",
        specification: "specs/99-unrelated",
        task: "Task 1"
      }

      broken = [extra | ParticipationGovernance.required_providers()]

      assert {:error, reasons} = ParticipationGovernance.validate_providers(broken)

      assert {:capability_set_mismatch, %{missing: [], unexpected: ["unrelated-capability"]}} in reasons
    end

    test "rejects a stale provider: an old and a new entry left in place for the same capability" do
      stale_and_fresh =
        ParticipationGovernance.required_providers() ++
          [
            %{
              capability: "participation-deletion-recovery",
              specification: "specs/28-participation-deletion-and-recovery",
              task: "Task 1"
            }
          ]

      assert {:error, reasons} = ParticipationGovernance.validate_providers(stale_and_fresh)
      assert {:duplicate_capability, "participation-deletion-recovery"} in reasons
    end

    test "rejects two capabilities pointing at the same provider task (a stale alias, not a fresh provider)" do
      [first, second | rest] = ParticipationGovernance.required_providers()
      aliased_second = %{second | specification: first.specification, task: first.task}

      assert {:error, reasons} =
               ParticipationGovernance.validate_providers([first, aliased_second | rest])

      assert {:duplicate_provider_reference, {first.specification, first.task}} in reasons
    end

    test "rejects a malformed entry: missing a required key" do
      [first | rest] = ParticipationGovernance.required_providers()
      malformed = Map.delete(first, :task)

      assert {:error, reasons} = ParticipationGovernance.validate_providers([malformed | rest])
      assert Enum.any?(reasons, &match?({:malformed_entry, ^malformed}, &1))
    end

    test "rejects a malformed entry: a task reference outside the closed `Task <n>` shape" do
      [first | rest] = ParticipationGovernance.required_providers()
      malformed = %{first | task: "task four"}

      assert {:error, reasons} = ParticipationGovernance.validate_providers([malformed | rest])
      assert Enum.any?(reasons, &match?({:malformed_entry, ^malformed}, &1))
    end

    test "readiness/1 reports governance unavailable and the earliest blocked stage for a broken registry" do
      [_dropped | broken] = ParticipationGovernance.required_providers()

      readiness = ParticipationGovernance.readiness(broken)

      refute readiness.registry_valid?
      assert readiness.implementation_readiness == :blocked
      assert readiness.local_verification_readiness == :blocked
      assert readiness.earliest_blocked_stage == :implementation

      assert {:capability_set_mismatch,
              %{missing: ["project-participation-boundary"], unexpected: []}} in readiness.blocking_reasons

      refute ParticipationGovernance.published?(broken)
    end
  end

  describe "AC-02/AC-03 staged readiness" do
    test "the real registry establishes implementation and local-verification readiness while release stays deferred" do
      readiness = ParticipationGovernance.readiness()

      assert readiness.registry_valid?
      assert readiness.implementation_readiness == :established
      assert readiness.local_verification_readiness == :established
      assert readiness.release_readiness == :deferred_to_release_gate
      assert readiness.earliest_blocked_stage == nil
      assert readiness.blocking_reasons == []
      assert ParticipationGovernance.published?()
    end

    test "implementation/local-verification readiness and release readiness are independent fields" do
      good = ParticipationGovernance.readiness()
      [_dropped | broken_providers] = ParticipationGovernance.required_providers()
      broken = ParticipationGovernance.readiness(broken_providers)

      # A broken registry blocks implementation/local-verification...
      assert good.implementation_readiness == :established
      assert broken.implementation_readiness == :blocked

      # ...but never changes release readiness in either direction: it is
      # never "established" by a passing registry and never further
      # weakened by a broken one. One local, structural check cannot move
      # a field that only deployment-specific evidence can move.
      assert good.release_readiness == :deferred_to_release_gate
      assert broken.release_readiness == :deferred_to_release_gate
    end
  end

  describe "AC-02 idempotency: readiness is a pure, repeatable computation" do
    test "readiness/0 and published?/0 return the identical result across repeated calls" do
      first = ParticipationGovernance.readiness()
      second = ParticipationGovernance.readiness()
      third = ParticipationGovernance.readiness()

      assert first == second
      assert second == third
      assert ParticipationGovernance.published?() == ParticipationGovernance.published?()
    end
  end

  describe "no provider mutation" do
    test "computing the registry, validation, and readiness never writes to a provider-owned table" do
      before_counts = provider_row_counts()

      ParticipationGovernance.required_providers()
      ParticipationGovernance.capability_names()
      ParticipationGovernance.validate_providers(ParticipationGovernance.required_providers())
      ParticipationGovernance.readiness()
      ParticipationGovernance.readiness()
      ParticipationGovernance.published?()

      assert provider_row_counts() == before_counts
    end
  end

  describe "cross-provider compatibility" do
    test "invite, accept, depart, operate, retain, recover, and propagate compose across every ready provider" do
      context = joined_project()

      # A bystander whose own authorization must stay untouched by everything
      # this test does to a different account, from start to finish.
      bystander = ParticipationFixtures.invited_identity_fixture()
      {:ok, _bystander_accept} = invite_and_accept(context, bystander, "Bystander")
      bystander_actor = actor_for(bystander)

      identity = ParticipationFixtures.invited_identity_fixture()

      # --- specs/25: invite (also exercises specs/27's diagnostic entity) ---
      {:ok, %{invitation: invitation}} =
        Invitations.create(
          context.project,
          context.account.id,
          identity.external_identity.display_identifier
        )

      # --- specs/25: accept -> one active participant + display profile ---
      assert {:ok, accepted} =
               Acceptance.accept(invitation.id, identity.hosted_identity, "Compat Member")

      actor = actor_for(identity)

      # --- specs/08: the published Boundary confirms current membership and
      # capability while participation is active ---
      assert {:ok, member} = Boundary.current_member(context.project.id, actor)
      assert member.role == :participant
      assert member.display_name == "Compat Member"
      assert Boundary.authorized?(context.project, actor, :read_specifications)
      refute Boundary.authorized?(context.project, actor, :manage_participants)

      # --- specs/26 Task 1: the processing inventory stays complete while
      # real rows exist for every entity it classifies ---
      assert ParticipationProcessingInventory.missing_fields() == %{}
      assert ParticipationProcessingInventory.unknown_fields() == %{}
      assert ParticipationProcessingInventory.validate_all() == :ok

      # --- specs/26 Task 5: the data-use policy authorizes exactly the
      # membership-management and email-delivery routes the invite/accept
      # flow just exercised, and refuses secondary use for the same entity ---
      assert ParticipationDataUsePolicy.authorize(
               :project_participant,
               :membership_management,
               :project_owner
             ) == :ok

      assert ParticipationDataUsePolicy.authorize(
               :project_invitation,
               :email_delivery,
               :email_delivery_provider
             ) == :ok

      assert ParticipationDataUsePolicy.authorize(
               :project_member_profile,
               :analytics,
               :current_participant
             ) == {:error, :secondary_use_prohibited}

      # --- specs/26 Task 4: the content boundary independently catches what
      # DisplayName alone does not, and authorizes exactly the destination
      # the invite's own delivery_email field just used ---
      assert ParticipationContentBoundary.scan_text("sk-abcdefghijklmnopqrst", "actor_label") ==
               {:error, :credential_detected}

      assert ParticipationContentBoundary.authorize_destination(
               :project_invitation,
               :delivery_email,
               :email_delivery_provider
             ) == :ok

      assert ParticipationContentBoundary.authorize_destination(
               :project_invitation,
               :delivery_email,
               :hosted_database
             ) == {:error, :unapproved_destination}

      # --- specs/26 Task 2: the operations view sees the real invite
      # delivery diagnostic, scoped to this project, with no identity or
      # content beyond its closed field allowlist ---
      ops_view = ParticipationOperationsAccess.metadata_for_project(context.project.id)
      assert Enum.any?(ops_view, &(&1.subject_ref == invitation.id))

      ops_fields = ops_view |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
      assert Enum.all?(ops_fields, &(&1 in ParticipationOperationsAccess.allowed_fields()))

      ops_text = ops_view |> inspect() |> String.downcase()
      refute ops_text =~ String.downcase(identity.external_identity.display_identifier)
      refute ops_text =~ "compat member"

      # --- specs/26 Task 3 + specs/28 Task 1: recovery is closed to ordinary
      # reads until a valid content-scoped support elevation exists ---
      assert ParticipationBackupLifecycle.recover(
               :project_participant,
               context.project.id,
               accepted.participant.id,
               %{},
               nil
             ) == {:error, :unauthorized}

      elevation = content_elevation(context.project)

      assert {:ok, live} =
               ParticipationBackupLifecycle.recover(
                 :project_participant,
                 context.project.id,
                 accepted.participant.id,
                 %{hosted_identity_id: Ecto.UUID.generate()},
                 elevation.id
               )

      assert live.hosted_identity_id == identity.hosted_identity.id
      assert live.source == :current_primary_store

      # --- specs/25 fail-closed rule composed with specs/27's security log:
      # the immutable owner is refused a self-leave, and the real domain
      # error is classified and recorded by the security log unchanged ---
      assert {:error, :owner_cannot_leave} =
               ParticipationSecurityLog.audit(
                 Revocations.leave(
                   context.project,
                   context.account.id,
                   context.owner.hosted_identity.id
                 ),
                 :revocation_denied
               )

      assert [owner_denied_event] = Repo.all(ParticipationSecurityEvent)
      assert owner_denied_event.outcome == :denied
      assert owner_denied_event.reason == :owner_cannot_leave
      refute inspect(owner_denied_event) =~ context.account.id

      # --- specs/25/08: the real departure ---
      assert {:ok, %{revocation: revocation}} =
               Revocations.leave(
                 context.project,
                 identity.account.id,
                 identity.hosted_identity.id
               )

      # Access ends immediately, before retention or propagation ever run.
      assert {:error, :not_a_member} = Boundary.current_member(context.project.id, actor)
      refute Boundary.authorized?(context.project, actor, :read_specifications)

      # The bystander's own authorization is completely unaffected by this
      # unrelated account's departure.
      assert {:ok, :participant} =
               Participation.member_role(
                 context.project,
                 bystander_actor.account_id,
                 bystander_actor.hosted_identity_id
               )

      # --- specs/28 Task 1: immediately after departure the identity link
      # has not been released yet (that is specs/27's 30-day rule below), so
      # recovery still correctly reflects the current, still-linked row ---
      assert {:ok, still_linked} =
               ParticipationBackupLifecycle.recover(
                 :project_participant,
                 context.project.id,
                 accepted.participant.id,
                 %{hosted_identity_id: Ecto.UUID.generate()},
                 elevation.id
               )

      assert still_linked.hosted_identity_id == identity.hosted_identity.id

      # --- specs/28 Task 2: propagate the departure's cleanup to every
      # configured non-backup destination, using a caller-minted opaque
      # reference the way Rights' own anonymization workflow does ---
      subject_ref = Ecto.UUID.generate()
      assert {:ok, requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)
      assert Enum.map(requests, & &1.destination) == ParticipationPropagation.destinations()
      assert {:ok, summary} = ParticipationPropagation.reconcile()
      assert summary.claimed >= length(requests)

      # Access stays denied regardless of propagation's own outcome: primary
      # authorization never waits on cleanup completion.
      assert {:error, :not_a_member} = Boundary.current_member(context.project.id, actor)

      # --- specs/27 Task 3: 31 days later, one Retention.prune_all/1 pass
      # composes the operational-retention rules for every provider this
      # scenario touched: the departed identity link, the revocation's
      # former-identity routing, the finalized invite email diagnostic, and
      # the owner-denial security event just recorded above ---
      later = DateTime.add(DateTime.utc_now(), 31 * @day, :second)
      counts = Retention.prune_all(later)

      assert counts.departed_participant_links == 1
      assert counts.participation_revocation_links == 1
      assert counts.expired_participation_email_delivery_diagnostics >= 1
      assert counts.expired_participation_security_events == 1

      pruned_participant = Repo.get!(ProjectParticipant, accepted.participant.id)
      assert is_nil(pruned_participant.hosted_identity_id)
      assert Repo.all(ParticipationSecurityEvent) == []

      # --- specs/25's own consumer-acknowledgement handoff, arriving late
      # (after retention already released the identity links it governs) ---
      assert {:ok, acknowledged} =
               Revocations.acknowledge(revocation.id, "governance-compat-proof")

      assert acknowledged.acknowledged_at

      # --- specs/28 Task 1: tombstone-first ordering still holds under this
      # exact race — recovery is refused even though the caller-supplied
      # backup snapshot still carries the old, stale identity ---
      stale_snapshot = %{hosted_identity_id: identity.hosted_identity.id}

      assert ParticipationBackupLifecycle.recover(
               :project_participant,
               context.project.id,
               accepted.participant.id,
               stale_snapshot,
               elevation.id
             ) == {:error, :tombstoned}

      assert ParticipationBackupLifecycle.recover(
               :participation_revocation,
               context.project.id,
               revocation.id,
               %{
                 former_hosted_identity_id: identity.hosted_identity.id,
                 former_account_id: identity.account.id
               },
               elevation.id
             ) == {:error, :tombstoned}

      # --- The bystander is still completely fine after every provider in
      # this scenario has run: boundary, processing, content, operations,
      # support access, backup recovery, propagation, and retention. ---
      assert {:ok, :participant} =
               Participation.member_role(
                 context.project,
                 bystander_actor.account_id,
                 bystander_actor.hosted_identity_id
               )

      assert Boundary.authorized?(context.project, bystander_actor, :read_specifications)

      # --- The governance registry itself is untouched by any of this real
      # activity: still valid, still published, still the same pure result. ---
      assert ParticipationGovernance.published?()
    end
  end

  defp joined_project(attrs \\ %{}) do
    result = ParticipationFixtures.hosted_project_fixture(attrs)

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    result
  end

  defp invite_and_accept(context, identity, display_name) do
    {:ok, %{invitation: invitation}} =
      Invitations.create(
        context.project,
        context.account.id,
        identity.external_identity.display_identifier
      )

    Acceptance.accept(invitation.id, identity.hosted_identity, display_name)
  end

  defp actor_for(identity),
    do: %{account_id: identity.account.id, hosted_identity_id: identity.hosted_identity.id}

  defp content_elevation(project) do
    operations_account = AccountsFixtures.account_fixture()

    {:ok, elevation} =
      ParticipationSupportAccess.issue(%{
        operations_account_id: operations_account.id,
        project_id: project.id,
        purpose: :incident_diagnosis,
        scope: :content,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    elevation
  end

  defp provider_row_counts do
    %{
      project_invitation: Repo.aggregate(ProjectInvitation, :count),
      project_participant: Repo.aggregate(ProjectParticipant, :count),
      project_member_profile: Repo.aggregate(ProjectMemberProfile, :count),
      participation_revocation: Repo.aggregate(ParticipationRevocation, :count),
      participation_email_delivery: Repo.aggregate(ParticipationEmailDelivery, :count),
      account_notification: Repo.aggregate(AccountNotification, :count),
      participation_security_event: Repo.aggregate(ParticipationSecurityEvent, :count),
      participation_cleanup_request: Repo.aggregate(ParticipationCleanupRequest, :count)
    }
  end
end
