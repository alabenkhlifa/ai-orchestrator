defmodule SddOrchestrator.DeliveryProtocolFixtures do
  @moduledoc false

  alias SddOrchestrator.Delivery.{ExecutionManifest, WorkerProtocol}

  @project_id "prj_01HZX0000000000000000001"
  @feature_id "ftr_01HZX0000000000000000002"
  @run_id "run_01HZX0000000000000000003"
  @command_id "cmd_01HZX0000000000000000004"
  @event_id "evt_01HZX0000000000000000005"
  @worker_id "wrk_01HZX0000000000000000006"
  @issued_at "2026-07-29T09:15:00Z"

  def project_id, do: @project_id
  def feature_id, do: @feature_id
  def run_id, do: @run_id
  def command_id, do: @command_id
  def worker_id, do: @worker_id
  def issued_at, do: @issued_at

  def manifest_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "manifest_version" => ExecutionManifest.manifest_version(),
        "project_id" => @project_id,
        "feature_id" => @feature_id,
        "run_id" => @run_id,
        "attempt_number" => 1,
        "approved_slice" => "07-guided-specification-delivery",
        "starting_revision_id" => "rev_01HZX0000000000000000007",
        "starting_revision_digest" => String.duplicate("a1", 32),
        "effective_revision_id" => "rev_01HZX0000000000000000007",
        "effective_revision_digest" => String.duplicate("a1", 32),
        "repository_base_revision" => "9f2c1ab4d5e6f708192a3b4c5d6e7f8091a2b3c4",
        "target_branch" => "sdd/feature/ftr-0002/run-0003",
        "required_checks" => [
          %{"name" => "format", "command" => "mix format --check-formatted"},
          %{"name" => "test", "command" => "mix test"}
        ],
        "agent_ref" => %{"provider_ref" => "configured-agent", "model_ref" => "configured-model"},
        "worker_ref" => %{"execution_target_ref" => "configured-local-worker"},
        "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil}
      },
      Map.new(overrides)
    )
  end

  def manifest(overrides \\ %{}) do
    {:ok, manifest} = overrides |> manifest_attrs() |> ExecutionManifest.new()
    manifest
  end

  def command(overrides \\ %{}) do
    manifest = manifest()

    Map.merge(
      %{
        "protocol_version" => WorkerProtocol.version(),
        "type" => "command",
        "command_id" => @command_id,
        "project_id" => @project_id,
        "feature_id" => @feature_id,
        "run_id" => @run_id,
        "attempt_number" => manifest.attempt_number,
        "operation" => "start",
        "expected_state_version" => 0,
        "manifest_digest" => ExecutionManifest.digest(manifest),
        "fence_token" => 1,
        "issued_at" => @issued_at,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      },
      Map.new(overrides)
    )
  end

  def cancel_command(overrides \\ %{}) do
    command()
    |> Map.merge(%{
      "command_id" => "cmd_01HZX0000000000000000008",
      "operation" => "cancel",
      "expected_state_version" => 3,
      "payload" => %{"reason" => "participant canceled the run"}
    })
    |> Map.merge(Map.new(overrides))
  end

  def event(overrides \\ %{}) do
    Map.merge(
      %{
        "protocol_version" => WorkerProtocol.version(),
        "type" => "event",
        "event_id" => @event_id,
        "run_id" => @run_id,
        "attempt_number" => 1,
        "command_id" => @command_id,
        "sequence" => 1,
        "event_type" => "progress",
        "occurred_at" => "2026-07-29T09:15:30Z",
        "source" => "worker",
        "fence_token" => 1,
        "payload" => %{"summary" => "Prepared the isolated workspace"}
      },
      Map.new(overrides)
    )
  end

  def acknowledgement(overrides \\ %{}) do
    Map.merge(
      %{
        "protocol_version" => WorkerProtocol.version(),
        "type" => "acknowledgement",
        "command_id" => @command_id,
        "run_id" => @run_id,
        "attempt_number" => 1,
        "fence_token" => 1,
        "status" => "accepted",
        "reason" => nil,
        "acknowledged_at" => "2026-07-29T09:15:01Z"
      },
      Map.new(overrides)
    )
  end

  def heartbeat(overrides \\ %{}) do
    Map.merge(
      %{
        "protocol_version" => WorkerProtocol.version(),
        "type" => "heartbeat",
        "run_id" => @run_id,
        "attempt_number" => 1,
        "fence_token" => 1,
        "last_sequence" => 4,
        "worker_id" => @worker_id,
        "state" => "running",
        "observed_at" => "2026-07-29T09:16:00Z"
      },
      Map.new(overrides)
    )
  end

  def reconciliation_snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        "protocol_version" => WorkerProtocol.version(),
        "type" => "reconciliation_snapshot",
        "worker_id" => @worker_id,
        "observed_at" => "2026-07-29T09:17:00Z",
        "attempts" => [
          %{
            "run_id" => @run_id,
            "attempt_number" => 1,
            "command_id" => @command_id,
            "fence_token" => 1,
            "last_sequence" => 4,
            "branch" => "sdd/feature/ftr-0002/run-0003",
            "state" => "running"
          }
        ]
      },
      Map.new(overrides)
    )
  end

  def announcement(overrides \\ %{}) do
    Map.merge(
      %{
        "protocol_version" => WorkerProtocol.version(),
        "capabilities" => WorkerProtocol.capabilities()
      },
      Map.new(overrides)
    )
  end
end
