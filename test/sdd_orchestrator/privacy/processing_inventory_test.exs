defmodule SddOrchestrator.Privacy.ProcessingInventoryTest do
  @moduledoc """
  Proof that the approved Slice 01 processing inventory is complete and purpose-
  limited (Task 10): every personal-data activity is recorded with the required
  fields and an approved lawful basis, and no activity has an analytics purpose.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.DataProcessingRecord
  alias SddOrchestrator.Privacy.ProcessingInventory

  @required_activities ~w(
    github_identity application_session github_credential github_authorization_attempt
    personal_workspace project_and_repository_connection project_onboarding_attempt
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
end
