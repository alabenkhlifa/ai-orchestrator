defmodule SddOrchestrator.Participation.EmailDeliveryTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Participation.{
    EmailDelivery,
    ParticipationEmail,
    ParticipationEmailDelivery
  }

  alias SddOrchestrator.ParticipationDeliveryDouble

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

  describe "builders" do
    test "build the four approved messages with minimum context and a safe link" do
      url = ParticipationEmail.invitation_url(Ecto.UUID.generate(), "raw-token")

      assert {:ok, invitation} =
               ParticipationEmail.build(:invitation, context(%{url: url}))

      assert {:ok, resent} = ParticipationEmail.build(:invitation_resent, context(%{url: url}))
      assert {:ok, canceled} = ParticipationEmail.build(:invitation_canceled, context())
      assert {:ok, removed} = ParticipationEmail.build(:participant_removed, context())

      for email <- [invitation, resent, canceled, removed] do
        assert email.to == [{"", "invitee@example.com"}]
        assert email.subject =~ "Roadmap"
        assert email.text_body =~ "Roadmap"
      end

      assert invitation.text_body =~ url
      assert resent.text_body =~ url
      refute canceled.text_body =~ "token"
      refute removed.text_body =~ "token"

      assert ParticipationEmail.events() ==
               ~w(invitation invitation_resent invitation_canceled participant_removed)a
    end

    test "carry no project content, other identity, or account-existence signal" do
      url = ParticipationEmail.invitation_url(Ecto.UUID.generate(), "raw-token")
      {:ok, email} = ParticipationEmail.build(:invitation, context(%{url: url}))

      body = email.text_body <> email.subject

      for forbidden <- [
            "requirements",
            "design.md",
            "specification",
            "evidence",
            "repository",
            "already has an account",
            "new account",
            "owner@example.com"
          ] do
        refute String.downcase(body) =~ String.downcase(forbidden)
      end
    end

    test "reject an unsupported event and a message that needs a missing link" do
      assert {:error, :unsupported_event} = ParticipationEmail.build(:newsletter, context())
      assert {:error, :missing_invitation_url} = ParticipationEmail.build(:invitation, context())
      assert {:error, :invalid_context} = ParticipationEmail.build(:invitation_canceled, %{})
    end
  end

  describe "deliver/2" do
    test "records one minimized sent outcome" do
      subject_ref = Ecto.UUID.generate()
      url = ParticipationEmail.invitation_url(subject_ref, "raw-token")

      assert {:ok, delivery} =
               EmailDelivery.deliver(
                 :invitation,
                 context(%{subject_ref: subject_ref, url: url})
               )

      assert_received {:participation_email, email}
      assert email.text_body =~ url

      assert delivery.status == "sent"
      assert delivery.event_type == "invitation"
      assert delivery.subject_ref == subject_ref
      assert delivery.event_version == 1
      assert delivery.delivered_at
      assert is_nil(delivery.failure_code)
      assert ParticipationEmailDelivery.sent?(delivery)
      assert EmailDelivery.result(:invitation, subject_ref).id == delivery.id
    end

    test "stores the recipient address encrypted and out of struct inspection" do
      subject_ref = Ecto.UUID.generate()
      url = ParticipationEmail.invitation_url(subject_ref, "raw-token")

      {:ok, delivery} =
        EmailDelivery.deliver(:invitation, context(%{subject_ref: subject_ref, url: url}))

      assert delivery.recipient_address == "invitee@example.com"
      refute inspect(delivery) =~ "invitee@example.com"

      %{rows: [[stored]]} =
        Repo.query!(
          "SELECT recipient_address FROM participation_email_deliveries WHERE id = $1",
          [
            Ecto.UUID.dump!(delivery.id)
          ]
        )

      refute stored =~ "invitee@example.com"
      assert is_binary(stored)
    end

    test "keeps one record per event, subject, and version across retries" do
      subject_ref = Ecto.UUID.generate()
      url = ParticipationEmail.invitation_url(subject_ref, "raw-token")
      attrs = context(%{subject_ref: subject_ref, url: url})

      ParticipationDeliveryDouble.fail_next()

      assert capture_log(fn ->
               assert {:ok, failed} = EmailDelivery.deliver(:invitation, attrs)
               assert failed.status == "failed"
               assert failed.failure_code == "delivery_failed"
               assert is_nil(failed.delivered_at)
             end) =~ "participation_email_delivery_failed"

      ParticipationDeliveryDouble.succeed()

      assert {:ok, retried} = EmailDelivery.deliver(:invitation, attrs)
      assert retried.status == "sent"
      assert is_nil(retried.failure_code)
      assert retried.delivered_at

      assert Repo.aggregate(ParticipationEmailDelivery, :count) == 1

      # A later invitation version for the same subject records its own outcome.
      assert {:ok, _resent} =
               EmailDelivery.deliver(:invitation_resent, Map.put(attrs, :event_version, 2))

      assert Repo.aggregate(ParticipationEmailDelivery, :count) == 2
    end

    test "records a provider crash as a minimized failure without leaking details" do
      subject_ref = Ecto.UUID.generate()
      url = ParticipationEmail.invitation_url(subject_ref, "raw-token")
      ParticipationDeliveryDouble.fail_next(:raise)

      log =
        capture_log(fn ->
          assert {:ok, delivery} =
                   EmailDelivery.deliver(
                     :invitation,
                     context(%{subject_ref: subject_ref, url: url})
                   )

          assert delivery.status == "failed"
          assert delivery.failure_code == "provider_unavailable"
        end)

      assert log =~ "participation_email_delivery_failed"
      refute log =~ "invitee@example.com"
      refute log =~ "raw-token"
      refute log =~ "provider exploded"
    end

    test "rejects an unbuildable message before recording an attempt" do
      assert {:error, :missing_invitation_url} =
               EmailDelivery.deliver(:invitation, context(%{subject_ref: Ecto.UUID.generate()}))

      assert {:error, :invalid_context} = EmailDelivery.deliver(:invitation, %{})
      assert Repo.aggregate(ParticipationEmailDelivery, :count) == 0
    end
  end

  describe "diagnostic minimization" do
    test "the schema stores no credential, body, or provider response column" do
      fields = ParticipationEmailDelivery.__schema__(:fields) |> Enum.sort()

      assert fields == [
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

      assert ParticipationEmailDelivery.failure_codes() ==
               ~w(delivery_failed invalid_recipient provider_unavailable)
    end

    test "the shared transport module is the default and stays configurable" do
      Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      assert EmailDelivery.transport() == SddOrchestrator.HostedAccess.SwooshDelivery

      Application.put_env(
        :sdd_orchestrator,
        :participation_email_delivery,
        ParticipationDeliveryDouble
      )

      assert EmailDelivery.transport() == ParticipationDeliveryDouble
    end
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{recipient: "invitee@example.com", project_label: "Roadmap"},
      overrides
    )
  end
end
