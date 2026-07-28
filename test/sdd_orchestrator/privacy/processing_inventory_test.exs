defmodule SddOrchestrator.Privacy.ProcessingInventoryTest do
  @moduledoc """
  Proof that the approved processing inventory is complete and purpose-limited:
  every personal-data activity is recorded with the required fields and an
  approved lawful basis, and no activity has an analytics purpose.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.DataProcessingRecord
  alias SddOrchestrator.Privacy.ProcessingInventory

  @required_activities ~w(
    github_identity application_session github_credential github_authorization_attempt
    hosted_identity external_identity magic_link_attempt passwordless_email_delivery
    hosted_session passwordless_abuse_control
    personal_workspace workspace hosted_project_storage
    hosted_local_repository_binding
    project_package import_attempt restore_operation package_provenance
    project_and_repository_connection project_onboarding_attempt
    project_specification_storage
    operational_security_log
  )a

  test "covers every personal-data activity in the slice" do
    for activity <- @required_activities do
      assert activity in ProcessingInventory.activities(),
             "processing inventory is missing #{activity}"
    end
  end

  test "each record has a purpose, lawful basis, personal-data fields, and lifecycle" do
    for record <- ProcessingInventory.records() do
      assert record.purpose not in [nil, ""]
      assert record.lawful_basis in DataProcessingRecord.lawful_bases()
      assert is_list(record.personal_data) and record.personal_data != []
      assert record.access not in [nil, ""]
      assert record.retention not in [nil, ""]
      assert record.rights not in [nil, ""]
      assert is_list(record.processors)
      assert record.transfers not in [nil, ""]
      assert record.review not in [nil, ""]
    end
  end

  test "declares no analytics, advertising, or model-training purpose (AC-41)" do
    refute ProcessingInventory.analytics?()

    for record <- ProcessingInventory.records() do
      refute String.contains?(String.downcase(record.purpose), [
               "analytic",
               "advertis",
               "model training"
             ])
    end
  end

  test "the storage-selection attempt retains only minimized proof digests and source-approved metadata (Slice 05 AC-12, AC-17)" do
    attempt =
      Enum.find(ProcessingInventory.records(), &(&1.activity == :project_onboarding_attempt))

    data = attempt.personal_data |> Enum.join(" ") |> String.downcase()

    # Only proof digests persist; the hosted boundary carries no raw proof, device
    # label, path, or credential.
    assert data =~ "digest"
    assert data =~ "fingerprint"
    refute data =~ "raw"
    refute data =~ "device label"
    refute data =~ "path"
    refute data =~ "token"

    # Terminal attempts and their proof bindings are deleted within 24 hours.
    assert String.downcase(attempt.retention) =~ "24 hours"
  end

  test "treats hashed and stable authentication identifiers as personal data" do
    authentication_data =
      ProcessingInventory.records()
      |> Enum.filter(
        &(&1.activity in [
            :external_identity,
            :magic_link_attempt,
            :hosted_session,
            :passwordless_abuse_control
          ])
      )
      |> Enum.flat_map(& &1.personal_data)
      |> Enum.join(" ")
      |> String.downcase()

    assert authentication_data =~ "subject"
    assert authentication_data =~ "digest"
    assert authentication_data =~ "hmac"
    refute authentication_data =~ "anonymous identifier"
  end

  test "the hosted local repository binding is minimized and lifecycle-bound" do
    binding =
      Enum.find(
        ProcessingInventory.records(),
        &(&1.activity == :hosted_local_repository_binding)
      )

    assert binding.personal_data == [
             "project id",
             "worker id",
             "last successful validation time"
           ]

    lifecycle = String.downcase(binding.retention)
    assert lifecycle =~ "disconnect"
    assert lifecycle =~ "worker revocation"
    assert lifecycle =~ "replacement"
    assert lifecycle =~ "project erasure"
    assert lifecycle =~ "service termination"
    assert lifecycle =~ "35 days"

    contract =
      [
        binding.purpose,
        binding.access,
        binding.retention,
        binding.rights,
        binding.transfers
      ]
      |> Enum.join(" ")
      |> String.downcase()

    refute contract =~ "repository path"
    refute contract =~ "credential"
    refute contract =~ "device label"
    refute contract =~ "compatibility"
    refute contract =~ "repository identifier"
  end
end
