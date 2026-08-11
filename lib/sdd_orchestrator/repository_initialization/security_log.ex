defmodule SddOrchestrator.RepositoryInitialization.SecurityLog do
  @moduledoc """
  Fixed, content-free security outcomes for the empty-repository
  pre-project and build boundary (specs/16 Task 7).

  Events never contain a plan, run, or result value — no target reference,
  purpose/users/first_outcome/constraints/technical-foundation answer, kit
  choice, worker id, commit sha, or tree digest. Deployment logging
  infrastructure applies the approved 30-day expiry
  (`DeploymentPrivacyProfile.retention_requirements/0`'s
  `operational_security_logs_days`).
  """

  require Logger

  @events [:confirm_plan, :start_run, :build, :publish, :handoff]

  @doc "The fixed set of audited events."
  @spec events() :: [atom()]
  def events, do: @events

  @doc """
  Logs one redacted outcome class for a failed call and returns `result`
  unchanged. A success (`{:ok, _}`) is never logged.
  """
  @spec audit(term(), atom()) :: term()
  def audit({:error, reason} = result, event) when event in @events do
    log(event, reason)
    result
  end

  def audit({:error, reason, _entity} = result, event) when event in @events do
    log(event, reason)
    result
  end

  def audit(result, event) when event in @events, do: result

  defp log(event, reason) do
    Logger.warning(
      "[repository_initialization_security] event=#{event} outcome=#{outcome(reason)}"
    )
  end

  defp outcome(%Ecto.Changeset{}), do: "validation_rejected"

  defp outcome(reason)
       when reason in [
              :invalid_request,
              :invalid_snapshot,
              :invalid_manifest,
              :plan_not_ready,
              :plan_not_confirmed,
              :disclosure_required,
              :run_not_ready,
              :invalid_run,
              :kit_path_invalid,
              :kit_file_invalid,
              :mature_repository,
              :non_empty_directory
            ],
       do: "validation_rejected"

  defp outcome(reason)
       when reason in [
              :not_found,
              :capability_grant_denied,
              :kit_package_unavailable,
              :inaccessible,
              :workspace_root_unconfigured,
              :workspace_unavailable,
              :workspace_escape,
              :git_unavailable
            ],
       do: "denied_or_missing"

  defp outcome(reason)
       when reason in [
              :plan_changed,
              :target_changed,
              :target_symlinked,
              :target_permission_changed,
              :kit_file_tampered
            ],
       do: "identity_conflict"

  defp outcome(_reason), do: "operation_failed"
end
