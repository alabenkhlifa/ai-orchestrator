defmodule SddOrchestrator.Privacy.DeliveryProcessingInventoryTest do
  @moduledoc """
  Proof for specs/18 Task 1 (AC-01): every Slice 07 guided-delivery field and
  transfer carries one mechanically valid purpose, basis, authority, recipient,
  processor, transfer, and lifecycle-owner classification, with no unclassified
  processing and no governed content leaking into the inventory itself.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.DeliveryProcessingInventory, as: Inventory
  alias SddOrchestrator.Privacy.DeliveryProcessingRecord, as: Record

  @expected_keys [
    :entity,
    :field,
    :purpose,
    :basis,
    :authority,
    :recipient_category,
    :processor_category,
    :transfer_classification,
    :lifecycle_owner
  ]

  describe "completeness" do
    test "every Slice 07 schema field has exactly one inventory entry" do
      assert Inventory.missing_fields() == %{},
             "schema fields with no inventory entry: #{inspect(Inventory.missing_fields())}"
    end

    test "no inventory entry names a field its schema no longer declares" do
      assert Inventory.unknown_fields() == %{},
             "inventory entries with no matching schema field: #{inspect(Inventory.unknown_fields())}"
    end

    test "every inventoried schema contributes at least one record" do
      for {entity, schema} <- Inventory.schemas() do
        count = Inventory.records() |> Enum.count(&(&1.entity == entity))

        assert count == length(schema.__schema__(:fields)),
               "#{entity} has #{count} inventory records but #{length(schema.__schema__(:fields))} schema fields"
      end
    end

    test "no entity/field pair is classified twice" do
      duplicates =
        Inventory.records()
        |> Enum.map(&{&1.entity, &1.field})
        |> Enum.frequencies()
        |> Enum.filter(fn {_pair, count} -> count > 1 end)

      assert duplicates == []
    end

    test "the guided-delivery entity list from specs/07 design.md is covered" do
      entities = Inventory.records() |> Enum.map(& &1.entity) |> Enum.uniq() |> MapSet.new()

      for entity <- ~w(
            feature readiness_assessment agent_run run_attempt run_command
            blocking_question activity_entry evidence evidence_artifact
            preview_deployment review_decision processing_confirmation
            account_notification
          )a do
        assert entity in entities, "processing inventory is missing entity #{entity}"
      end
    end
  end

  describe "purpose" do
    test "every record names a non-blank purpose" do
      for record <- Inventory.records() do
        assert is_binary(record.purpose) and String.trim(record.purpose) != "",
               "#{record.entity}.#{record.field} has no purpose"
      end
    end

    test "no field purpose is a copy-pasted duplicate of another field's purpose" do
      Inventory.records()
      |> Enum.group_by(& &1.purpose)
      |> Enum.each(fn {purpose, records} ->
        assert length(records) == 1,
               "purpose #{inspect(purpose)} is reused by #{inspect(Enum.map(records, &{&1.entity, &1.field}))}"
      end)
    end
  end

  describe "basis" do
    test "every record declares an approved lawful basis" do
      for record <- Inventory.records() do
        assert record.basis in Record.bases(),
               "#{record.entity}.#{record.field} has an unapproved basis #{inspect(record.basis)}"
      end
    end

    test "no Slice 07 field is a security log, so every field is contract necessity" do
      assert Inventory.records() |> Enum.all?(&(&1.basis == :contract_necessity))
    end

    test "the operational-security basis remains approved for a future security-log inventory" do
      assert :operational_security in Record.bases()
    end
  end

  describe "authority" do
    test "every record declares an approved authority" do
      for record <- Inventory.records() do
        assert record.authority in Record.authorities(),
               "#{record.entity}.#{record.field} has an unapproved authority #{inspect(record.authority)}"
      end
    end

    test "dual-store entities are classified :both" do
      for entity <- ~w(
            feature agent_run run_attempt run_command blocking_question
            activity_entry evidence evidence_artifact preview_deployment
            review_decision
          )a do
        assert Inventory.records()
               |> Enum.filter(&(&1.entity == entity))
               |> Enum.all?(&(&1.authority == :both)),
               "#{entity} should be dual-store (:both) authority"
      end
    end

    test "hosted-only entities are classified :hosted" do
      for entity <- ~w(readiness_assessment processing_confirmation account_notification)a do
        assert Inventory.records()
               |> Enum.filter(&(&1.entity == entity))
               |> Enum.all?(&(&1.authority == :hosted)),
               "#{entity} should be :hosted authority"
      end
    end
  end

  describe "recipient" do
    test "every record declares an approved recipient category" do
      for record <- Inventory.records() do
        assert record.recipient_category in Record.recipient_categories(),
               "#{record.entity}.#{record.field} has an unapproved recipient #{inspect(record.recipient_category)}"
      end
    end

    test "run_command fields are addressed to the worker or provider capability, not participants" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity == :run_command))
             |> Enum.all?(&(&1.recipient_category == :worker_or_provider_capability))
    end

    test "the start-time processing confirmation is operations-support compliance evidence" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity == :processing_confirmation))
             |> Enum.all?(&(&1.recipient_category == :operations_support))
    end
  end

  describe "processor" do
    test "every record declares an approved processor category" do
      for record <- Inventory.records() do
        assert record.processor_category in Record.processor_categories(),
               "#{record.entity}.#{record.field} has an unapproved processor #{inspect(record.processor_category)}"
      end
    end

    test "the configured preview provider fields are classified as the preview processor" do
      preview =
        Inventory.records() |> Enum.filter(&(&1.entity == :preview_deployment))

      for field <- ~w(provider provider_ref link path)a do
        record = Enum.find(preview, &(&1.field == field))

        assert record.processor_category == :preview_provider,
               "#{field} should be :preview_provider"
      end

      for field <- ~w(branch commit_sha status)a do
        record = Enum.find(preview, &(&1.field == field))

        assert record.processor_category == :hosted_database_or_device_worker,
               "#{field} should stay the ordinary dual-store processor"
      end
    end
  end

  describe "transfer" do
    test "every record declares an approved transfer classification" do
      for record <- Inventory.records() do
        assert record.transfer_classification in Record.transfer_classifications(),
               "#{record.entity}.#{record.field} has an unapproved transfer #{inspect(record.transfer_classification)}"
      end
    end

    test "run_command carries the hosted relay's transient control-delivery classification" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity == :run_command))
             |> Enum.all?(&(&1.transfer_classification == :hosted_relay_transient))
    end

    test "the configured preview provider fields require the disclosed remote-capability transfer" do
      for field <- ~w(provider provider_ref link path)a do
        record =
          Inventory.records()
          |> Enum.find(&(&1.entity == :preview_deployment and &1.field == field))

        assert record.transfer_classification == :configured_remote_capability
      end
    end

    test "ordinary project content never transfers merely by being stored" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity in [:feature, :activity_entry, :evidence]))
             |> Enum.all?(&(&1.transfer_classification == :no_transfer))
    end
  end

  describe "lifecycle owner" do
    test "every record points at an approved lifecycle-owning specification" do
      for record <- Inventory.records() do
        assert record.lifecycle_owner in Record.lifecycle_owners(),
               "#{record.entity}.#{record.field} has an unapproved lifecycle owner #{inspect(record.lifecycle_owner)}"
      end
    end

    test "inactive execution mechanics are owned by the operational-retention specification" do
      for entity <- ~w(run_command preview_deployment evidence_artifact)a do
        assert Inventory.records()
               |> Enum.filter(&(&1.entity == entity))
               |> Enum.all?(&(&1.lifecycle_owner == :specs_19_operational_retention)),
               "#{entity} should be owned by specs/19 (operational retention)"
      end
    end

    test "a superseded evidence row is owned by the operational-retention specification" do
      record =
        Enum.find(
          Inventory.records(),
          &(&1.entity == :evidence and &1.field == :superseded_by_id)
        )

      assert record.lifecycle_owner == :specs_19_operational_retention
    end

    test "authoritative retained-while-active history is owned by the deletion-and-recovery specification" do
      for entity <-
            ~w(feature readiness_assessment agent_run activity_entry review_decision processing_confirmation)a do
        assert Inventory.records()
               |> Enum.filter(&(&1.entity == entity))
               |> Enum.all?(&(&1.lifecycle_owner == :specs_21_deletion_and_recovery)),
               "#{entity} should be owned by specs/21 (deletion and recovery)"
      end
    end

    test "the delivery-namespace notification fields are owned by the already-implemented notification-access specification" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity == :account_notification))
             |> Enum.all?(&(&1.lifecycle_owner == :specs_17_notification_access))
    end

    test "the device-data-retention specification remains an approved lifecycle owner" do
      assert :specs_20_device_data_retention in Record.lifecycle_owners()
    end
  end

  describe "minimum field" do
    test "a record carries exactly its nine classification fields, nothing else" do
      for record <- Inventory.records() do
        keys = record |> Map.from_struct() |> Map.keys() |> Enum.sort()
        assert keys == Enum.sort(@expected_keys)
      end
    end

    test "the struct enforces every classification key at construction" do
      assert_raise ArgumentError, fn ->
        struct!(Record, entity: :feature, field: :title)
      end
    end
  end

  describe "content absence" do
    test "no purpose embeds an email-shaped literal" do
      for record <- Inventory.records() do
        refute record.purpose =~ ~r/[^\s]+@[^\s]+\.[^\s]+/,
               "#{record.entity}.#{record.field} purpose looks like it embeds an email address"
      end
    end

    test "no purpose embeds a long opaque token, digest, or credential-shaped literal" do
      for record <- Inventory.records() do
        refute record.purpose =~ ~r/[0-9a-fA-F]{32,}/,
               "#{record.entity}.#{record.field} purpose looks like it embeds a raw token or digest"
      end
    end

    test "no purpose embeds an actual secret-shaped literal rather than describing one" do
      # A purpose may legitimately *describe* a security control (evidence's
      # digest addressing, or activity's rejection of credential-shaped
      # payload keys), so this checks for an embedded `key: value` or
      # `key=value` literal, not for the English category word alone.
      literal_pattern =
        ~r/(password|secret|credential|api[_-]?key|access[_-]?token)\s*[:=]\s*\S+/i

      for record <- Inventory.records() do
        refute record.purpose =~ literal_pattern,
               "#{record.entity}.#{record.field} purpose looks like it embeds a literal secret"
      end
    end

    test "every classification value is an atom, never free-form captured text" do
      for record <- Inventory.records() do
        assert is_atom(record.basis)
        assert is_atom(record.authority)
        assert is_atom(record.recipient_category)
        assert is_atom(record.processor_category)
        assert is_atom(record.transfer_classification)
        assert is_atom(record.lifecycle_owner)
        assert is_atom(record.entity)
        assert is_atom(record.field)
      end
    end
  end

  describe "invalid classification (validator rejection)" do
    @valid %{
      entity: :feature,
      field: :title,
      purpose: "Present the user-facing feature label.",
      basis: :contract_necessity,
      authority: :hosted,
      recipient_category: :current_participants,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    }

    test "a fully valid record passes" do
      assert Record.validate(struct!(Record, @valid)) == :ok
    end

    test "an unapproved basis is rejected" do
      record = struct!(Record, %{@valid | basis: :legitimate_interests})
      assert {:error, reasons} = Record.validate(record)
      assert :basis in reasons
    end

    test "an unapproved authority is rejected" do
      record = struct!(Record, %{@valid | authority: :cloud})
      assert {:error, reasons} = Record.validate(record)
      assert :authority in reasons
    end

    test "an unapproved recipient category is rejected" do
      record = struct!(Record, %{@valid | recipient_category: :the_public})
      assert {:error, reasons} = Record.validate(record)
      assert :recipient_category in reasons
    end

    test "an unapproved processor category is rejected" do
      record = struct!(Record, %{@valid | processor_category: :analytics_vendor})
      assert {:error, reasons} = Record.validate(record)
      assert :processor_category in reasons
    end

    test "an unapproved transfer classification is rejected" do
      record = struct!(Record, %{@valid | transfer_classification: :unrestricted})
      assert {:error, reasons} = Record.validate(record)
      assert :transfer_classification in reasons
    end

    test "an unapproved lifecycle owner is rejected" do
      record = struct!(Record, %{@valid | lifecycle_owner: :nobody})
      assert {:error, reasons} = Record.validate(record)
      assert :lifecycle_owner in reasons
    end

    test "a blank purpose is rejected" do
      record = struct!(Record, %{@valid | purpose: ""})
      assert {:error, reasons} = Record.validate(record)
      assert :purpose in reasons
    end

    test "every classification failure is reported at once, not just the first" do
      record =
        struct!(Record, %{
          @valid
          | purpose: "",
            basis: :bad,
            authority: :bad,
            recipient_category: :bad,
            processor_category: :bad,
            transfer_classification: :bad,
            lifecycle_owner: :bad
        })

      assert {:error, reasons} = Record.validate(record)

      assert MapSet.new(reasons) ==
               MapSet.new([
                 :purpose,
                 :basis,
                 :authority,
                 :recipient_category,
                 :processor_category,
                 :transfer_classification,
                 :lifecycle_owner
               ])
    end

    test "the real inventory has no unclassified processing" do
      assert Inventory.validate_all() == :ok
    end
  end
end
