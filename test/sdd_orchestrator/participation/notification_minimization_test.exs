defmodule SddOrchestrator.Participation.NotificationMinimizationTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Accounts.HostedIdentity
  alias SddOrchestrator.Notifications.AccountNotification

  alias SddOrchestrator.Participation.{
    EmailDelivery,
    ParticipationEmail,
    ParticipationEmailDelivery,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectNotifications
  }

  alias SddOrchestrator.Projects.Project

  @forbidden_context [
    specification_content: "SPECIFICATION-CONTENT-SENTINEL",
    feature_content: "FEATURE-CONTENT-SENTINEL",
    comment_content: "COMMENT-CONTENT-SENTINEL",
    evidence_content: "EVIDENCE-CONTENT-SENTINEL",
    repository: "REPOSITORY-DETAIL-SENTINEL",
    credential: "CREDENTIAL-SENTINEL",
    secret: "SECRET-SENTINEL",
    unrelated_identity: "unrelated@example.com"
  ]
  @forbidden_values Keyword.values(@forbidden_context)

  test "every in-product event has its exact field allowlist and event-specific safe link" do
    events = in_product_events()

    assert Enum.map(events, & &1.event_type) |> Enum.sort() ==
             ~w(
               participation.invitation_declined
               participation.invitation_expired
               participation.joined
               participation.left
               participation.participant_joined
               participation.removed
             )

    for event <- events do
      assert Enum.sort(Map.keys(event)) ==
               event.event_type |> ProjectNotifications.payload_fields() |> Enum.sort()

      assert :ok = ProjectNotifications.validate_payload(event)

      serialized = inspect(event)

      for forbidden <- @forbidden_values do
        refute serialized =~ forbidden
      end
    end

    assert Enum.find(events, &(&1.event_type == "participation.joined")).link_path =~
             ~r{\A/projects/[0-9a-f-]+\z}

    assert Enum.find(events, &(&1.event_type == "participation.removed")).link_path ==
             "/hosted/access/sessions"

    for event <-
          Enum.reject(events, &(&1.event_type in ~w(participation.joined participation.removed))) do
      assert event.link_path =~ ~r{\A/projects/[0-9a-f-]+/participation\z}
    end
  end

  test "in-product policy rejects extra context, unsafe links, and unsupported events" do
    event = Enum.find(in_product_events(), &(&1.event_type == "participation.joined"))

    for {field, value} <- @forbidden_context do
      assert {:error, :unapproved_fields} =
               event
               |> Map.put(field, value)
               |> ProjectNotifications.validate_payload()
    end

    assert {:error, :unapproved_content} =
             event
             |> Map.put(:body, "SPECIFICATION-CONTENT-SENTINEL")
             |> ProjectNotifications.validate_payload()

    assert {:error, :unsafe_link} =
             event
             |> Map.put(:link_path, "https://example.com/projects/#{event.subject_ref}")
             |> ProjectNotifications.validate_payload()

    assert {:error, :unsafe_link} =
             event
             |> Map.put(:link_path, event.link_path <> "?credential=SECRET-SENTINEL")
             |> ProjectNotifications.validate_payload()

    assert {:error, :unsupported_event} =
             event
             |> Map.put(:event_type, "participation.unsupported")
             |> ProjectNotifications.validate_payload()
  end

  test "every email template accepts only its approved recipient context" do
    invitation_id = Ecto.UUID.generate()
    invitation_url = ParticipationEmail.invitation_url(invitation_id, "INVITATION-TOKEN")

    contexts = [
      invitation: email_context(%{url: invitation_url}),
      invitation_resent: email_context(%{url: invitation_url}),
      invitation_canceled: email_context(),
      participant_removed: email_context()
    ]

    for {event, context} <- contexts do
      assert Enum.sort(Map.keys(context)) ==
               event |> ParticipationEmail.context_fields() |> Enum.sort()

      assert {:ok, email} = ParticipationEmail.build(event, context)
      assert email.to == [{"", "invitee@example.com"}]
      assert email.subject =~ "Roadmap"
      assert email.text_body =~ "Roadmap"

      serialized = email.subject <> email.text_body

      for forbidden <- @forbidden_values do
        refute serialized =~ forbidden
      end
    end

    assert EmailDelivery.context_fields(:invitation) == [
             :subject_ref,
             :event_version,
             :recipient,
             :project_label,
             :url
           ]
  end

  test "email policy rejects unapproved context and links outside the product" do
    invitation_id = Ecto.UUID.generate()
    safe_url = ParticipationEmail.invitation_url(invitation_id, "INVITATION-TOKEN")

    for {field, value} <- @forbidden_context do
      context = email_context(%{url: safe_url}) |> Map.put(field, value)
      assert {:error, :unapproved_context} = ParticipationEmail.build(:invitation, context)
    end

    assert {:error, :unapproved_context} =
             EmailDelivery.deliver(:invitation, %{
               subject_ref: invitation_id,
               recipient: "invitee@example.com",
               project_label: "Roadmap",
               url: safe_url,
               repository: "REPOSITORY-DETAIL-SENTINEL"
             })

    for unsafe_url <- [
          "https://example.com/projects/invitations/#{invitation_id}/accept?token=x",
          safe_url <> "&secret=SECRET-SENTINEL",
          safe_url <> "#credential=CREDENTIAL-SENTINEL",
          String.replace(safe_url, "token=INVITATION-TOKEN", "not_token=x")
        ] do
      assert {:error, :unsafe_invitation_url} =
               ParticipationEmail.build(:invitation, email_context(%{url: unsafe_url}))
    end

    assert {:error, :unapproved_context} =
             ParticipationEmail.build(
               :participant_removed,
               email_context(%{url: safe_url})
             )
  end

  test "delivery records have no content, link, credential, secret, or unrelated identity field" do
    assert AccountNotification.__schema__(:fields) |> Enum.sort() == [
             :account_id,
             :actor_label,
             :body,
             :event_type,
             :event_version,
             :id,
             :inserted_at,
             :link_path,
             :occurred_at,
             :project_label,
             :read_at,
             :subject_ref,
             :title,
             :updated_at
           ]

    assert ParticipationEmailDelivery.__schema__(:fields) |> Enum.sort() == [
             :attempted_at,
             :delivered_at,
             :event_type,
             :event_version,
             :failure_code,
             :id,
             :inserted_at,
             :recipient_address,
             :status,
             :subject_ref,
             :updated_at
           ]
  end

  defp in_product_events do
    project = %Project{id: Ecto.UUID.generate(), name: "Roadmap"}
    owner = %{account_id: Ecto.UUID.generate()}
    identity = %HostedIdentity{account_id: Ecto.UUID.generate()}
    profile = %ProjectMemberProfile{id: Ecto.UUID.generate(), display_name: "Member Label"}
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

  defp email_context(overrides \\ %{}) do
    Map.merge(%{recipient: "invitee@example.com", project_label: "Roadmap"}, overrides)
  end
end
