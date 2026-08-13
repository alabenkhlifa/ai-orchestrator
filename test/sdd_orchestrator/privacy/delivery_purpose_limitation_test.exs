defmodule SddOrchestrator.Privacy.DeliveryPurposeLimitationTest do
  @moduledoc """
  Task 4 proof for specs/18 (AC-05): Slice 07 guided-delivery storage,
  requests, events, metrics, and identifiers carry no product analytics,
  advertising, model-training reuse, unrelated improvement, or other
  secondary use, and operational telemetry remains governed personal data
  rather than anonymous analytics.

  This does not re-prove Task 1's field-level classification (AC-01,
  `DeliveryProcessingInventoryTest`) or the legacy processing inventory's own
  contract (`ProcessingInventoryTest`, `AnalyticsAbsenceTest`); it proves the
  purpose-limitation and secondary-use boundary drawn across both.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.DeliveryDataUsePolicy, as: Policy
  alias SddOrchestrator.Privacy.DeliveryProcessingInventory, as: Inventory
  alias SddOrchestrator.Privacy.DeliveryProcessingRecord, as: Record
  alias SddOrchestrator.Privacy.ProcessingInventory

  @delivery_entities ~w(
    feature readiness_assessment agent_run run_attempt run_command
    blocking_question activity_entry evidence evidence_artifact
    preview_deployment review_decision processing_confirmation
    account_notification
  )a

  @all_consumers [
    :current_participant,
    :worker_runtime,
    :model_provider,
    :preview_provider,
    :approved_operations,
    :verified_rights_operator
  ]

  @analytics_shaped ["analytic", "advertis", "model training"]

  # --- store, request, event, and metric negative contract -----------------
  #
  # Task 1's inventory holds one record per persisted field across every
  # Slice 07 schema (and the delivery-namespace notification foundation), so
  # scanning its purposes covers every store, request, event, and metric this
  # slice produces: there is no separate analytics table, outbound request,
  # emitted event, or metric that would fall outside this enumeration.
  describe "store, request, event, and metric negative contract" do
    test "no persisted Slice 07 field states a prohibited purpose" do
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
             "a Slice 07 field is classified under a non-contract-necessity basis"
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

      for identifier <- [
            :user,
            :account,
            :project,
            :feature,
            :run,
            :repository,
            :worker,
            :provider,
            :device,
            :content,
            :network,
            :stable_pseudonymous_identifier
          ] do
        assert identifier in boundary.prohibited_identifiers,
               "#{identifier} is missing from the prohibited-identifier boundary"
      end
    end
  end

  # --- advertising and model-training denial --------------------------------
  describe "advertising denial" do
    test "advertising is refused for every data class and every consumer, including provider consumers" do
      for data_class <- Policy.data_classes(), consumer <- @all_consumers do
        assert Policy.authorize(data_class, :advertising, consumer) ==
                 {:error, :secondary_use_prohibited},
               "#{data_class} authorized :advertising for #{consumer}"
      end
    end
  end

  describe "model-training denial" do
    test "model training reuse is refused for every data class and every consumer, including provider consumers" do
      for data_class <- Policy.data_classes(), consumer <- @all_consumers do
        assert Policy.authorize(data_class, :model_training, consumer) ==
                 {:error, :secondary_use_prohibited},
               "#{data_class} authorized :model_training for #{consumer}"
      end
    end

    test "a preview or execution route never doubles as a training route" do
      assert Policy.authorize(:run_command, :model_training, :model_provider) ==
               {:error, :secondary_use_prohibited}

      assert Policy.authorize(:preview_deployment, :model_training, :preview_provider) ==
               {:error, :secondary_use_prohibited}
    end
  end

  describe "unrelated improvement and identity-tracking denial" do
    test "unrelated product improvement and identity tracking are refused for every data class" do
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

    test "model_provider and preview_provider are not blanket-prohibited, unlike a fixed-prohibition consumer" do
      refute :model_provider in Policy.prohibited_consumers()
      refute :preview_provider in Policy.prohibited_consumers()
    end

    test "an execution manifest legitimately reaches the worker and the model it dispatches to" do
      assert Policy.authorize(:run_command, :worker_dispatch, :worker_runtime) == :ok
      assert Policy.authorize(:run_command, :worker_dispatch, :model_provider) == :ok
    end

    test "a preview legitimately reaches only the configured preview provider" do
      assert Policy.authorize(:preview_deployment, :preview_deployment, :preview_provider) == :ok
    end

    test "the model and preview provider are still refused outside their one approved route" do
      assert Policy.authorize(:feature, :feature_delivery, :model_provider) ==
               {:error, :not_authorized}

      assert Policy.authorize(:preview_deployment, :feature_delivery, :model_provider) ==
               {:error, :not_authorized}

      assert Policy.authorize(:run_command, :worker_dispatch, :preview_provider) ==
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

    test "operational_security remains an approved Slice 07 basis, currently unused by any field" do
      assert :operational_security in Record.bases()
      refute Enum.any?(Inventory.records(), &(&1.basis == :operational_security))
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
      assert Policy.authorize(:feature, :feature_delivery, :current_participant) == :ok

      assert Policy.authorize(:readiness_assessment, :feature_delivery, :current_participant) ==
               :ok

      assert Policy.authorize(:agent_run, :feature_delivery, :current_participant) == :ok
      assert Policy.authorize(:run_attempt, :worker_dispatch, :worker_runtime) == :ok
      assert Policy.authorize(:run_command, :worker_dispatch, :model_provider) == :ok
      assert Policy.authorize(:blocking_question, :worker_dispatch, :worker_runtime) == :ok
      assert Policy.authorize(:activity_entry, :feature_delivery, :current_participant) == :ok
      assert Policy.authorize(:evidence, :feature_delivery, :current_participant) == :ok
      assert Policy.authorize(:evidence_artifact, :feature_delivery, :current_participant) == :ok
      assert Policy.authorize(:preview_deployment, :preview_deployment, :preview_provider) == :ok
      assert Policy.authorize(:review_decision, :feature_delivery, :current_participant) == :ok

      assert Policy.authorize(
               :processing_confirmation,
               :compliance_evidence,
               :approved_operations
             ) ==
               :ok

      assert Policy.authorize(:account_notification, :notification_delivery, :current_participant) ==
               :ok

      for data_class <- Policy.data_classes() do
        assert Policy.authorize(data_class, :retention_cleanup, :approved_operations) == :ok
        assert Policy.authorize(data_class, :verified_rights, :verified_rights_operator) == :ok
      end

      assert Policy.authorize(:feature, :feature_delivery, :approved_operations) ==
               {:error, :not_authorized}

      assert Policy.authorize(:run_command, :worker_dispatch, :current_participant) ==
               {:error, :not_authorized}

      assert Policy.authorize(
               :processing_confirmation,
               :compliance_evidence,
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
      assert Enum.sort(classes) == Enum.sort(@delivery_entities)

      for data_class <- classes do
        assert Policy.authorize(data_class, :model_training, :approved_operations) ==
                 {:error, :secondary_use_prohibited}
      end

      # An unknown class, purpose, or consumer is refused rather than defaulted to anything.
      assert Policy.authorize(:unknown_class, :feature_delivery, :current_participant) ==
               {:error, :not_authorized}

      assert Policy.authorize(:feature, :unknown_purpose, :current_participant) ==
               {:error, :not_authorized}

      assert Policy.authorize(:feature, :feature_delivery, :unknown_consumer) ==
               {:error, :not_authorized}

      # And a genuine downstream route is served, so the capability is usable.
      assert Policy.authorize(:feature, :feature_delivery, :current_participant) == :ok
    end
  end
end
