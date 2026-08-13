defmodule SddOrchestrator.Privacy.ParticipationPurposeLimitationTest do
  @moduledoc """
  Task 5 proof for specs/26 (AC-05): participation stores, requests, events,
  metrics, processors, transfers, and destinations carry no advertising,
  model-training reuse, unrelated improvement, product analytics, or stable
  pseudonymous profile, and the aggregate-measurement boundary accepts no
  linkable identifier or raw participation data.

  This does not re-prove Task 1's field-level classification (AC-01,
  `ParticipationProcessingInventoryTest`), Task 2's access boundary (AC-02),
  Task 3's support boundary (AC-03), or Task 4's content boundary (AC-04,
  `ParticipationContentBoundaryTest`, which already proves
  `authorize_destination/3` field-to-processor routing); it proves the
  purpose-limitation and secondary-use boundary drawn across all of them,
  mirroring `SddOrchestrator.Privacy.DeliveryPurposeLimitationTest` (specs/18
  Task 4).
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.ParticipationDataUsePolicy, as: Policy
  alias SddOrchestrator.Privacy.ParticipationProcessingInventory, as: Inventory
  alias SddOrchestrator.Privacy.ParticipationProcessingRecord, as: Record
  alias SddOrchestrator.Privacy.ProcessingInventory

  @participation_entities ~w(
    project_invitation project_participant project_member_profile
    participation_revocation participation_email_delivery account_notification
  )a

  @all_consumers [
    :project_owner,
    :current_participant,
    :email_delivery_provider,
    :approved_operations,
    :verified_rights_operator
  ]

  @analytics_shaped ["analytic", "advertis", "model training"]

  # --- store, request, event, and metric negative contract -----------------
  #
  # Task 1's inventory holds one record per persisted field across every
  # specs/26 schema (and the participation-namespace notification
  # foundation), so scanning its purposes covers every store, request,
  # event, and metric this slice produces: there is no separate analytics
  # table, outbound request, emitted event, or metric that would fall
  # outside this enumeration.
  describe "store, request, event, and metric negative contract" do
    test "no persisted participation field states a prohibited purpose" do
      for record <- Inventory.records() do
        purpose = String.downcase(record.purpose)

        refute String.contains?(purpose, @analytics_shaped),
               "#{record.entity}.#{record.field} states a prohibited purpose: #{record.purpose}"
      end
    end

    test "no persisted field purpose names an analytics, tracking, or ad-tech destination" do
      for record <- Inventory.records() do
        purpose = String.downcase(record.purpose)

        refute String.contains?(purpose, [
                 "tracking pixel",
                 "ad network",
                 "ad tech",
                 "third-party ad"
               ]),
               "#{record.entity}.#{record.field} names an ad-tech or tracking destination"
      end
    end
  end

  # --- identifier and stable-profile negative contract ----------------------
  describe "identifier and stable-profile negative contract" do
    test "every record's lawful basis is contract necessity, never a profiling basis" do
      assert Enum.all?(Inventory.records(), &(&1.basis == :contract_necessity)),
             "a specs/26 field is classified under a non-contract-necessity basis"
    end

    test "no purpose describes building a persistent profile for tracking, advertising, or analytics" do
      for record <- Inventory.records() do
        purpose = String.downcase(record.purpose)

        if String.contains?(purpose, "profile") do
          assert record.basis == :contract_necessity,
                 "#{record.entity}.#{record.field} builds a profile outside contract necessity"

          refute String.contains?(purpose, @analytics_shaped),
                 "#{record.entity}.#{record.field} builds an analytics-shaped profile"
        end
      end
    end

    test "declares no aggregate analytics processing and the minimum future boundary" do
      boundary = Policy.anonymous_aggregate_boundary()

      assert boundary.current_processing == :prohibited
      assert boundary.future_requirement == :aggregate_and_genuinely_anonymous

      # Exact list from this specification's own design.md ("Aggregate
      # measurement cannot contain or be grouped by account, identity, email
      # or digest, project, workspace, invitation, participant, notification,
      # repository, device, network, session, or another stable or
      # singling-out identifier") — deliberately not
      # `DeliveryDataUsePolicy`'s list, which names unrelated entities.
      for identifier <- [
            :account,
            :identity,
            :email_or_digest,
            :project,
            :workspace,
            :invitation,
            :participant,
            :notification,
            :repository,
            :device,
            :network,
            :session,
            :stable_or_singling_out_identifier
          ] do
        assert identifier in boundary.prohibited_identifiers,
               "#{identifier} is missing from the prohibited-identifier boundary"
      end
    end
  end

  # --- advertising and model-training denial --------------------------------
  describe "advertising denial" do
    test "advertising is refused for every data class and every consumer, including the email-delivery provider" do
      for data_class <- Policy.data_classes(), consumer <- @all_consumers do
        assert Policy.authorize(data_class, :advertising, consumer) ==
                 {:error, :secondary_use_prohibited},
               "#{data_class} authorized :advertising for #{consumer}"
      end
    end
  end

  describe "model-training denial" do
    test "model training reuse is refused for every data class and every consumer, including the email-delivery provider" do
      for data_class <- Policy.data_classes(), consumer <- @all_consumers do
        assert Policy.authorize(data_class, :model_training, consumer) ==
                 {:error, :secondary_use_prohibited},
               "#{data_class} authorized :model_training for #{consumer}"
      end
    end

    test "the email-delivery route never doubles as a training route" do
      assert Policy.authorize(:project_invitation, :model_training, :email_delivery_provider) ==
               {:error, :secondary_use_prohibited}

      assert Policy.authorize(
               :participation_email_delivery,
               :model_training,
               :email_delivery_provider
             ) ==
               {:error, :secondary_use_prohibited}
    end
  end

  describe "unrelated improvement and identity-tracking denial" do
    test "unrelated product improvement, identity tracking, and analytics are refused for every data class" do
      for data_class <- Policy.data_classes(),
          purpose <- [:unrelated_product_improvement, :identity_tracking, :analytics] do
        assert Policy.authorize(data_class, purpose, :approved_operations) ==
                 {:error, :secondary_use_prohibited},
               "#{data_class} authorized #{purpose}"
      end
    end
  end

  # --- unrelated processor denial -------------------------------------------
  describe "unrelated processor denial" do
    test "the advertising network, analytics processor, and unrelated processor are always refused" do
      for data_class <- Policy.data_classes(),
          {purpose, _consumers} <- Map.get(Policy.allowed_routes(), data_class, %{}),
          consumer <- Policy.prohibited_consumers() do
        assert Policy.authorize(data_class, purpose, consumer) ==
                 {:error, :consumer_prohibited},
               "#{data_class}/#{purpose} authorized prohibited consumer #{consumer}"
      end
    end

    test "email_delivery_provider is not blanket-prohibited, unlike a fixed-prohibition consumer" do
      refute :email_delivery_provider in Policy.prohibited_consumers()
    end

    test "an invitation legitimately reaches the configured email-delivery processor" do
      assert Policy.authorize(:project_invitation, :email_delivery, :email_delivery_provider) ==
               :ok
    end

    test "a delivery-diagnostic record legitimately reaches the configured email-delivery processor" do
      assert Policy.authorize(
               :participation_email_delivery,
               :email_delivery,
               :email_delivery_provider
             ) == :ok
    end

    test "the email-delivery provider is still refused outside its one approved route" do
      assert Policy.authorize(
               :project_invitation,
               :membership_management,
               :email_delivery_provider
             ) ==
               {:error, :not_authorized}

      assert Policy.authorize(
               :project_participant,
               :membership_management,
               :email_delivery_provider
             ) ==
               {:error, :not_authorized}

      assert Policy.authorize(
               :participation_email_delivery,
               :operations_diagnostics,
               :email_delivery_provider
             ) ==
               {:error, :not_authorized}
    end
  end

  # --- operational-telemetry classification ---------------------------------
  describe "operational-telemetry classification" do
    test "the legacy operational logs remain legitimate-interests governed personal data, not analytics" do
      refute ProcessingInventory.analytics?()

      records = Map.new(ProcessingInventory.records(), &{&1.activity, &1})

      for activity <- [:operational_security_log, :ai_runtime_operational_log] do
        record = Map.fetch!(records, activity)

        assert record.lawful_basis == :legitimate_interests,
               "#{activity} is not classified :legitimate_interests"

        refute String.contains?(String.downcase(record.purpose), @analytics_shaped),
               "#{activity} states a prohibited purpose"
      end
    end

    test "legitimate_interests remains an approved participation basis, currently unused by any field" do
      assert :legitimate_interests in Record.bases()
      refute Enum.any?(Inventory.records(), &(&1.basis == :legitimate_interests))
    end
  end

  # --- negative scan: closed classification enums ---------------------------
  describe "negative scan of Task 1's closed classification enums" do
    test "no recipient, processor, or transfer enum member names an analytics or advertising concept" do
      enum_values =
        Record.recipient_categories() ++
          Record.processor_categories() ++
          Record.transfer_classifications()

      for value <- enum_values do
        text = value |> Atom.to_string() |> String.downcase()

        refute String.contains?(text, ["analytic", "advertis"]),
               "#{value} names an analytics or advertising concept"
      end
    end
  end

  # --- legitimate routes (sanity that the boundary is not vacuous) ---------
  describe "legitimate purpose and consumer routes" do
    test "permits exactly the approved purpose and consumer for each data class" do
      assert Policy.authorize(:project_invitation, :membership_management, :project_owner) == :ok

      assert Policy.authorize(:project_invitation, :email_delivery, :email_delivery_provider) ==
               :ok

      assert Policy.authorize(:project_participant, :membership_management, :project_owner) ==
               :ok

      assert Policy.authorize(
               :project_member_profile,
               :participant_presentation,
               :current_participant
             ) == :ok

      assert Policy.authorize(:participation_revocation, :membership_management, :project_owner) ==
               :ok

      assert Policy.authorize(
               :participation_email_delivery,
               :operations_diagnostics,
               :approved_operations
             ) == :ok

      assert Policy.authorize(
               :participation_email_delivery,
               :email_delivery,
               :email_delivery_provider
             ) == :ok

      assert Policy.authorize(:account_notification, :notification_delivery, :current_participant) ==
               :ok

      for data_class <- Policy.data_classes() do
        assert Policy.authorize(data_class, :retention_cleanup, :approved_operations) == :ok
        assert Policy.authorize(data_class, :verified_rights, :verified_rights_operator) == :ok
      end

      assert Policy.authorize(:project_invitation, :membership_management, :approved_operations) ==
               {:error, :not_authorized}

      assert Policy.authorize(
               :project_member_profile,
               :participant_presentation,
               :project_owner
             ) ==
               {:error, :not_authorized}

      assert Policy.authorize(
               :participation_email_delivery,
               :operations_diagnostics,
               :current_participant
             ) ==
               {:error, :not_authorized}
    end
  end

  # --- capability contract ---------------------------------------------------
  describe "capability contract" do
    test "serves a downstream consumer through the public API alone" do
      # A consumer holds only a data class, a purpose, and a recipient.
      assert {:authorize, 3} in Policy.__info__(:functions)
      assert {:data_classes, 0} in Policy.__info__(:functions)
      assert {:allowed_routes, 0} in Policy.__info__(:functions)
      assert {:prohibited_purposes, 0} in Policy.__info__(:functions)
      assert {:prohibited_consumers, 0} in Policy.__info__(:functions)
      assert {:anonymous_aggregate_boundary, 0} in Policy.__info__(:functions)

      classes = Policy.data_classes()
      assert Enum.sort(classes) == Enum.sort(@participation_entities)

      for data_class <- classes do
        assert Policy.authorize(data_class, :model_training, :approved_operations) ==
                 {:error, :secondary_use_prohibited}
      end

      # An unknown class, purpose, or consumer is refused rather than defaulted to anything.
      assert Policy.authorize(:unknown_class, :membership_management, :project_owner) ==
               {:error, :not_authorized}

      assert Policy.authorize(:project_invitation, :unknown_purpose, :project_owner) ==
               {:error, :not_authorized}

      assert Policy.authorize(:project_invitation, :membership_management, :unknown_consumer) ==
               {:error, :not_authorized}

      # And a genuine downstream route is served, so the capability is usable.
      assert Policy.authorize(:project_invitation, :membership_management, :project_owner) == :ok
    end
  end
end
