defmodule SddOrchestrator.Privacy.DeliverySecurityLogTest do
  @moduledoc """
  specs/19 Task 4 proof.

  A fixed, minimized `DeliverySecurityEvent` carries only an allowlisted
  guided-delivery event type, coarse outcome, fixed reason classification when
  required, UTC occurrence time, and a fresh non-secret correlation
  identifier. No project, feature, run, attempt, command, participant, or
  worker identifier, and no specification content, comment, blocking question,
  evidence, preview link, credential, or email, can ever reach a stored row —
  and a call outside the closed vocabulary is refused with a typed result
  rather than raising or being stored.

  The 30-day expiry over `occurred_at` is a later specs/19 task; nothing here
  deletes.
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Privacy.{DeliverySecurityEvent, DeliverySecurityLog}

  # One valid `{outcome, reason}` pair per allowlisted event type. The
  # coverage assertion below fails the moment the vocabulary grows without
  # this proof growing with it.
  @vocabulary %{
    worker_command_rejected: {:rejected, :secret_field_rejected},
    agent_adapter_rejected: {:rejected, :raw_event_detected},
    delivery_access_denied: {:denied, :unauthorized},
    evidence_artifact_rejected: {:rejected, :credential_detected},
    retention_sweep_failed: {:failed, nil}
  }

  @schema_fields [
    :correlation_id,
    :event_type,
    :id,
    :inserted_at,
    :occurred_at,
    :outcome,
    :reason
  ]

  describe "closed event-type, outcome, and reason vocabulary" do
    test "the proven vocabulary covers exactly the allowlisted event types" do
      assert Enum.sort(Map.keys(@vocabulary)) == Enum.sort(DeliverySecurityLog.event_types())
      assert DeliverySecurityLog.outcomes() == [:rejected, :denied, :failed]
    end

    test "every allowlisted event type persists one row with exactly the fixed fields" do
      now = truncated_now()

      capture_log(fn ->
        for {event_type, {outcome, reason}} <- @vocabulary do
          assert :ok =
                   DeliverySecurityLog.emit(event_type, outcome,
                     reason: reason,
                     occurred_at: now
                   )
        end
      end)

      stored = Repo.all(DeliverySecurityEvent)
      assert length(stored) == map_size(@vocabulary)

      for event <- stored do
        {outcome, reason} = Map.fetch!(@vocabulary, event.event_type)

        assert event.outcome == outcome
        assert event.reason == reason
        assert event.occurred_at == now
        assert {:ok, _uuid} = Ecto.UUID.cast(event.correlation_id)
        assert persisted_keys(event) == @schema_fields
      end
    end

    test "the schema declares no column capable of holding project content" do
      assert Enum.sort(DeliverySecurityEvent.__schema__(:fields)) == @schema_fields

      for field <- DeliverySecurityEvent.__schema__(:fields) do
        refute field in [
                 :project_id,
                 :feature_id,
                 :run_id,
                 :attempt_id,
                 :command_id,
                 :account_id,
                 :participant_id,
                 :worker_id,
                 :payload,
                 :content,
                 :message,
                 :detail,
                 :field,
                 :metadata
               ]
      end

      # The two free-shaped columns are closed enumerations, not free text.
      assert {:parameterized, {Ecto.Enum, _}} =
               DeliverySecurityEvent.__schema__(:type, :event_type)

      assert {:parameterized, {Ecto.Enum, _}} = DeliverySecurityEvent.__schema__(:type, :reason)
    end
  end

  describe "typed refusal outside the closed vocabulary" do
    test "a non-allowlisted event type is refused and writes nothing" do
      # Routed through `String.to_atom/1` so this is a runtime-bound value,
      # not a literal the compiler could treat as always-invalid.
      unlisted = String.to_atom("delivery_project_content_exfiltrated")

      log =
        capture_log(fn ->
          assert {:error, :unapproved_event_type} =
                   DeliverySecurityLog.emit(unlisted, :rejected, reason: :credential_detected)
        end)

      assert log =~ "refused=unapproved_event_type"
      refute log =~ "delivery_project_content_exfiltrated"
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 0
    end

    test "a non-allowlisted outcome is refused and writes nothing" do
      unlisted = String.to_atom("blocked")

      log =
        capture_log(fn ->
          assert {:error, :unapproved_outcome} =
                   DeliverySecurityLog.emit(:worker_command_rejected, unlisted,
                     reason: :secret_field_rejected
                   )
        end)

      assert log =~ "refused=unapproved_outcome"
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 0
    end

    test "a reason not approved for its outcome is refused and writes nothing" do
      log =
        capture_log(fn ->
          # `:unauthorized` is a `:denied` reason, never a `:rejected` one.
          assert {:error, :unapproved_reason} =
                   DeliverySecurityLog.emit(:worker_command_rejected, :rejected,
                     reason: :unauthorized
                   )

          # An outcome that requires a reason refuses to persist without one.
          assert {:error, :unapproved_reason} =
                   DeliverySecurityLog.emit(:delivery_access_denied, :denied, [])

          # An atom outside the reason vocabulary entirely.
          assert {:error, :unapproved_reason} =
                   DeliverySecurityLog.emit(:agent_adapter_rejected, :rejected,
                     reason: String.to_atom("project_content_detected")
                   )
        end)

      assert log =~ "refused=unapproved_reason"
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 0
    end

    test "a refusal never raises, so a mis-declared call site cannot fail a delivery request" do
      capture_log(fn ->
        assert {:error, :unapproved_event_type} =
                 DeliverySecurityLog.emit(String.to_atom("nope"), :failed, [])

        assert {:error, :some_upstream_reason} =
                 DeliverySecurityLog.audit(
                   {:error, :some_upstream_reason},
                   String.to_atom("nope"),
                   []
                 )
      end)

      assert Repo.aggregate(DeliverySecurityEvent, :count) == 0
    end
  end

  describe "structurally impossible forbidden content" do
    test "every caller-supplied key outside the fixed schema is dropped" do
      now = truncated_now()

      assert DeliverySecurityLog.allowed_opt_keys() == [:reason, :occurred_at]

      log =
        capture_log(fn ->
          assert :ok =
                   DeliverySecurityLog.emit(:evidence_artifact_rejected, :rejected,
                     reason: :credential_detected,
                     occurred_at: now,
                     project_id: Ecto.UUID.generate(),
                     email: "attacker@example.com",
                     token: "ghp_leakedleakedleakedleaked",
                     prompt: "leaked agent prompt text",
                     question: "leaked blocking question",
                     artifact: "leaked evidence bytes",
                     correlation_id: Ecto.UUID.generate()
                   )
        end)

      assert [stored] = Repo.all(DeliverySecurityEvent)
      assert persisted_keys(stored) == @schema_fields

      dumped = Repo.one!(raw_row_query())

      for leaked <- [
            "attacker@example.com",
            "ghp_leakedleakedleakedleaked",
            "leaked agent prompt text",
            "leaked blocking question",
            "leaked evidence bytes"
          ] do
        refute inspect(stored) =~ leaked
        refute dumped =~ leaked
        refute log =~ leaked
      end
    end

    test "a changeset built directly against the schema also drops every unapproved key" do
      changeset =
        DeliverySecurityEvent.changeset(%DeliverySecurityEvent{}, %{
          event_type: :agent_adapter_rejected,
          outcome: :rejected,
          reason: :raw_event_detected,
          occurred_at: truncated_now(),
          correlation_id: Ecto.UUID.generate(),
          project_id: Ecto.UUID.generate(),
          email: "smuggled@example.com",
          prompt: "smuggled prompt",
          artifact: "smuggled bytes"
        })

      assert changeset.valid?

      for key <- [:project_id, :email, :prompt, :artifact] do
        refute Map.has_key?(changeset.changes, key)
      end
    end
  end

  describe "fresh non-secret correlation identifiers" do
    test "two emits about the same underlying context get different correlation ids" do
      now = truncated_now()

      capture_log(fn ->
        for _twice <- 1..2 do
          assert :ok =
                   DeliverySecurityLog.emit(:worker_command_rejected, :rejected,
                     reason: :secret_field_rejected,
                     occurred_at: now
                   )
        end
      end)

      assert [first, second] = Repo.all(DeliverySecurityEvent)
      assert first.correlation_id != second.correlation_id
      assert {:ok, _} = Ecto.UUID.cast(first.correlation_id)
      assert {:ok, _} = Ecto.UUID.cast(second.correlation_id)
    end

    test "the correlation id is never derived from a project, run, or worker identifier" do
      project_id = Ecto.UUID.generate()
      run_id = Ecto.UUID.generate()
      worker_id = Ecto.UUID.generate()

      capture_log(fn ->
        assert :ok =
                 DeliverySecurityLog.emit(:delivery_access_denied, :denied,
                   reason: :unauthorized,
                   project_id: project_id,
                   run_id: run_id,
                   worker_id: worker_id,
                   correlation_id: project_id
                 )
      end)

      assert [stored] = Repo.all(DeliverySecurityEvent)

      refute stored.correlation_id == project_id
      refute stored.correlation_id == run_id
      refute stored.correlation_id == worker_id
    end
  end

  describe "audit/3 pass-through" do
    test "a success is silent and the result is returned unchanged" do
      assert {:ok, :dispatched} =
               DeliverySecurityLog.audit({:ok, :dispatched}, :worker_command_rejected)

      assert :ok = DeliverySecurityLog.audit(:ok, :worker_command_rejected)
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 0
    end

    test "a failure emits the classified outcome and still returns the result unchanged" do
      capture_log(fn ->
        assert {:error, :secret_material_rejected} =
                 DeliverySecurityLog.audit(
                   {:error, :secret_material_rejected},
                   :worker_command_rejected
                 )

        assert {:error, :not_found} =
                 DeliverySecurityLog.audit({:error, :not_found}, :evidence_artifact_rejected)

        assert {:error, :some_unclassified_reason} =
                 DeliverySecurityLog.audit(
                   {:error, :some_unclassified_reason},
                   :retention_sweep_failed
                 )
      end)

      stored = Repo.all(DeliverySecurityEvent) |> Map.new(&{&1.event_type, &1})

      assert stored[:worker_command_rejected].outcome == :rejected
      assert stored[:worker_command_rejected].reason == :secret_material_rejected

      assert stored[:evidence_artifact_rejected].outcome == :denied
      assert stored[:evidence_artifact_rejected].reason == :not_found

      # The redaction clause: an unrecognised reason is never inspected,
      # matched, or stored.
      assert stored[:retention_sweep_failed].outcome == :failed
      assert is_nil(stored[:retention_sweep_failed].reason)
    end
  end

  defp persisted_keys(event) do
    # `Map.from_struct/1` also carries Ecto's own `:__meta__` bookkeeping key;
    # every other key is one of this schema's own declared fields.
    event |> Map.from_struct() |> Map.delete(:__meta__) |> Map.keys() |> Enum.sort()
  end

  # Reads the row as the database itself holds it, so the "no column can hold
  # project content" claim is proven against real storage, not only against the
  # struct Ecto hands back.
  defp raw_row_query do
    from event in "delivery_security_events",
      select:
        fragment(
          "concat_ws(' ', ?::text, ?::text, ?::text, ?::text, ?::text, ?::text)",
          event.id,
          event.event_type,
          event.outcome,
          event.reason,
          event.occurred_at,
          event.correlation_id
        )
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
