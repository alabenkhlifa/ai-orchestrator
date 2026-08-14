defmodule SddOrchestrator.Privacy.ParticipationContentBoundaryTest do
  @moduledoc """
  Proof for specs/26 Task 4 (AC-04): participation data crossing a
  persistence, notification, delivery, support, logging, export, or
  processor boundary has credentials, secrets, unauthorized project content,
  out-of-context participant emails, and unrelated identities rejected or
  removed before the boundary is crossed.

  This file proves three things: the new shared detector
  (`ParticipationContentBoundary`) works correctly on its own closed
  vocabulary; the real participation write paths it complements
  (`ParticipationEmail`, `ProjectNotifications`, `Invitations`,
  `ProjectMemberProfile`) carry no credential or out-of-context email in
  their real approved output; and the destination-allowlist check is
  cross-referenced against the real, already-approved
  `ParticipationProcessingInventory` (specs/26 Task 1) rather than a second
  hand-written copy of it.

  One real gap is documented rather than fixed here (out of this task's
  scope: `lib/sdd_orchestrator/participation/` is read-only for this task):
  `SddOrchestrator.Participation.DisplayName.normalize/1` rejects an
  email-shaped display name but places no credential scan on it, unlike the
  free-text boundaries specs/18 already guards. The "display name" tests
  below prove the real (unmodified) `DisplayName`/`ProjectMemberProfile`
  boundary accepts a credential-shaped label as-is, and that the new shared
  detector would have caught it.
  """
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Accounts.HostedIdentity

  alias SddOrchestrator.Participation.{
    DisplayName,
    Invitations,
    ParticipationEmail,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectNotifications
  }

  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures

  alias SddOrchestrator.Privacy.{
    ParticipationContentBoundary,
    ParticipationContentBoundaryAudit,
    ParticipationProcessingInventory,
    ParticipationSupportAudit
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @credentials [
    "use sk-abcdefghijklmnopqrstuvwxyz012345",
    "token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "github_pat_11ABCDEFG0abcdefghijklmnop",
    "-----BEGIN RSA PRIVATE KEY-----",
    "key AKIAIOSFODNN7EXAMPLE"
  ]

  @emails [
    "ask alex@example.com about this",
    "contact ops-team@sdd-orchestrator.example for help"
  ]

  @credential_label "sk-abcdefghijklmnopqrstuvwxyz012345"

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

  describe "credential detection" do
    test "flags every mirrored secret shape in free text" do
      for text <- @credentials do
        assert ParticipationContentBoundary.scan_text(text) == {:error, :credential_detected}
      end
    end

    test "flags a forbidden key name nested inside a structure" do
      for key <- ParticipationContentBoundary.credential_keys() do
        nested = %{"outer" => %{key => "placeholder"}}

        assert ParticipationContentBoundary.scan_structure(nested) ==
                 {:error, :credential_detected}
      end
    end

    test "flags a PEM block or secret-shaped string embedded deep inside a list" do
      value = %{"events" => [%{"note" => "fine"}, %{"note" => "-----BEGIN RSA PRIVATE KEY-----"}]}

      assert ParticipationContentBoundary.scan_structure(value) == {:error, :credential_detected}
    end

    test "passes ordinary prose and structures with no credential shape" do
      assert ParticipationContentBoundary.scan_text("Ready to join the project.") == :ok
      assert ParticipationContentBoundary.scan_structure(%{"summary" => "Invitation sent"}) == :ok
    end
  end

  describe "email detection" do
    test "flags a plain email address in free text" do
      for text <- @emails do
        assert ParticipationContentBoundary.scan_text(text) == {:error, :email_detected}
      end
    end

    test "flags an email nested inside a structure" do
      nested = %{"cc" => ["reviewer@example.com"]}
      assert ParticipationContentBoundary.scan_structure(nested) == {:error, :email_detected}
    end

    test "passes text with no email shape" do
      assert ParticipationContentBoundary.scan_text("You joined the project.") == :ok
    end
  end

  describe "destination allowlist: real ParticipationProcessingInventory cross-reference" do
    test "the two fields classified for the configured email-delivery processor authorize exactly that destination" do
      assert ParticipationContentBoundary.authorize_destination(
               :project_invitation,
               :delivery_email,
               :email_delivery_provider
             ) == :ok

      assert ParticipationContentBoundary.authorize_destination(
               :participation_email_delivery,
               :recipient_address,
               :email_delivery_provider
             ) == :ok
    end

    test "every other classified field authorizes only the hosted database, never the email-delivery processor" do
      for record <- ParticipationProcessingInventory.records(),
          record.processor_category != :email_delivery_provider do
        assert ParticipationContentBoundary.authorize_destination(
                 record.entity,
                 record.field,
                 :hosted_database
               ) == :ok

        assert ParticipationContentBoundary.authorize_destination(
                 record.entity,
                 record.field,
                 :email_delivery_provider
               ) == {:error, :unapproved_destination}
      end
    end

    test "the invitation's own credential-verification fields never authorize the email-delivery destination" do
      for field <- [:email_digest, :token_digest, :token_salt] do
        assert ParticipationContentBoundary.authorize_destination(
                 :project_invitation,
                 field,
                 :email_delivery_provider
               ) == {:error, :unapproved_destination}

        assert ParticipationContentBoundary.authorize_destination(
                 :project_invitation,
                 field,
                 :hosted_database
               ) == :ok
      end
    end

    test "an unclassified field is refused rather than silently allowed" do
      assert ParticipationContentBoundary.authorize_destination(
               :project_invitation,
               :not_a_real_field,
               :hosted_database
             ) == {:error, :unclassified_field}

      assert ParticipationContentBoundary.authorize_destination(
               :not_a_real_entity,
               :id,
               :hosted_database
             ) == {:error, :unclassified_field}
    end

    test "processor_category and transfer_classification co-vary for every inventoried record" do
      for record <- ParticipationProcessingInventory.records() do
        case record.processor_category do
          :hosted_database ->
            assert record.transfer_classification == :no_transfer

          :email_delivery_provider ->
            assert record.transfer_classification == :configured_email_delivery
        end
      end
    end
  end

  describe "real notification payloads: no credential or out-of-context email in any approved participation.* event" do
    test "every approved event's exact field allowlist and safe link still hold" do
      for event <- in_product_events() do
        assert Enum.sort(Map.keys(event)) ==
                 event.event_type |> ProjectNotifications.payload_fields() |> Enum.sort()

        assert :ok = ProjectNotifications.validate_payload(event)
      end
    end

    test "title, body, project_label, and actor_label carry no credential or email shape" do
      for event <- in_product_events(),
          field <- [:title, :body, :project_label, :actor_label],
          value = Map.get(event, field),
          is_binary(value) do
        assert ParticipationContentBoundary.scan_text(value, to_string(field)) == :ok
      end
    end

    test "scanning the whole presentable slice of a real event structurally also passes" do
      for event <- in_product_events() do
        presentable = Map.take(event, [:title, :body, :project_label, :actor_label, :link_path])
        assert ParticipationContentBoundary.scan_structure(presentable) == :ok
      end
    end

    test "the shared detector still catches a credential or email injected into a notification body" do
      assert ParticipationContentBoundary.scan_text(
               "contact alex@example.com about this",
               "notification_body"
             ) == {:error, :email_detected}

      assert ParticipationContentBoundary.scan_text(
               "token #{@credential_label}",
               "notification_body"
             ) == {:error, :credential_detected}
    end
  end

  describe "real email payloads: no credential or out-of-context email in the built message subject/body" do
    test "every approved participation email's subject and body carry no credential or unrelated-email shape" do
      invitation_id = Ecto.UUID.generate()
      url = ParticipationEmail.invitation_url(invitation_id, "INVITATION-TOKEN")

      contexts = [
        invitation: %{recipient: "invitee@example.com", project_label: "Roadmap", url: url},
        invitation_resent: %{recipient: "invitee@example.com", project_label: "Roadmap", url: url},
        invitation_canceled: %{recipient: "invitee@example.com", project_label: "Roadmap"},
        participant_removed: %{recipient: "invitee@example.com", project_label: "Roadmap"}
      ]

      for {event, context} <- contexts do
        assert {:ok, email} = ParticipationEmail.build(event, context)
        assert ParticipationContentBoundary.scan_text(email.subject, "email_subject") == :ok
        assert ParticipationContentBoundary.scan_text(email.text_body, "email_body") == :ok
      end
    end
  end

  describe "negative persistence and transmission scan: the raw invitation credential stays out of every other field" do
    test "the raw pre-digest token appears only in the invitation's own message, never in a later message, an event, or the stored row" do
      %{project: project, account: account} = owned_project()

      {:ok, %{invitation: invitation}} =
        Invitations.create(project, account.id, "invitee@example.com")

      assert_received {:participation_email, created}
      [_, first_token] = Regex.run(~r/token=([A-Za-z0-9_-]+)/, created.text_body)

      {:ok, _resent} = Invitations.resend(project, account.id, "invitee@example.com")
      assert_received {:participation_email, resent}
      [_, second_token] = Regex.run(~r/token=([A-Za-z0-9_-]+)/, resent.text_body)

      refute first_token == second_token

      # Before cancellation, the stored row holds only the credential's
      # digest and salt — never the raw token — and that digest is never
      # classified for the email-delivery destination.
      still_pending = Repo.get!(ProjectInvitation, invitation.id)
      refute is_nil(still_pending.token_digest)
      refute still_pending.token_digest == first_token
      refute still_pending.token_digest == second_token

      assert ParticipationContentBoundary.authorize_destination(
               :project_invitation,
               :token_digest,
               :email_delivery_provider
             ) == {:error, :unapproved_destination}

      {:ok, _canceled} = Invitations.cancel(project, account.id, "invitee@example.com")
      assert_received {:participation_email, canceled}

      for token <- [first_token, second_token] do
        refute canceled.text_body =~ token
      end

      assert ParticipationContentBoundary.scan_text(canceled.text_body, "email_body") == :ok

      # No approved notification event ever carries the raw credential.
      for event <- in_product_events() do
        serialized = inspect(event)

        for token <- [first_token, second_token] do
          refute serialized =~ token
        end
      end

      # Cancellation erases the credential material immediately: the digest
      # and salt are gone, not merely unreachable.
      canceled_row = Repo.get!(ProjectInvitation, invitation.id)
      assert is_nil(canceled_row.token_digest)
      assert is_nil(canceled_row.token_salt)
    end
  end

  describe "typed credential rejection: the DisplayName gap, demonstrated against real product code" do
    test "DisplayName.normalize/1 accepts a credential-shaped label as-is (documented, unmodified specs/25 behavior)" do
      assert {:ok, %{display_name: @credential_label}} = DisplayName.normalize(@credential_label)
    end

    test "the shared detector would have caught it before the label crosses a persistence boundary" do
      assert ParticipationContentBoundary.scan_text(@credential_label, "display_name") ==
               {:error, :credential_detected}
    end

    test "a real ProjectMemberProfile changeset accepts and would persist the credential-shaped label" do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      changeset =
        ProjectMemberProfile.changeset(%ProjectMemberProfile{}, %{
          project_id: project.id,
          account_id: account.id,
          role: "owner",
          display_name: @credential_label
        })

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :display_name)

      {:ok, profile} = Repo.insert(changeset)
      assert profile.display_name == @credential_label
    end

    test "an email-shaped label is already rejected by the real, unmodified boundary" do
      assert DisplayName.normalize("someone@example.com") == {:error, :invalid_display_name}
    end
  end

  describe "AC-04 support boundary: Task 3's allowlist already satisfies content minimization" do
    test "the participation support audit allowlist carries no project content, participant email, or credential field" do
      allowed = ParticipationSupportAudit.allowed_keys()

      forbidden = ~w(
        project_name display_name invitation_email participant_email
        credential token_digest token_salt email_digest
      )a

      for key <- forbidden do
        refute key in allowed
      end
    end
  end

  describe "typed refusal result vocabulary" do
    test "every refusal returns exactly one of the four closed atoms" do
      assert {:error, :credential_detected} =
               ParticipationContentBoundary.scan_text(hd(@credentials))

      assert {:error, :email_detected} = ParticipationContentBoundary.scan_text(hd(@emails))

      assert {:error, :unclassified_field} =
               ParticipationContentBoundary.authorize_destination(
                 :no_entity,
                 :no_field,
                 :hosted_database
               )

      assert {:error, :unapproved_destination} =
               ParticipationContentBoundary.authorize_destination(
                 :project_invitation,
                 :token_digest,
                 :email_delivery_provider
               )
    end
  end

  describe "diagnostic logging is field-name-only, never content" do
    test "a credential refusal logs the check and field name, never the matched secret" do
      secret = hd(@credentials)

      log =
        capture_log(fn ->
          assert ParticipationContentBoundary.scan_text(secret, "display_name") ==
                   {:error, :credential_detected}
        end)

      assert log =~ "check=credential_detected"
      assert log =~ "field=display_name"
      refute log =~ secret
      refute log =~ @credential_label
    end

    test "an email refusal logs the check and field name, never the matched address" do
      email_text = hd(@emails)

      log =
        capture_log(fn ->
          assert ParticipationContentBoundary.scan_text(email_text, "notification_body") ==
                   {:error, :email_detected}
        end)

      assert log =~ "check=email_detected"
      assert log =~ "field=notification_body"
      refute log =~ "alex@example.com"
    end

    test "a destination refusal logs the check and the entity.field name, never the record's other content" do
      log =
        capture_log(fn ->
          assert ParticipationContentBoundary.authorize_destination(
                   :project_invitation,
                   :token_digest,
                   :email_delivery_provider
                 ) == {:error, :unapproved_destination}
        end)

      assert log =~ "check=unapproved_destination"
      assert log =~ "field=project_invitation.token_digest"
    end
  end

  describe "audit trail" do
    test "every emitted line carries only allowlisted keys" do
      log =
        capture_log(fn ->
          ParticipationContentBoundary.scan_text(hd(@credentials), "display_name")
          ParticipationContentBoundary.scan_text(hd(@emails), "notification_body")

          ParticipationContentBoundary.authorize_destination(
            :project_invitation,
            :token_digest,
            :email_delivery_provider
          )
        end)

      allowed = ParticipationContentBoundaryAudit.allowed_keys()

      for line <- String.split(log, "\n"),
          String.contains?(line, "[#{ParticipationContentBoundaryAudit.tag()}]") do
        [_prefix, payload] =
          String.split(line, "[#{ParticipationContentBoundaryAudit.tag()}] ", parts: 2)

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
          ParticipationContentBoundaryAudit.event(:refused, %{
            check: :credential_detected,
            field: "display_name",
            outcome: :rejected,
            project_name: "Secret Launch Project",
            display_name_content: "the participant's real name #{@credential_label}",
            participant_email: "person@example.com"
          })
        end)

      assert log =~ "check=credential_detected"
      refute log =~ "Secret Launch Project"
      refute log =~ "real name"
      refute log =~ "person@example.com"
      refute log =~ "project_name"
      refute log =~ "display_name_content"
      refute log =~ "participant_email"
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

  defp in_product_events do
    project = %Project{id: Ecto.UUID.generate(), name: "Roadmap"}
    owner = %{account_id: Ecto.UUID.generate()}
    identity = %HostedIdentity{account_id: Ecto.UUID.generate()}

    profile = %ProjectMemberProfile{
      id: Ecto.UUID.generate(),
      display_name: "Member Label"
    }

    occurred_at = DateTime.utc_now() |> DateTime.truncate(:second)

    invitation = %ProjectInvitation{
      id: Ecto.UUID.generate(),
      credential_version: 2,
      terminal_at: occurred_at
    }

    revocation = %{
      id: Ecto.UUID.generate(),
      contract_version: 1,
      former_account_id: identity.account_id,
      owner_account_id: owner.account_id,
      last_display_name: "Member Label",
      occurred_at: occurred_at
    }

    [
      ProjectNotifications.invitation_expired_event(project, invitation, owner),
      ProjectNotifications.acceptance_participant_event(project, profile, identity),
      ProjectNotifications.acceptance_owner_event(project, profile, owner),
      ProjectNotifications.decline_owner_event(project, invitation, owner),
      ProjectNotifications.removal_event(project, revocation),
      ProjectNotifications.leave_event(project, revocation)
    ]
  end
end
