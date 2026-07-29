defmodule SddOrchestrator.Privacy.PortabilityPrivacyReviewTest do
  @moduledoc """
  Task 7 consolidated privacy and security review for project portability.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Portability.SecurityLog

  alias SddOrchestrator.Privacy.{
    DataProcessingRecord,
    DeploymentPrivacyProfile,
    PortabilityDataUsePolicy,
    ProcessingInventory
  }

  @portability_activities [
    :project_package,
    :import_attempt,
    :restore_operation,
    :package_provenance,
    :hosted_local_repository_binding,
    :operational_security_log
  ]

  test "inventories every active portability processing boundary" do
    records = Map.new(ProcessingInventory.records(), &{&1.activity, &1})

    for activity <- @portability_activities do
      assert %DataProcessingRecord{} = record = Map.fetch!(records, activity)
      assert record.purpose not in [nil, ""]
      assert record.personal_data != []
      assert record.access not in [nil, ""]
      assert record.retention not in [nil, ""]
      assert record.rights not in [nil, ""]
      assert record.processors != []
      assert record.transfers not in [nil, ""]
      assert record.review not in [nil, ""]
    end

    assert records.operational_security_log.lawful_basis == :legitimate_interests

    for activity <- @portability_activities -- [:operational_security_log] do
      assert records[activity].lawful_basis == :contract
    end
  end

  test "keeps package, temporary, binding, provenance, and log records minimized" do
    records = Map.new(ProcessingInventory.records(), &{&1.activity, &1})

    assert records.hosted_local_repository_binding.personal_data == [
             "project id",
             "worker id",
             "last successful validation time"
           ]

    assert records.package_provenance.personal_data == [
             "project id",
             "payload schema version",
             "restoration time"
           ]

    assert records.operational_security_log.personal_data == [
             "event type",
             "timestamp",
             "outcome class",
             "internal correlation id"
           ]

    assert Map.keys(%SecurityLog.Event{
             event_type: :restore_intake,
             occurred_at: "2026-07-28T00:00:00Z",
             outcome: :succeeded,
             correlation_id: Ecto.UUID.generate()
           })
           |> Enum.sort() ==
             [:__struct__, :correlation_id, :event_type, :occurred_at, :outcome]
  end

  test "aligns immediate, 24-hour, 30-day, and 35-day lifecycle controls" do
    records = Map.new(ProcessingInventory.records(), &{&1.activity, &1})

    assert records.project_package.retention =~ "No completed service copy"
    assert records.restore_operation.retention =~ "discarded immediately"
    assert records.import_attempt.retention =~ "within 24 hours"
    assert records.operational_security_log.retention == "Deleted after 30 days."

    assert SecurityLog.retention_days() == 30

    assert DeploymentPrivacyProfile.retention_requirements() == %{
             operational_security_logs_days: 30,
             encrypted_rolling_backups_days: 35
           }

    assert DeploymentPrivacyProfile.backup_handoff(:erasure) == %{
             action: :erasure,
             deletion_propagation: :required,
             maximum_expiry_days: 35,
             restore_scope: :approved_recovery_only
           }
  end

  test "limits access to approved service, worker, operations, and rights recipients" do
    assert :ok =
             PortabilityDataUsePolicy.authorize(
               :hosted_local_repository_binding,
               :repository_routing,
               :authorized_device_worker
             )

    assert :ok =
             PortabilityDataUsePolicy.authorize(
               :operational_security_log,
               :security_operations,
               :approved_operations
             )

    for data_class <- PortabilityDataUsePolicy.data_classes(),
        consumer <- [:coding_agent, :model_provider] do
      assert {:error, :consumer_prohibited} =
               PortabilityDataUsePolicy.authorize(data_class, :restore_validation, consumer)
    end

    refute ProcessingInventory.analytics?()
  end

  test "keeps unresolved deployment facts in the public release gate" do
    profile = DeploymentPrivacyProfile.new(%{})

    assert {:error, {:incomplete, missing}} =
             DeploymentPrivacyProfile.ensure_backup_release_ready(profile)

    assert :processors in missing
    assert :hosting_regions in missing
    assert :transfer_safeguards in missing
    assert :privacy_notice in missing
    assert :incident_path in missing
    assert :retention_enforcement in missing
    assert :reviews in missing
    assert :encrypted_backup_configuration in missing

    contract = DeploymentPrivacyProfile.backup_lifecycle_contract()
    assert contract.evidence_stage == :release
    assert contract.enforcement == :deployment_infrastructure
  end
end
