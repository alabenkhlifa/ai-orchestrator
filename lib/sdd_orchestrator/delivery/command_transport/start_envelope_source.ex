defmodule SddOrchestrator.Delivery.CommandTransport.StartEnvelopeSource do
  @moduledoc """
  Builds the `start` envelope one stored command is delivered as.

  The outbox row records identities, a manifest digest, and a due time. It
  never records the manifest body, so the durable command on its own cannot
  say what the worker has to run. This rebuilds that body from the records the
  starting transaction wrote in the same commit: the run, its first attempt,
  and the version of the execution profile the repository's owner approved.

  Every part of the rebuild is checked before it is sent. The attempt has to be
  the one the command was enqueued for, and the rebuilt manifest has to produce
  the digest the command already carries. Any drift between what the starting
  transaction committed and what is read back now refuses the command instead
  of delivering it under instructions nobody approved. A refusal leaves the
  command queued, which is the same outcome as having no worker attached.

  Only a `start` command is built here. A continuation names a prior attempt
  number and a control command names a reason, and neither is recorded
  anywhere this could read it back from, so a resume, retry, cancel, or
  reconcile command stays queued rather than being delivered under a manifest
  or a payload this cannot prove.

  Two manifest fields have no record of their own: the agent and worker
  references. The product's start path supplies neither, so they are rebuilt
  empty exactly as it left them, and the digest comparison is what catches it
  if that ever stops being true.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport.EnvelopeSource

  alias SddOrchestrator.Accounts.PersonalWorkspace

  alias SddOrchestrator.Delivery.{
    DeliveryStore,
    ExecutionManifest,
    ExecutionProfile,
    RunCommand,
    WorkerProtocol
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @impl true
  def envelope(%RunCommand{operation: "start"} = command) do
    with {:ok, authority} <- authority(command.project_id),
         {:ok, run} <- fetch_run(authority, command),
         {:ok, attempt} <- fetch_attempt(authority, command),
         {:ok, manifest} <- rebuild_manifest(authority, run, attempt),
         :ok <- confirm_digest(manifest, command) do
      {:ok, build(command, run, attempt, manifest)}
    end
  end

  def envelope(%RunCommand{}), do: {:error, :unsupported_operation}

  # Authority comes from the project, exactly as the worker gateway resolves
  # it, never from the command. A device-authoritative project keeps its
  # delivery records on its own machine, so nothing here can read them back,
  # and it resolves to no authority rather than to a hosted lookup.
  defp authority(project_id) do
    case Repo.get(Project, project_id) do
      %Project{storage_mode: "hosted", workspace_id: workspace_id} -> workspace(workspace_id)
      _other -> {:error, :authority_unavailable}
    end
  rescue
    Ecto.Query.CastError -> {:error, :authority_unavailable}
  end

  defp workspace(workspace_id) do
    case Repo.get(PersonalWorkspace, workspace_id) do
      %PersonalWorkspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :authority_unavailable}
    end
  end

  defp fetch_run(authority, command) do
    case DeliveryStore.fetch_run(authority, command.project_id, command.run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, :run_unavailable}
    end
  end

  # The attempt the command was enqueued for, and never whichever attempt is
  # current now. A command that outlived its attempt must not be delivered
  # against a later one's fence token.
  defp fetch_attempt(authority, command) do
    case DeliveryStore.current_attempt(authority, command.project_id, command.run_id) do
      {:ok, attempt} -> confirm_attempt(attempt, command)
      :error -> {:error, :attempt_unavailable}
    end
  end

  defp confirm_attempt(attempt, command) do
    if attempt.id == command.attempt_id do
      {:ok, attempt}
    else
      {:error, :attempt_superseded}
    end
  end

  # The execution contract comes from the profile the repository's owner
  # approved, read through the one place every continuation reads it, so a
  # delivered start and a continued attempt cannot drift into two different
  # contracts for the same repository.
  defp rebuild_manifest(authority, run, attempt) do
    with {:ok, profile_fields} <- ExecutionProfile.manifest_fields(authority, run.project_id) do
      %{
        "manifest_version" => ExecutionManifest.manifest_version(),
        "project_id" => run.project_id,
        "feature_id" => run.feature_id,
        "run_id" => run.id,
        "attempt_number" => attempt.attempt_number,
        "approved_slice" => run.approved_slice,
        "starting_revision_id" => run.starting_revision_id,
        "starting_revision_digest" => run.starting_revision_digest,
        "effective_revision_id" => attempt.effective_revision_id,
        "effective_revision_digest" => attempt.effective_revision_digest,
        "target_branch" => run.branch,
        "agent_ref" => %{},
        "worker_ref" => %{},
        "continuation" => %{
          "reason" => attempt.continuation_reason,
          "prior_attempt_number" => nil
        }
      }
      |> Map.merge(profile_fields)
      |> ExecutionManifest.new()
    end
  end

  defp confirm_digest(manifest, command) do
    if ExecutionManifest.digest(manifest) == command.manifest_digest do
      :ok
    else
      {:error, :manifest_digest_mismatch}
    end
  end

  defp build(command, run, attempt, manifest) do
    %{
      "type" => "command",
      "protocol_version" => WorkerProtocol.version(),
      "command_id" => command.id,
      "project_id" => command.project_id,
      "feature_id" => run.feature_id,
      "run_id" => command.run_id,
      "attempt_number" => attempt.attempt_number,
      "fence_token" => attempt.fence_token,
      "operation" => command.operation,
      "expected_state_version" => command.expected_state_version,
      "manifest_digest" => command.manifest_digest,
      "issued_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
    }
  end
end
