defmodule SddOrchestrator.Privacy.ParticipationSupportAccessTest do
  @moduledoc """
  Proof for specs/26 Task 3 (AC-03): participation support access is
  content-free by default and any exception requires verified authority,
  least privilege, one purpose and scope, a fixed expiry, revocation, and a
  minimized audit record.

  Mirrors specs/18 Task 2's `delivery_access_controls_test.exs` AC-03
  coverage against the new, separate exceptional-support boundary
  (`SddOrchestrator.Privacy.ParticipationSupportAccess`): a plain grant
  defaults to metadata-only and never authorizes a content read; an
  explicit, content-scoped, currently valid grant does, scoped to exactly
  one project; every denial reason (absent, malformed, wrong-project,
  metadata-only, expired, revoked) returns the identical non-disclosing
  result; issuing enforces a closed purpose vocabulary and a required,
  bounded expiry; and every issue, authorize, and revoke outcome is audited
  through a minimized, allowlisted payload that a call site cannot smuggle
  content, a display name, or an email through.
  """
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ParticipationFixtures

  alias SddOrchestrator.Privacy.{
    ParticipationSupportAccess,
    ParticipationSupportAudit,
    ParticipationSupportElevation
  }

  describe "AC-03 default support access is content-free" do
    test "no elevation at all is content-free by default" do
      %{project: project} = joined()

      assert ParticipationSupportAccess.authorize_content_read(
               project.id,
               Ecto.UUID.generate()
             ) == {:error, :unauthorized}
    end

    test "issuing without scope defaults to :metadata and never authorizes a content read" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:ok, elevation} =
        ParticipationSupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert elevation.scope == :metadata
      refute ParticipationSupportElevation.content_scope?(elevation)

      assert ParticipationSupportAccess.authorize_content_read(project.id, elevation.id) ==
               {:error, :unauthorized}
    end

    test "explicitly issuing scope: :metadata behaves identically to omitting it" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:ok, elevation} =
        ParticipationSupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :metadata,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert ParticipationSupportAccess.authorize_content_read(project.id, elevation.id) ==
               {:error, :unauthorized}
    end
  end

  describe "AC-03 exceptional elevation: issue and least privilege" do
    test "an explicit content-scoped, currently valid grant authorizes exactly its own project's content read" do
      %{elevation: elevation, project: project} = elevation_fixture()

      assert {:ok, ^elevation} =
               ParticipationSupportAccess.authorize_content_read(project.id, elevation.id)
    end

    test "a content-scoped grant does not authorize a read for a different project" do
      %{elevation: elevation} = elevation_fixture()
      %{project: other_project} = joined()

      assert ParticipationSupportAccess.authorize_content_read(other_project.id, elevation.id) ==
               {:error, :unauthorized}
    end

    test "issuing refuses an unapproved scope" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:error, changeset} =
        ParticipationSupportAccess.issue(%{
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
        ParticipationSupportAccess.issue(%{
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
        ParticipationSupportAccess.issue(%{
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
      assert ParticipationSupportElevation.max_duration_seconds() == 86_400
    end
  end

  describe "AC-03 elevation expiry" do
    test "an elevation is valid strictly before its own expiry and invalid at or after it" do
      now = DateTime.utc_now()
      elevation = %ParticipationSupportElevation{revoked_at: nil, expires_at: now}

      assert ParticipationSupportElevation.valid_at?(elevation, DateTime.add(now, -1, :second))
      refute ParticipationSupportElevation.valid_at?(elevation, now)
      refute ParticipationSupportElevation.valid_at?(elevation, DateTime.add(now, 1, :second))
    end

    test "an already-expired grant denies a content read and is audited as expired" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:ok, elevation} =
        ParticipationSupportAccess.issue(%{
          operations_account_id: operations_account.id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :content,
          issued_at: DateTime.add(DateTime.utc_now(), -7200, :second),
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      refute ParticipationSupportElevation.valid_at?(elevation, DateTime.utc_now())

      log =
        capture_log(fn ->
          assert ParticipationSupportAccess.authorize_content_read(project.id, elevation.id) ==
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
               ParticipationSupportAccess.authorize_content_read(project.id, elevation.id)

      assert {:ok, revoked} = ParticipationSupportAccess.revoke(elevation.id, revoker.id)
      assert %DateTime{} = revoked.revoked_at
      assert revoked.revoked_by_account_id == revoker.id

      assert ParticipationSupportAccess.authorize_content_read(project.id, elevation.id) ==
               {:error, :unauthorized}
    end

    test "revoking an already-revoked elevation is refused rather than silently repeated" do
      %{elevation: elevation} = elevation_fixture()
      revoker = AccountsFixtures.account_fixture()

      assert {:ok, _revoked} = ParticipationSupportAccess.revoke(elevation.id, revoker.id)
      assert {:error, changeset} = ParticipationSupportAccess.revoke(elevation.id, revoker.id)
      assert %{revoked_at: ["is already recorded"]} = errors_on(changeset)
    end

    test "revoking an unknown elevation is refused" do
      revoker = AccountsFixtures.account_fixture()

      assert ParticipationSupportAccess.revoke(Ecto.UUID.generate(), revoker.id) ==
               {:error, :not_found}
    end
  end

  describe "AC-03 purpose validation" do
    test "the purpose vocabulary is closed" do
      assert ParticipationSupportAccess.purposes() == [
               :incident_diagnosis,
               :security_investigation
             ]
    end

    test "issuing refuses a purpose outside the closed vocabulary" do
      %{project: project} = joined()
      operations_account = AccountsFixtures.account_fixture()

      {:error, changeset} =
        ParticipationSupportAccess.issue(%{
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
        ParticipationSupportAccess.issue(%{
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

      for purpose <- ParticipationSupportAccess.purposes() do
        assert {:ok, elevation} =
                 ParticipationSupportAccess.issue(%{
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
            ParticipationSupportAccess.issue(%{
              operations_account_id: operations_account.id,
              project_id: project.id,
              purpose: :incident_diagnosis,
              scope: :content,
              expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
            })

          ParticipationSupportAccess.authorize_content_read(project.id, elevation.id)
          ParticipationSupportAccess.revoke(elevation.id, revoker.id)
        end)

      assert log =~ "[#{ParticipationSupportAudit.tag()}]"
      assert log =~ "event=issue"
      assert log =~ "event=authorize"
      assert log =~ "event=revoke"
      assert log =~ "outcome=granted"

      allowed = ParticipationSupportAudit.allowed_keys()

      for line <- String.split(log, "\n"),
          String.contains?(line, "[#{ParticipationSupportAudit.tag()}]") do
        [_prefix, payload] =
          String.split(line, "[#{ParticipationSupportAudit.tag()}] ", parts: 2)

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

    test "a call site cannot smuggle project content, a display name, or an email into the audit trail" do
      log =
        capture_log(fn ->
          ParticipationSupportAudit.event(:authorize, %{
            outcome: :granted,
            elevation_id: "abc-123",
            reason: :ok,
            project_name: "Secret Launch Project",
            display_name: "Jordan Participant",
            invitation_email: "person@example.com",
            invitation_credential_digest: "abc123digest"
          })
        end)

      assert log =~ "event=authorize"
      refute log =~ "Secret Launch Project"
      refute log =~ "Jordan Participant"
      refute log =~ "person@example.com"
      refute log =~ "abc123digest"
      refute log =~ "project_name"
      refute log =~ "display_name"
      refute log =~ "invitation_email"
      refute log =~ "invitation_credential_digest"
    end

    test "an issue rejected for invalid attributes is still audited, without content" do
      %{project: project} = joined()

      log =
        capture_log(fn ->
          ParticipationSupportAccess.issue(%{
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

  describe "AC-03 non-disclosure across every denial reason" do
    test "every denial reason — absent, malformed, wrong-project, metadata-only, expired, revoked — returns the identical result" do
      %{elevation: content_elevation, project: project} = elevation_fixture()
      %{project: other_project} = joined()

      {:ok, metadata_elevation} =
        ParticipationSupportAccess.issue(%{
          operations_account_id: AccountsFixtures.account_fixture().id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :metadata,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, expired_elevation} =
        ParticipationSupportAccess.issue(%{
          operations_account_id: AccountsFixtures.account_fixture().id,
          project_id: project.id,
          purpose: :incident_diagnosis,
          scope: :content,
          issued_at: DateTime.add(DateTime.utc_now(), -7200, :second),
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      %{elevation: to_revoke} = elevation_fixture()
      revoker = AccountsFixtures.account_fixture()
      {:ok, revoked_elevation} = ParticipationSupportAccess.revoke(to_revoke.id, revoker.id)

      absent =
        ParticipationSupportAccess.authorize_content_read(project.id, Ecto.UUID.generate())

      malformed = ParticipationSupportAccess.authorize_content_read(project.id, "not-a-uuid")

      wrong_project =
        ParticipationSupportAccess.authorize_content_read(
          other_project.id,
          content_elevation.id
        )

      metadata_only =
        ParticipationSupportAccess.authorize_content_read(project.id, metadata_elevation.id)

      expired =
        ParticipationSupportAccess.authorize_content_read(project.id, expired_elevation.id)

      revoked =
        ParticipationSupportAccess.authorize_content_read(project.id, revoked_elevation.id)

      results = [absent, malformed, wrong_project, metadata_only, expired, revoked]

      assert Enum.uniq(results) == [{:error, :unauthorized}]
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

    Map.merge(result, %{identity: identity})
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

    {:ok, elevation} = ParticipationSupportAccess.issue(attrs)

    %{elevation: elevation, project: project, operations_account: operations_account}
  end
end
