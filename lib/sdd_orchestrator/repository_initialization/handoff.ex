defmodule SddOrchestrator.RepositoryInitialization.Handoff do
  @moduledoc """
  Moves one successfully published empty-repository initialization into
  normal local-onboarding and project authority (specs/16 Task 6, AC-13).

  Continues directly from a `Publisher.publish/3` success: `target_path` by
  this point holds the committed repository Task 5 just published, which is
  what makes the portable repository identity computable at all (before
  publication the directory was still empty). This module never routes
  through `Delivery.AgentAdapter` — every step is deterministic filesystem,
  device-store, and control-plane work, matching how `StagingBuilder` and
  `Publisher` are also fully synchronous.

  Idempotency is gated purely by `result.onboarding_handoff_state`: once
  `"completed"`, every later call returns the same result immediately without
  touching the device store or hosted PostgreSQL again. Before that, a
  failure at any step returns `result` completely unchanged (still
  `"pending"`) rather than a partial or failed state — a genuine retry
  re-attempts the whole sequence from scratch, which is safe because no
  project exists yet on a genuine failure path (every step through
  `register_device_project/3` either has no side effect outside a fresh,
  disposable `ProjectOnboardingAttempt`, or fails before it).
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryInitialization.{Plan, Result, SpecificationRenderer}
  alias SddOrchestrator.SpecificationStore

  # A device-readiness receipt stays valid for this window. Duplicated from
  # `SddOrchestratorWeb.LocalOnboardingLive`'s own private `readiness_receipt/2`
  # (same shape, same TTL) rather than shared across task/spec boundaries —
  # this codebase's own established convention (see `StagingBuilderTest`'s own
  # comment on duplicating fixtures instead of sharing them).
  @readiness_ttl_seconds 15 * 60

  @type handoff_error ::
          :repository_identity_failed
          | :onboarding_attempt_failed
          | :repository_selection_failed
          | :readiness_receipt_failed
          | :storage_mode_failed
          | :project_registration_failed
          | :specification_creation_failed
          | :result_update_failed

  @doc """
  Completes the local-onboarding and specification handoff for one published
  result.

  Returns the already-completed `result` unchanged when the handoff already
  ran. Otherwise runs the full pipeline — portable repository identity,
  device onboarding attempt, storage selection, project registration, and
  the complete first specification revision — and returns `{:ok, result}`
  with `onboarding_handoff_state == "completed"`, or `{:error, reason,
  result}` with `result` untouched on any failure.
  """
  @spec complete(Result.t(), Plan.t(), DeviceWorkspace.t(), Path.t()) ::
          {:ok, Result.t()} | {:error, handoff_error(), Result.t()}
  def complete(
        %Result{onboarding_handoff_state: "completed"} = result,
        _plan,
        _workspace,
        _target_path
      ) do
    {:ok, result}
  end

  def complete(
        %Result{onboarding_handoff_state: "pending"} = result,
        %Plan{} = plan,
        %DeviceWorkspace{} = workspace,
        target_path
      )
      when is_binary(target_path) do
    name = Path.basename(target_path)

    with {:ok, fingerprint} <- identify_repository(target_path, workspace),
         {:ok, attempt} <- start_attempt(workspace),
         {:ok, attempt} <- select_repository(workspace, attempt, fingerprint, name),
         {:ok, attempt} <- record_receipt(workspace, attempt),
         {:ok, attempt} <- select_storage(workspace, attempt),
         {:ok, project} <- register_project(workspace, attempt, name),
         documents = SpecificationRenderer.render(plan),
         {:ok, specification} <- create_specification(workspace, project, result, documents),
         {:ok, updated} <- persist_handoff(result, project, specification) do
      {:ok, updated}
    else
      {:error, reason} -> {:error, reason, result}
    end
  end

  ## Pipeline steps

  defp identify_repository(target_path, workspace) do
    case Devices.select_repository(target_path, workspace) do
      {:ok, %{fingerprint: fingerprint}} -> {:ok, fingerprint}
      {:error, _reason} -> {:error, :repository_identity_failed}
    end
  end

  defp start_attempt(workspace) do
    case Projects.start_device_onboarding_attempt(workspace) do
      {:ok, attempt} -> {:ok, attempt}
      {:error, _reason} -> {:error, :onboarding_attempt_failed}
    end
  end

  defp select_repository(workspace, attempt, fingerprint, name) do
    case Projects.select_local_repository(workspace, attempt.id, %{
           fingerprint: fingerprint,
           name: name
         }) do
      {:ok, attempt} -> {:ok, attempt}
      {:error, _reason} -> {:error, :repository_selection_failed}
    end
  end

  defp record_receipt(workspace, attempt) do
    case Projects.record_device_receipt(
           workspace,
           attempt.id,
           readiness_receipt(attempt, workspace)
         ) do
      {:ok, attempt} -> {:ok, attempt}
      {:error, _reason} -> {:error, :readiness_receipt_failed}
    end
  end

  defp select_storage(workspace, attempt) do
    case Projects.select_storage_mode(workspace, attempt.id, "device") do
      {:ok, attempt} -> {:ok, attempt}
      {:error, _reason} -> {:error, :storage_mode_failed}
    end
  end

  # `allocate_suffix?: true`: unlike `LocalOnboardingLive`'s own confirmed,
  # user-edited name (`false`, to protect it from silent renaming), this is a
  # fully automated flow with no user-edited name to protect — a workspace
  # name collision should just take the next available suffix.
  defp register_project(workspace, attempt, name) do
    case Projects.register_device_project(workspace, attempt, name: name, allocate_suffix?: true) do
      {:ok, project} -> {:ok, project}
      {:error, _reason} -> {:error, :project_registration_failed}
    end
  end

  # Reuses `result.id` as the specification's own id: a stable, already-unique
  # identifier with no new UUID generation needed, tying the published result
  # and its authoritative first specification 1:1.
  defp create_specification(workspace, project, result, documents) do
    attrs = %{id: result.id, title: "Initial specification", documents: documents}

    case SpecificationStore.create(workspace, project.id, attrs) do
      {:ok, %{specification: specification}} -> {:ok, specification}
      {:error, _reason} -> {:error, :specification_creation_failed}
    end
  end

  defp persist_handoff(result, project, specification) do
    result
    |> Result.handoff_changeset(%{
      project_id: project.id,
      specification_id: specification.id,
      onboarding_handoff_state: "completed"
    })
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :result_update_failed}
    end
  end

  defp readiness_receipt(attempt, workspace) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    DeviceStorageReceipt.issue(%{
      token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      attempt_id: attempt.id,
      device_workspace_id: workspace.id,
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      issued_at: now,
      expires_at: DateTime.add(now, @readiness_ttl_seconds, :second)
    })
  end
end
