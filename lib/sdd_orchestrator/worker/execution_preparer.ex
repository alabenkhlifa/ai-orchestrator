defmodule SddOrchestrator.Worker.ExecutionPreparer do
  @moduledoc """
  Turns an accepted `start` command into a proven, isolated place to run.

  Composes three already-proven primitives in order — manifest reconstruction,
  branch isolation (which itself proves and creates the run workspace), and the
  single-process attempt lease — and stops at the first refusal. Nothing here
  launches a process: a refusal at any step simply means no workspace, no
  branch, and no lock exist for this attempt yet, which is what "refused
  before any process exists" means for this task's scope.

  On success this is also the one place that builds the `workspace_ready`
  event — the only event this worker may emit outside the agent's own
  observation loop (Task 8) — and records its sequence as the attempt's first
  in `SddOrchestrator.Worker.RunState`, written before the event is ever
  handed back to a caller for delivery, matching
  `SddOrchestrator.Worker.CommandHandler`'s own persist-before-push order.
  """

  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.Worker.Branch
  alias SddOrchestrator.Delivery.Worker.ProcessLock
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Worker.RunState

  @doc """
  Prepares the isolated workspace and branch for an accepted command envelope
  and returns the `workspace_ready` event to deliver, or the reason execution
  cannot proceed.
  """
  @spec prepare(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def prepare(envelope, home_override \\ nil) do
    with {:ok, manifest} <- ProtocolCodec.manifest(envelope),
         {:ok, branch} <- Branch.prepare(manifest),
         {:ok, _lock} <- ProcessLock.acquire(manifest, envelope["fence_token"]),
         :ok <- record_first_sequence(home_override) do
      {:ok, workspace_ready_event(envelope, branch)}
    end
  end

  # Written before the event is returned for delivery, so a crash between
  # persisting and pushing leaves a durable record a redelivery can reconcile
  # rather than losing the fact that sequence 1 was already produced.
  defp record_first_sequence(home_override) do
    case RunState.load(home_override) do
      {:ok, %{current: %RunState{} = current} = snapshot} ->
        updated = %{snapshot | current: %{current | last_sequence: 1}}
        RunState.store(updated, home_override)

      {:ok, %{current: nil}} ->
        {:error, :local_run_state_unavailable}

      {:error, _reason} ->
        {:error, :local_run_state_unavailable}
    end
  end

  defp workspace_ready_event(envelope, %Branch{} = branch) do
    %{
      "type" => "event",
      "protocol_version" => envelope["protocol_version"],
      "event_id" => WorkerProtocol.generate_id(),
      "run_id" => envelope["run_id"],
      "command_id" => envelope["command_id"],
      "attempt_number" => envelope["attempt_number"],
      "fence_token" => envelope["fence_token"],
      "sequence" => 1,
      "event_type" => "workspace_ready",
      "source" => "worker",
      "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "payload" => %{
        "branch" => branch.name,
        "base_revision" => branch.base_revision,
        "reused" => branch.reused?
      }
    }
  end
end
