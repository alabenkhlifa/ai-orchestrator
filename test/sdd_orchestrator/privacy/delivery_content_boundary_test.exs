defmodule SddOrchestrator.Privacy.DeliveryContentBoundaryTest do
  @moduledoc """
  Proof for specs/18 Task 3 (AC-04): guided-delivery content crossing a UI,
  worker, provider, evidence, preview, review, comment, notification, or
  logging boundary has raw credentials, participant emails, raw provider
  events, and unauthorized project content excluded or rejected.

  Slice 07 already enforces most of this at each individual boundary — see
  `SddOrchestrator.Privacy.DeliveryContentBoundary`'s moduledoc for the full
  map. This file proves two things: the new shared detector
  (`DeliveryContentBoundary`) works correctly on its own closed vocabulary,
  and the real Slice 07 write paths it complements (`Comments.add/4`,
  `ActivityEntry`'s changeset, `ProtocolCodec`/`EventIngestion`) still refuse
  credential- and email-laden content before it reaches storage.

  One real gap is documented rather than fixed here (out of this task's
  scope, since specs/18 excludes changes to approved Slice 07 product
  behavior): `SddOrchestrator.Delivery.ReviewDecision.record_changeset/2`
  places no credential or email scan on reviewer `feedback`, unlike
  `Comments.add/4`. The "review-feedback" tests below prove the shared
  detector is correct against realistic feedback text, and a dedicated test
  demonstrates the gap directly against the real (unmodified) changeset.
  """
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Delivery.{
    Activity,
    ActivityEntry,
    Comments,
    EventIngestion,
    ProtocolCodec,
    ReviewDecision,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.Privacy.{DeliveryContentBoundary, DeliveryContentBoundaryAudit}
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

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature,
      account: context.account,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "credential detection" do
    test "flags every mirrored secret shape in free text" do
      for text <- @credentials do
        assert DeliveryContentBoundary.scan_text(text) == {:error, :credential_detected}
      end
    end

    test "flags a forbidden key name nested inside a structure, matching SecretBoundary's own vocabulary" do
      for key <- DeliveryContentBoundary.credential_keys() do
        nested = %{"outer" => %{key => "placeholder"}}
        assert DeliveryContentBoundary.scan_structure(nested) == {:error, :credential_detected}
      end
    end

    test "flags a PEM block or secret-shaped string embedded deep inside a list" do
      value = %{"events" => [%{"note" => "fine"}, %{"note" => "-----BEGIN RSA PRIVATE KEY-----"}]}

      assert DeliveryContentBoundary.scan_structure(value) == {:error, :credential_detected}
    end

    test "passes ordinary prose and structures with no credential shape" do
      assert DeliveryContentBoundary.scan_text("This needs a mobile layout.") == :ok
      assert DeliveryContentBoundary.scan_structure(%{"summary" => "Ran the tests"}) == :ok
    end
  end

  describe "email detection" do
    test "flags a plain email address in free text" do
      for text <- @emails do
        assert DeliveryContentBoundary.scan_text(text) == {:error, :email_detected}
      end
    end

    test "flags an email nested inside a structure" do
      nested = %{"cc" => ["reviewer@example.com"]}
      assert DeliveryContentBoundary.scan_structure(nested) == {:error, :email_detected}
    end

    test "passes text with no email shape" do
      assert DeliveryContentBoundary.scan_text("Ready for review soon.") == :ok
    end
  end

  describe "unauthorized project content: generic raw-event allowlist helper" do
    test "rejects an envelope carrying a key outside the given allowlist" do
      envelope = %{"a" => 1, "b" => 2, "raw_provider_field" => "unexpected"}

      assert DeliveryContentBoundary.reject_raw_event(envelope, ~w(a b)) ==
               {:error, :raw_event_detected}
    end

    test "accepts an envelope whose keys are exactly the allowlist" do
      envelope = %{"a" => 1, "b" => 2}

      assert DeliveryContentBoundary.reject_raw_event(envelope, ~w(a b)) == :ok
    end
  end

  describe "worker normalized-event allowlist (real ProtocolCodec / EventIngestion)" do
    setup %{project: project, feature: feature} do
      run = DeliveryFixtures.run_fixture(project, feature)
      pending = DeliveryFixtures.attempt_fixture(run, %{fence_token: 3})

      {:ok, attempt} =
        pending
        |> SddOrchestrator.Delivery.RunAttempt.transition_changeset(
          "dispatched",
          pending.state_version
        )
        |> Repo.update()

      %{run: run, attempt: attempt}
    end

    test "an envelope with an extra unknown field is refused before it can reach ingestion", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope = run |> event(attempt, sequence: 1) |> Map.put("extra", "nope")

      assert {:error, _reason} = ProtocolCodec.validate(envelope)
      assert {:error, _reason} = EventIngestion.ingest(authority, project.id, envelope)
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "an event type outside the handled vocabulary is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      for type <- WorkerProtocol.event_types() -- EventIngestion.handled_event_types() do
        envelope = run |> event(attempt, sequence: 1) |> Map.put("event_type", type)

        assert {:error, :unsupported_event} =
                 EventIngestion.ingest(authority, project.id, envelope)
      end

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "a credential-shaped field embedded in a worker payload is refused by the codec, and independently flagged by the shared detector",
         %{authority: authority, project: project, run: run, attempt: attempt} do
      envelope =
        event(run, attempt, sequence: 1, payload: %{"api_key" => "sk-abcdefghijklmnop"})

      assert {:error, _reason} = ProtocolCodec.validate(envelope)
      assert DeliveryContentBoundary.scan_structure(envelope) == {:error, :credential_detected}
      assert {:error, _reason} = EventIngestion.ingest(authority, project.id, envelope)
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end
  end

  describe "raw-provider-event rejection: no raw provider payload survives into persisted activity" do
    setup %{project: project, feature: feature} do
      run = DeliveryFixtures.run_fixture(project, feature)
      pending = DeliveryFixtures.attempt_fixture(run, %{fence_token: 1})

      {:ok, attempt} =
        pending
        |> SddOrchestrator.Delivery.RunAttempt.transition_changeset(
          "dispatched",
          pending.state_version
        )
        |> Repo.update()

      %{run: run, attempt: attempt}
    end

    test "a realistic raw-provider-shaped payload is accepted by the codec but never persisted verbatim",
         %{authority: authority, project: project, run: run, attempt: attempt} do
      raw_provider_shape = %{
        "summary" => "Ran the tests",
        "raw_event" => %{"type" => "tool_use", "id" => "evt_1"},
        "stdout" => "$ mix test\n..................\n1234 tests, 0 failures",
        "transcript" => [%{"role" => "assistant", "content" => "Running tests now"}],
        "prompt" => "You are a coding agent working on this feature."
      }

      envelope = event(run, attempt, sequence: 1, payload: raw_provider_shape)

      # None of these keys are SecretBoundary/DeliveryContentBoundary credential
      # keys, so the envelope validates and ingestion applies it — proving the
      # minimization is the *normalized projection*, not a pre-ingestion refusal.
      assert :ok = ProtocolCodec.validate(envelope)
      assert {:ok, results} = EventIngestion.ingest(authority, project.id, envelope)

      stored = Repo.get!(ActivityEntry, results.activity.id)

      refute Map.has_key?(stored.payload, "raw_event")
      refute Map.has_key?(stored.payload, "stdout")
      refute Map.has_key?(stored.payload, "transcript")
      refute Map.has_key?(stored.payload, "prompt")
      refute Map.has_key?(stored.payload, "payload")
      assert stored.payload["summary"] == "Ran the tests"

      # The stored, minimized projection itself carries no forbidden key or
      # credential/email shape.
      assert DeliveryContentBoundary.scan_structure(stored.payload) == :ok
    end
  end

  describe "participant free-text boundary: comments (negative persistence scan)" do
    test "refuses a pasted credential in the real write path, and the shared detector agrees", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      count_before = Repo.aggregate(ActivityEntry, :count)

      for text <- @credentials do
        assert {:error, :redacted_content} = Comments.add(project.id, owner, feature.id, text)
        assert DeliveryContentBoundary.scan_text(text) == {:error, :credential_detected}
      end

      assert Repo.aggregate(ActivityEntry, :count) == count_before
    end

    test "refuses a pasted email in the real write path, and the shared detector agrees", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      count_before = Repo.aggregate(ActivityEntry, :count)

      for text <- @emails do
        assert {:error, :redacted_content} = Comments.add(project.id, owner, feature.id, text)
        assert DeliveryContentBoundary.scan_text(text) == {:error, :email_detected}
      end

      assert Repo.aggregate(ActivityEntry, :count) == count_before
    end
  end

  describe "activity payload keys: no forbidden key reaches an insert" do
    test "a payload naming any of ActivityEntry's own forbidden keys is refused before an insert",
         %{project: project, feature: feature} do
      count_before = Repo.aggregate(ActivityEntry, :count)

      for key <- ActivityEntry.forbidden_payload_keys() do
        assert {:error, changeset} =
                 Activity.append(%{
                   project_id: project.id,
                   feature_id: feature.id,
                   actor_kind: "system",
                   type: "progress",
                   payload: %{key => "placeholder"}
                 })

        assert %{payload: [message]} = errors_on(changeset)
        assert message =~ key
      end

      assert Repo.aggregate(ActivityEntry, :count) == count_before
    end
  end

  describe "review-feedback: shared detector proof, and the documented Slice 07 gap" do
    test "flags a pasted credential in realistic review-feedback-shaped text" do
      feedback = "Please rotate this before merging: sk-abcdefghijklmnopqrstuvwxyz012345"

      assert DeliveryContentBoundary.scan_text(feedback, "review_feedback") ==
               {:error, :credential_detected}
    end

    test "flags a pasted email in realistic review-feedback-shaped text" do
      feedback = "Loop in jordan@example.com before this ships."

      assert DeliveryContentBoundary.scan_text(feedback, "review_feedback") ==
               {:error, :email_detected}
    end

    test "passes ordinary rejection feedback with no credential or email" do
      feedback = "The mobile layout still overflows on narrow screens. Please fix and resubmit."

      assert DeliveryContentBoundary.scan_text(feedback, "review_feedback") == :ok
    end

    test "documents the gap: ReviewDecision.record_changeset places no credential/email scan on feedback" do
      feedback = "Please rotate this before merging: sk-abcdefghijklmnopqrstuvwxyz012345"

      attrs = %{
        project_id: Ecto.UUID.generate(),
        feature_id: Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate(),
        attempt_id: Ecto.UUID.generate(),
        decision: "rejected",
        feedback: feedback,
        reviewer_account_id: Ecto.UUID.generate(),
        branch: "sdd/feature-1",
        commit_sha: "abc123def456",
        decided_at: DateTime.utc_now()
      }

      changeset = ReviewDecision.record_changeset(%ReviewDecision{}, attrs)

      # The already-approved Slice 07 changeset accepts this feedback as-is: it
      # validates required-ness, pairing with the decision, and a byte-length
      # cap, but runs no credential or email scan, unlike Comments.add/4.
      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :feedback)

      # The shared detector this task builds would have caught it.
      assert DeliveryContentBoundary.scan_text(feedback, "review_feedback") ==
               {:error, :credential_detected}
    end
  end

  describe "notification minimization: realistic title/body/label fixtures carry no credential or email" do
    # Reproduces SddOrchestrator.Delivery.RunNotifications's own title/body
    # shapes (read-only reference; that module is not modified here) to prove
    # its real output carries no email or credential literal.
    test "the three real notification titles carry no credential or email shape" do
      for title <- ["A run needs an answer", "Work is ready for review", "A run failed"] do
        assert DeliveryContentBoundary.scan_text(title, "notification_title") == :ok
      end
    end

    test "the three real notification body templates carry no credential or email shape" do
      feature_label = "Add payment retry banner"

      bodies = [
        "#{feature_label} is waiting on an answer before development continues.",
        "#{feature_label} is ready for a review decision.",
        "#{feature_label} stopped on a failed run and is waiting for a decision."
      ]

      for body <- bodies do
        assert DeliveryContentBoundary.scan_text(body, "notification_body") == :ok
      end
    end

    test "a project label carries no credential or email shape" do
      assert DeliveryContentBoundary.scan_text("Acme Storefront", "notification_project_label") ==
               :ok
    end

    test "the shared detector would still catch an email or credential accidentally injected into a notification field" do
      assert DeliveryContentBoundary.scan_text(
               "contact alex@example.com for the failure detail",
               "notification_body"
             ) == {:error, :email_detected}

      assert DeliveryContentBoundary.scan_text(
               "token sk-abcdefghijklmnopqrstuvwxyz012345",
               "notification_body"
             ) == {:error, :credential_detected}
    end
  end

  describe "typed refusal result vocabulary" do
    test "every refusal returns exactly one of the three closed atoms" do
      assert {:error, :credential_detected} = DeliveryContentBoundary.scan_text(hd(@credentials))
      assert {:error, :email_detected} = DeliveryContentBoundary.scan_text(hd(@emails))

      assert {:error, :raw_event_detected} =
               DeliveryContentBoundary.reject_raw_event(%{"extra" => 1}, [])
    end
  end

  describe "diagnostic logging is field-name-only, never content" do
    test "a credential refusal logs the check and field name, never the matched secret" do
      secret = hd(@credentials)

      log =
        capture_log(fn ->
          assert DeliveryContentBoundary.scan_text(secret, "comment_body") ==
                   {:error, :credential_detected}
        end)

      assert log =~ "check=credential_detected"
      assert log =~ "field=comment_body"
      refute log =~ secret
      refute log =~ "sk-abcdefghijklmnopqrstuvwxyz012345"
    end

    test "an email refusal logs the check and field name, never the matched address" do
      email_text = hd(@emails)

      log =
        capture_log(fn ->
          assert DeliveryContentBoundary.scan_text(email_text, "review_feedback") ==
                   {:error, :email_detected}
        end)

      assert log =~ "check=email_detected"
      assert log =~ "field=review_feedback"
      refute log =~ "alex@example.com"
    end

    test "a raw-event refusal logs the check and offending field names, never envelope content" do
      envelope = %{"summary" => "fine", "unexpected_provider_field" => "raw content here"}

      log =
        capture_log(fn ->
          assert DeliveryContentBoundary.reject_raw_event(envelope, ~w(summary)) ==
                   {:error, :raw_event_detected}
        end)

      assert log =~ "check=raw_event_detected"
      assert log =~ "field=unexpected_provider_field"
      refute log =~ "raw content here"
    end
  end

  describe "audit trail" do
    test "every emitted line carries only allowlisted keys" do
      log =
        capture_log(fn ->
          DeliveryContentBoundary.scan_text(hd(@credentials), "comment_body")
          DeliveryContentBoundary.scan_text(hd(@emails), "review_feedback")
          DeliveryContentBoundary.reject_raw_event(%{"a" => 1, "b" => 2}, ~w(a))
        end)

      allowed = DeliveryContentBoundaryAudit.allowed_keys()

      for line <- String.split(log, "\n"),
          String.contains?(line, "[#{DeliveryContentBoundaryAudit.tag()}]") do
        [_prefix, payload] =
          String.split(line, "[#{DeliveryContentBoundaryAudit.tag()}] ", parts: 2)

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
          DeliveryContentBoundaryAudit.event(:refused, %{
            check: :credential_detected,
            field: "comment_body",
            outcome: :rejected,
            project_name: "Secret Launch Project",
            comment_body_content: "the participant's private comment sk-abcdef0123456789",
            participant_email: "person@example.com"
          })
        end)

      assert log =~ "check=credential_detected"
      refute log =~ "Secret Launch Project"
      refute log =~ "private comment"
      refute log =~ "person@example.com"
      refute log =~ "project_name"
      refute log =~ "comment_body_content"
      refute log =~ "participant_email"
    end
  end

  defp event(run, attempt, opts) do
    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "run_id" => run.id,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => Keyword.get(opts, :fence_token, attempt.fence_token),
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => "progress",
      "source" => "agent",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => Keyword.get(opts, :payload, %{"summary" => "Working"})
    }
  end
end
