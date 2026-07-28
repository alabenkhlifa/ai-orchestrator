defmodule SddOrchestrator.Portability.SecurityLogTest do
  @moduledoc """
  Task 18 proof for fixed, minimized, redacted portability security events and
  their 30-day deployment expiry contract.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Accounts.PersonalWorkspace

  alias SddOrchestrator.Portability.{
    GitHubReconnection,
    HostedLocalRepositoryReconnection,
    HostedRestore,
    LocalRepositoryReconnection,
    RestoreIntake,
    SecurityLog
  }

  alias SddOrchestrator.Portability.SecurityLog.Event
  alias SddOrchestrator.Privacy.DeploymentPrivacyProfile

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  test "emits exactly the fixed event type, time, outcome, and correlation identifier" do
    correlation_id = "0198a4b6-37f2-7a90-9fc7-37b6f8d5a101"
    occurred_at = ~U[2026-07-28 12:34:56Z]

    log =
      capture_log([level: :info], fn ->
        assert {:ok, :restored} =
                 SecurityLog.audit({:ok, :restored}, :restore_commit,
                   correlation_id: correlation_id,
                   occurred_at: occurred_at
                 )
      end)

    assert event_from(log) == %{
             "correlation_id" => correlation_id,
             "event_type" => "restore_commit",
             "occurred_at" => "2026-07-28T12:34:56Z",
             "outcome" => "succeeded"
           }

    assert Map.keys(%Event{
             event_type: :restore_commit,
             occurred_at: "2026-07-28T12:34:56Z",
             outcome: :succeeded,
             correlation_id: correlation_id
           })
           |> Enum.sort() ==
             [:__struct__, :correlation_id, :event_type, :occurred_at, :outcome]
  end

  test "uses coarse outcomes and drops supplied secret, content, binding, and environment data" do
    marker = "forbidden-marker-#{System.unique_integer([:positive])}"

    unsafe_result =
      {:error,
       %{
         package: marker,
         project_content: marker,
         repository_id: marker,
         binding: marker,
         worker_id: marker,
         device_workspace_id: marker,
         filename: marker,
         path: marker,
         passphrase: marker,
         decrypted: marker,
         credential: marker
       }}

    log =
      capture_log(fn ->
        assert ^unsafe_result =
                 SecurityLog.audit(unsafe_result, :repository_reconnection,
                   correlation_id: marker,
                   occurred_at: marker,
                   project_id: marker,
                   diagnostic: marker
                 )
      end)

    event = event_from(log)
    assert event["event_type"] == "repository_reconnection"
    assert event["outcome"] == "failed"
    assert {:ok, _uuid} = Ecto.UUID.cast(event["correlation_id"])
    assert event["occurred_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    refute log =~ marker

    for forbidden <- [
          "project_id",
          "repository_id",
          "binding",
          "worker_id",
          "device_workspace_id",
          "filename",
          "path",
          "passphrase",
          "decrypted",
          "credential"
        ] do
      refute Map.has_key?(event, forbidden)
    end
  end

  test "classifies conflicts, rejections, and cancellation without logging error terms" do
    conflict_log =
      capture_log(fn ->
        SecurityLog.audit({:error, :repository_conflict}, :restore_commit)
      end)

    rejected_log =
      capture_log(fn ->
        SecurityLog.audit({:error, :authorization_required}, :restore_validation)
      end)

    cancelled_log =
      capture_log([level: :info], fn ->
        SecurityLog.audit(:ok, :restore_cancellation)
      end)

    assert event_from(conflict_log)["outcome"] == "blocked"
    assert event_from(rejected_log)["outcome"] == "rejected"
    assert event_from(cancelled_log)["outcome"] == "cancelled"
    refute conflict_log =~ "repository_conflict"
    refute rejected_log =~ "authorization_required"
  end

  test "generates a fresh non-secret correlation identifier for each event" do
    log =
      capture_log([level: :info], fn ->
        SecurityLog.audit(:ok, :restore_completion_cleanup)
        SecurityLog.audit(:ok, :restore_completion_cleanup)
      end)

    [first, second] = events_from(log)
    refute first["correlation_id"] == second["correlation_id"]
    assert {:ok, _first_uuid} = Ecto.UUID.cast(first["correlation_id"])
    assert {:ok, _second_uuid} = Ecto.UUID.cast(second["correlation_id"])
  end

  test "integrated invalid intake, restore, and reconnection paths never inspect their inputs" do
    marker = "failure-input-marker-#{System.unique_integer([:positive])}"
    workspace = %PersonalWorkspace{id: Ecto.UUID.generate()}

    log =
      capture_log(fn ->
        assert {:error, :unauthorized_destination} =
                 RestoreIntake.start(workspace, "device", marker)

        assert {:error, :invalid_restore} =
                 HostedRestore.restore(marker, marker, marker, marker)

        assert {:error, :invalid_request} =
                 GitHubReconnection.connect(marker, marker, marker)

        assert {:error, :invalid_request} =
                 LocalRepositoryReconnection.connect(marker, marker, marker, marker)

        assert {:error, :invalid_request} =
                 HostedLocalRepositoryReconnection.connect(
                   marker,
                   marker,
                   marker,
                   marker,
                   marker
                 )
      end)

    assert length(events_from(log)) == 5
    refute log =~ marker
    refute log =~ workspace.id
  end

  test "binds operational-security logs to the approved 30-day expiry configuration" do
    assert SecurityLog.retention_days() == 30

    assert DeploymentPrivacyProfile.retention_requirements() == %{
             operational_security_logs_days: 30,
             encrypted_rolling_backups_days: 35
           }

    assert SecurityLog.events() == [
             :backup_generation,
             :repository_disconnection,
             :repository_reconnection,
             :restore_cancellation,
             :restore_commit,
             :restore_completion_cleanup,
             :restore_failure_cleanup,
             :restore_intake,
             :restore_validation
           ]
  end

  defp event_from(log) do
    assert [event] = events_from(log)
    event
  end

  defp events_from(log) do
    ~r/\[portability_security\] (\{.*\})/
    |> Regex.scan(log, capture: :all_but_first)
    |> Enum.map(fn [json] -> Jason.decode!(json) end)
  end
end
