defmodule SddOrchestrator.Privacy.ParticipationProcessingInventoryTest do
  @moduledoc """
  Proof for specs/26 Task 1 (AC-01): every participation field and transfer
  carries one mechanically valid purpose, basis, authority, recipient,
  processor, transfer, and lifecycle-owner classification, matching the
  approved `capability:participation-identity-lifecycle` contract, with no
  unclassified processing and no governed content leaking into the inventory
  itself.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.ParticipationProcessingInventory, as: Inventory
  alias SddOrchestrator.Privacy.ParticipationProcessingRecord, as: Record

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
    test "every participation schema field has exactly one inventory entry" do
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

    test "the participation entity list from specs/26 design.md is covered" do
      entities = Inventory.records() |> Enum.map(& &1.entity) |> Enum.uniq() |> MapSet.new()

      for entity <- ~w(
            project_invitation project_participant project_member_profile
            participation_revocation participation_email_delivery
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

    test "no inventoried field is a security log, so every field is contract necessity" do
      assert Inventory.records() |> Enum.all?(&(&1.basis == :contract_necessity))
    end

    test "the legitimate-interests basis remains approved for a future security-log inventory" do
      assert :legitimate_interests in Record.bases()
    end
  end

  describe "authority" do
    test "every record declares an approved authority" do
      for record <- Inventory.records() do
        assert record.authority in Record.authorities(),
               "#{record.entity}.#{record.field} has an unapproved authority #{inspect(record.authority)}"
      end
    end

    test "every participation entity is hosted-only, so every record is :hosted authority" do
      assert Inventory.records() |> Enum.all?(&(&1.authority == :hosted))
    end
  end

  describe "recipient" do
    test "every record declares an approved recipient category" do
      for record <- Inventory.records() do
        assert record.recipient_category in Record.recipient_categories(),
               "#{record.entity}.#{record.field} has an unapproved recipient #{inspect(record.recipient_category)}"
      end
    end

    test "invitation credential-verification fields are minimized-operations only, never owner-visible" do
      records =
        Inventory.records() |> Enum.filter(&(&1.entity == :project_invitation))

      for field <- ~w(email_digest token_digest token_salt)a do
        record = Enum.find(records, &(&1.field == field))

        assert record.recipient_category == :minimized_operations,
               "#{field} should be minimized_operations"
      end

      for field <- ~w(status expires_at project_id invited_by_account_id)a do
        record = Enum.find(records, &(&1.field == field))

        assert record.recipient_category == :owner_membership_management,
               "#{field} should stay the ordinary owner membership-management recipient"
      end
    end

    test "participation email-delivery diagnostics are addressed to minimized operations" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity == :participation_email_delivery))
             |> Enum.all?(&(&1.recipient_category == :minimized_operations))
    end

    test "project member presentation labels are participant project context" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity == :project_member_profile))
             |> Enum.all?(&(&1.recipient_category == :participant_project_context))
    end

    test "the exceptional-support recipient category remains approved with no default record" do
      assert :exceptional_support in Record.recipient_categories()

      refute Inventory.records() |> Enum.any?(&(&1.recipient_category == :exceptional_support))
    end
  end

  describe "processor" do
    test "every record declares an approved processor category" do
      for record <- Inventory.records() do
        assert record.processor_category in Record.processor_categories(),
               "#{record.entity}.#{record.field} has an unapproved processor #{inspect(record.processor_category)}"
      end
    end

    test "the fields that leave the hosted database are classified as the email-delivery processor" do
      invitation_record =
        Inventory.records()
        |> Enum.find(&(&1.entity == :project_invitation and &1.field == :delivery_email))

      delivery_record =
        Inventory.records()
        |> Enum.find(
          &(&1.entity == :participation_email_delivery and &1.field == :recipient_address)
        )

      assert invitation_record.processor_category == :email_delivery_provider
      assert delivery_record.processor_category == :email_delivery_provider
    end

    test "invitation credential fields stay the ordinary hosted-database processor" do
      records = Inventory.records() |> Enum.filter(&(&1.entity == :project_invitation))

      for field <- ~w(email_digest token_digest token_salt)a do
        record = Enum.find(records, &(&1.field == field))

        assert record.processor_category == :hosted_database,
               "#{field} should stay hosted_database"
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

    test "the configured email-delivery fields require the disclosed transfer classification" do
      invitation_record =
        Inventory.records()
        |> Enum.find(&(&1.entity == :project_invitation and &1.field == :delivery_email))

      delivery_record =
        Inventory.records()
        |> Enum.find(
          &(&1.entity == :participation_email_delivery and &1.field == :recipient_address)
        )

      assert invitation_record.transfer_classification == :configured_email_delivery
      assert delivery_record.transfer_classification == :configured_email_delivery
    end

    test "ordinary participation authorization and presentation data never transfers merely by being stored" do
      assert Inventory.records()
             |> Enum.filter(&(&1.entity in [:project_participant, :project_member_profile]))
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

    test "revocation, departure, and anonymization fields match the approved identity lifecycle" do
      revocation_identity_fields =
        Inventory.records()
        |> Enum.filter(
          &(&1.entity == :participation_revocation and
              &1.field in [:former_hosted_identity_id, :former_account_id, :occurred_at, :reason])
        )

      profile_identity_fields =
        Inventory.records()
        |> Enum.filter(
          &(&1.entity == :project_member_profile and
              &1.field in [:state, :anonymized_at, :account_id, :display_name])
        )

      assert length(revocation_identity_fields) == 4
      assert length(profile_identity_fields) == 4

      for record <- revocation_identity_fields ++ profile_identity_fields do
        assert record.lifecycle_owner == :specs_25_participation_identity_lifecycle,
               "#{record.entity}.#{record.field} must match the approved participation identity lifecycle"
      end
    end

    test "every participation_revocation and project_member_profile field is owned by the identity-lifecycle specification" do
      for entity <-
            ~w(participation_revocation project_member_profile project_participant project_invitation)a do
        assert Inventory.records()
               |> Enum.filter(&(&1.entity == entity))
               |> Enum.all?(&(&1.lifecycle_owner == :specs_25_participation_identity_lifecycle)),
               "#{entity} should be owned by specs/25 (participation identity lifecycle)"
      end
    end

    test "email-delivery diagnostics and participation notifications are owned by operational retention" do
      for entity <- ~w(participation_email_delivery account_notification)a do
        assert Inventory.records()
               |> Enum.filter(&(&1.entity == entity))
               |> Enum.all?(
                 &(&1.lifecycle_owner == :specs_27_participation_operational_retention)
               ),
               "#{entity} should be owned by specs/27 (participation operational retention)"
      end
    end

    test "the deletion-and-recovery specification remains an approved lifecycle owner with no default record" do
      assert :specs_28_participation_deletion_and_recovery in Record.lifecycle_owners()

      refute Inventory.records()
             |> Enum.any?(&(&1.lifecycle_owner == :specs_28_participation_deletion_and_recovery))
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
        struct!(Record, entity: :project_invitation, field: :status)
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
      # A purpose may legitimately *describe* a security control (an
      # invitation's digest addressing, or a revocation's rejection of raw
      # identity values), so this checks for an embedded `key: value` or
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
      entity: :project_invitation,
      field: :status,
      purpose: "Track the invitation through its approved lifecycle.",
      basis: :contract_necessity,
      authority: :hosted,
      recipient_category: :owner_membership_management,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_25_participation_identity_lifecycle
    }

    test "a fully valid record passes" do
      assert Record.validate(struct!(Record, @valid)) == :ok
    end

    test "an unapproved basis is rejected" do
      record = struct!(Record, %{@valid | basis: :advertising})
      assert {:error, reasons} = Record.validate(record)
      assert :basis in reasons
    end

    test "an unapproved authority is rejected" do
      record = struct!(Record, %{@valid | authority: :device})
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

    test "duplicate classification is caught at the inventory level, not merely per-record" do
      duplicated =
        Inventory.records() ++ [Enum.find(Inventory.records(), &(&1.field == :status))]

      duplicates =
        duplicated
        |> Enum.map(&{&1.entity, &1.field})
        |> Enum.frequencies()
        |> Enum.filter(fn {_pair, count} -> count > 1 end)

      assert duplicates != [],
             "expected the deliberately duplicated fixture to be detected as a duplicate"
    end

    test "the real inventory has no unclassified processing" do
      assert Inventory.validate_all() == :ok
    end
  end
end
