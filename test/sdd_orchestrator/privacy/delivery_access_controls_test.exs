defmodule SddOrchestrator.Privacy.DeliveryAccessControlsTest do
  @moduledoc """
  Proof for specs/18 Task 2 (AC-02, AC-03): guided-delivery content stays
  inside current project participation, and exceptional support or operations
  access is content-free by default and requires verified, least-privilege,
  time-bounded, purpose-limited, audited elevation.

  AC-02 is proved by exercising the already-approved, already-applied Slice 07
  boundary (`SddOrchestrator.Delivery.ParticipantGuard`) at the
  privacy-specification level: a current participant reads; a stale, removed,
  absent, or cross-project identity is denied identically, without content
  disclosure. This does not duplicate `participant_guard_test.exs`'s exhaustive
  per-action coverage; it proves the same contract holds from this
  specification's own vantage point.

  AC-03 is proved against the new, separate exceptional-support boundary
  (`SddOrchestrator.Privacy.DeliverySupportAccess`): a plain grant defaults to
  metadata-only and never authorizes a content read; an explicit,
  content-scoped, currently valid grant does, scoped to exactly one project;
  every denial reason (absent, malformed, wrong-project, metadata-only,
  expired, revoked) returns the identical non-disclosing result; issuing
  enforces a closed purpose vocabulary and a required, bounded expiry; and
  every issue, authorize, and revoke outcome is audited through a minimized,
  allowlisted payload that a call site cannot smuggle content or an email
  through.
  """
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Delivery.ParticipantGuard
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures

  alias SddOrchestrator.Privacy.{
    DeliverySupportAccess,
    DeliverySupportAudit,
    DeliverySupportElevation
  }

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

  describe "AC-02 current-participant project reads" do
    test "the owner and a current participant read every protected guided-delivery action" do
      %{project: project, owner_actor: owner_actor, participant_actor: participant_actor} =
        joined()

      for actor <- [owner_actor, participant_actor],
          action <- ParticipantGuard.protected_actions() do
        assert {:ok, _member} = ParticipantGuard.authorize_action(project.id, actor, action)
      end
    end

    test "an absent identity is denied without content disclosure" do
      %{project: project} = joined()

      assert ParticipantGuard.authorize(project.id, nil) == {:error, :unauthorized}
      assert ParticipantGuard.authorize(project.id, %{}) == {:error, :unauthorized}
    end

    test "a stale (never-a-member) and a cross-project identity deny identically to an absent one" do
      %{project: project, participant_actor: actor} = joined()
      %{project: other_project} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      outsider_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      absent = ParticipantGuard.authorize(project.id, nil)
      stale = ParticipantGuard.authorize(project.id, outsider_actor)
      cross_project = ParticipantGuard.authorize(other_project.id, actor)

      assert absent == {:error, :unauthorized}
      assert stale == absent
      assert cross_project == absent
    end

    test "a removed participant is denied immediately, on every protected action" do
      %{project: project, account: owner_account, participant_actor: actor, identity: identity} =
        joined()

      assert {:ok, _member} = ParticipantGuard.authorize_action(project.id, actor, :view_feature)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      for action <- ParticipantGuard.protected_actions() do
        assert ParticipantGuard.authorize_action(project.id, actor, action) ==
                 {:error, :unauthorized}
      end
    end

    test "an unknown project id is indistinguishable from a project the caller cannot read" do
      %{participant_actor: actor} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      outsider_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      %{project: project} = joined()

      unknown = ParticipantGuard.authorize(Ecto.UUID.generate(), actor)
      unauthorized = ParticipantGuard.authorize(project.id, outsider_actor)

      assert unknown == {:error, :unauthorized}
      assert unknown == unauthorized
    end
  end

  describe "AC-03 default support access is content-free" do
    test "no elevation at all is content-free by default" do
      %{project: project} = joined()

      assert DeliverySupportAccess.authorize_content_read(project.id, Ecto.UUID.generate()) ==
               {:error, :unauthorized}
    end

    test "issuing without scope defaults to :metadata and never authorizes a content read" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:ok, elevation} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert elevation.scope == :metadata
      refute DeliverySupportElevation.content_scope?(elevation)

      assert DeliverySupportAccess.authorize_content_read(project.id, elevation.id) ==
               {:error, :unauthorized}
    end

    test "explicitly issuing scope: :metadata behaves identically to omitting it" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:ok, elevation} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :metadata,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert DeliverySupportAccess.authorize_content_read(project.id, elevation.id) ==
               {:error, :unauthorized}
    end
  end

  describe "AC-03 exceptional elevation: issue and least privilege" do
    test "an explicit content-scoped, currently valid grant authorizes exactly its own project's content read" do
      %{elevation: elevation, project: project} = elevation_fixture()

      assert {:ok, ^elevation} =
               DeliverySupportAccess.authorize_content_read(project.id, elevation.id)
    end

    test "a content-scoped grant does not authorize a read for a different project" do
      %{elevation: elevation} = elevation_fixture()
      %{project: other_project} = joined()

      assert DeliverySupportAccess.authorize_content_read(other_project.id, elevation.id) ==
               {:error, :unauthorized}
    end

    test "issuing refuses an unapproved scope" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:error, changeset} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :full_access,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert %{scope: ["is invalid"]} = errors_on(changeset)
    end

    test "issuing requires a present expiry" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:error, changeset} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :content
        })

      assert %{expires_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "issuing refuses an unbounded expiry" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:error, changeset} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :content,
          expires_at: DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
        })

      assert %{expires_at: [message]} = errors_on(changeset)
      assert message =~ "within"
    end

    test "a grant cannot outlive the maximum bounded duration" do
      assert DeliverySupportElevation.max_duration_seconds() == 86_400
    end
  end

  describe "AC-03 elevation expiry" do
    test "an elevation is valid strictly before its own expiry and invalid at or after it" do
      now = DateTime.utc_now()
      elevation = %DeliverySupportElevation{revoked_at: nil, expires_at: now}

      assert DeliverySupportElevation.valid_at?(elevation, DateTime.add(now, -1, :second))
      refute DeliverySupportElevation.valid_at?(elevation, now)
      refute DeliverySupportElevation.valid_at?(elevation, DateTime.add(now, 1, :second))
    end

    test "an already-expired grant denies a content read and is audited as expired" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:ok, elevation} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :content,
          issued_at: DateTime.add(DateTime.utc_now(), -7200, :second),
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      refute DeliverySupportElevation.valid_at?(elevation, DateTime.utc_now())

      log =
        capture_log(fn ->
          assert DeliverySupportAccess.authorize_content_read(project.id, elevation.id) ==
                   {:error, :unauthorized}
        end)

      assert log =~ "event=authorize"
      assert log =~ "outcome=denied"
      assert log =~ "reason=expired"
    end
  end

  describe "AC-03 elevation revocation" do
    test "revoking a content-scoped elevation immediately denies further content reads" do
      %{elevation: elevation, project: project} = elevation_fixture()
      revoker = AccountsFixtures.account_fixture()

      assert {:ok, _elevation} =
               DeliverySupportAccess.authorize_content_read(project.id, elevation.id)

      assert {:ok, revoked} = DeliverySupportAccess.revoke(elevation.id, revoker.id)
      assert %DateTime{} = revoked.revoked_at
      assert revoked.revoked_by_account_id == revoker.id

      assert DeliverySupportAccess.authorize_content_read(project.id, elevation.id) ==
               {:error, :unauthorized}
    end

    test "revoking an already-revoked elevation is refused rather than silently repeated" do
      %{elevation: elevation} = elevation_fixture()
      revoker = AccountsFixtures.account_fixture()

      assert {:ok, _revoked} = DeliverySupportAccess.revoke(elevation.id, revoker.id)
      assert {:error, changeset} = DeliverySupportAccess.revoke(elevation.id, revoker.id)
      assert %{revoked_at: ["is already recorded"]} = errors_on(changeset)
    end

    test "revoking an unknown elevation is refused" do
      revoker = AccountsFixtures.account_fixture()

      assert DeliverySupportAccess.revoke(Ecto.UUID.generate(), revoker.id) ==
               {:error, :not_found}
    end
  end

  describe "AC-03 purpose validation" do
    test "the purpose vocabulary is closed" do
      assert DeliverySupportAccess.purposes() == [:incident_diagnosis, :security_investigation]
    end

    test "issuing refuses a purpose outside the closed vocabulary" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:error, changeset} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :curiosity,
          scope: :content,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert %{purpose: ["is invalid"]} = errors_on(changeset)
    end

    test "issuing refuses free-text prose in place of a purpose atom" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:error, changeset} =
        DeliverySupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: "helping the participant who filed a ticket",
          scope: :content,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert %{purpose: ["is invalid"]} = errors_on(changeset)
    end

    test "every approved purpose issues successfully" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      for purpose <- DeliverySupportAccess.purposes() do
        assert {:ok, elevation} =
                 DeliverySupportAccess.issue(%{
                   operations_account_id: operations_account.id,
                   project_id: project.id,
                   purpose: purpose,
                   scope: :metadata,
                   expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
                 })

        assert elevation.purpose == purpose
      end
    end
  end

  describe "AC-03 minimized audit trail" do
    test "issuing, authorizing, and revoking each emit only allowlisted keys" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()
      revoker = AccountsFixtures.account_fixture()

      log =
        capture_log(fn ->
          {:ok, elevation} =
            DeliverySupportAccess.issue(%{
              operations_account_id: operations_account.id,
              project_id: project.id,
              purpose: :incident_diagnosis,
              scope: :content,
              expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
            })

          DeliverySupportAccess.authorize_content_read(project.id, elevation.id)
          DeliverySupportAccess.revoke(elevation.id, revoker.id)
        end)

      assert log =~ "[#{DeliverySupportAudit.tag()}]"
      assert log =~ "event=issue"
      assert log =~ "event=authorize"
      assert log =~ "event=revoke"
      assert log =~ "outcome=granted"

      allowed = DeliverySupportAudit.allowed_keys()

      for line <- String.split(log, "\n"),
          String.contains?(line, "[#{DeliverySupportAudit.tag()}]") do
        [_prefix, payload] = String.split(line, "[#{DeliverySupportAudit.tag()}] ", parts: 2)

        keys =
          payload
          |> String.split(" ", trim: true)
          |> Enum.map(fn pair ->
            pair |> String.split("=", parts: 2) |> hd() |> String.to_atom()
          end)

        for key <- keys do
          assert key in allowed, "unexpected audit key #{inspect(key)} in line #{inspect(line)}"
        end
      end
    end

    test "a call site cannot smuggle project content, a name, or an email into the audit trail" do
      log =
        capture_log(fn ->
          DeliverySupportAudit.event(:authorize, %{
            outcome: :granted,
            elevation_id: "abc-123",
            reason: :ok,
            project_name: "Secret Launch Project",
            feature_title: "Unreleased pricing feature",
            comment_body: "the participant's private comment",
            participant_email: "person@example.com"
          })
        end)

      assert log =~ "event=authorize"
      refute log =~ "Secret Launch Project"
      refute log =~ "Unreleased pricing feature"
      refute log =~ "private comment"
      refute log =~ "person@example.com"
      refute log =~ "project_name"
      refute log =~ "feature_title"
      refute log =~ "comment_body"
      refute log =~ "participant_email"
    end

    test "an issue rejected for invalid attributes is still audited, without content" do
      %{project: project} = joined()

      log =
        capture_log(fn ->
          DeliverySupportAccess.issue(%{
            operations_account_id: nil,
            project_id: project.id,
            purpose: :not_a_real_purpose,
            scope: :content
          })
        end)

      assert log =~ "event=issue"
      assert log =~ "outcome=rejected"
    end
  end

  describe "shared content-existence non-disclosure (AC-02 and AC-03)" do
    test "every AC-03 denial reason — absent, malformed, wrong-project, metadata-only, expired, revoked — returns the identical result" do
      %{elevation: content_elevation, project: project} = elevation_fixture()
      %{project: other_project} = joined()

      {:ok, metadata_elevation} =
        DeliverySupportAccess.issue(%{
          operations_account_id: AccountsFixtures.account_fixture().id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :metadata,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, expired_elevation} =
        DeliverySupportAccess.issue(%{
          operations_account_id: AccountsFixtures.account_fixture().id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :content,
          issued_at: DateTime.add(DateTime.utc_now(), -7200, :second),
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      %{elevation: to_revoke} = elevation_fixture()
      revoker = AccountsFixtures.account_fixture()
      {:ok, revoked_elevation} = DeliverySupportAccess.revoke(to_revoke.id, revoker.id)

      absent = DeliverySupportAccess.authorize_content_read(project.id, Ecto.UUID.generate())
      malformed = DeliverySupportAccess.authorize_content_read(project.id, "not-a-uuid")

      wrong_project =
        DeliverySupportAccess.authorize_content_read(other_project.id, content_elevation.id)

      metadata_only =
        DeliverySupportAccess.authorize_content_read(project.id, metadata_elevation.id)

      expired = DeliverySupportAccess.authorize_content_read(project.id, expired_elevation.id)

      revoked =
        DeliverySupportAccess.authorize_content_read(project.id, revoked_elevation.id)

      results = [absent, malformed, wrong_project, metadata_only, expired, revoked]

      assert Enum.uniq(results) == [{:error, :unauthorized}]
    end

    test "AC-02 and AC-03 deny in the identical shape" do
      %{project: project, participant_actor: actor} = joined()

      participation_denial = ParticipantGuard.authorize(Ecto.UUID.generate(), actor)

      support_denial =
        DeliverySupportAccess.authorize_content_read(project.id, Ecto.UUID.generate())

      assert participation_denial == {:error, :unauthorized}
      assert support_denial == {:error, :unauthorized}
      assert participation_denial == support_denial
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

  defp elevation_fixture(overrides \\ %{}) do
    %{project: project} = joined()
    operations_account = AccountsFixtures.account_fixture()

    attrs =
      Map.merge(
        %{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :content,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        overrides
      )

    {:ok, elevation} = DeliverySupportAccess.issue(attrs)

    %{elevation: elevation, project: project, operations_account: operations_account}
  end
end
