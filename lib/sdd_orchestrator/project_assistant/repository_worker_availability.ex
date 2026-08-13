defmodule SddOrchestrator.ProjectAssistant.RepositoryWorkerAvailability do
  @moduledoc """
  Reports only whether a repository worker exists for one project, for the
  disclosed processing summary's "may a repository worker be used" boundary.

  This module never observes anything: it reuses the existing worker
  reachability signal each storage authority already publishes rather than
  inventing a new one.

    * Hosted: `SddOrchestrator.Portability.HostedLocalRepositoryBindings.connection_state/3`
      reports whether the project's bound local worker is currently
      `:connected`, `:temporarily_unavailable`, or the project has no
      binding at all (`:disconnected`).
    * Device: `SddOrchestrator.Devices.worker_status/1` reports whether the
      owning device workspace has an active, compatible, reachable local
      worker paired to it (`:detected`), matching every other device
      onboarding surface's reachability check.

  The actual bounded tree, search, and line-read observation adapter this
  boolean gates belongs to Task 4; this module only answers "may a worker be
  used right now," not "what does it see."
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings

  @doc "Whether a currently reachable repository worker exists for this project."
  @spec available?(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) :: boolean()
  def available?(%PersonalWorkspace{} = authority, project_id) do
    case HostedLocalRepositoryBindings.connection_state(authority, project_id) do
      {:ok, %{state: :connected}} -> true
      _otherwise -> false
    end
  end

  def available?(%DeviceWorkspace{id: workspace_id}, _project_id) do
    Devices.worker_status(workspace_id) == :detected
  end

  def available?(_authority, _project_id), do: false
end
