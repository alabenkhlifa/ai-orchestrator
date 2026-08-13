defmodule SddOrchestrator.ProjectAssistantBoundaryStore do
  @moduledoc """
  Shared authoritative store for one participant's current
  `AssistantBoundaryConfirmation` per project.

  Mirrors `SddOrchestrator.ProjectAssistantStore` exactly: hosted and device
  authorities implement the same logical operations behind one dispatch,
  every operation revalidates the acting participant's current project
  participation on its own call, and an unsupported authority, an
  unauthorized actor, and a nonexistent project all fail the same way.

  There is at most one current confirmation per participant per project.
  Confirming again replaces the stored digest, version, and confirmation
  time in place; it never appends a second row or a history entry.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}

  alias SddOrchestrator.ProjectAssistant.{
    AssistantBoundaryConfirmation,
    DeviceAssistantBoundaryConfirmation,
    Guard
  }

  alias SddOrchestrator.ProjectAssistant.ProjectAssistantBoundaryStore.{Device, Hosted}

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: Guard.actor()
  @type confirmation ::
          AssistantBoundaryConfirmation.t() | DeviceAssistantBoundaryConfirmation.t()

  @doc "Returns the acting participant's current confirmation, or `nil` if none exists."
  @spec get_confirmation(authority(), String.t(), actor()) ::
          {:ok, confirmation() | nil} | {:error, :unauthorized}
  def get_confirmation(%PersonalWorkspace{} = authority, project_id, actor),
    do: Hosted.get_confirmation(authority, project_id, actor)

  def get_confirmation(%DeviceWorkspace{} = authority, project_id, actor),
    do: Device.get_confirmation(authority, project_id, actor)

  def get_confirmation(_authority, _project_id, _actor), do: {:error, :unauthorized}

  @doc """
  Records the acting participant's confirmation of one disclosed processing
  boundary, replacing any prior confirmation for this participant and
  project.
  """
  @spec confirm(authority(), String.t(), actor(), String.t(), pos_integer(), DateTime.t()) ::
          {:ok, confirmation()} | {:error, :unauthorized | term()}
  def confirm(
        %PersonalWorkspace{} = authority,
        project_id,
        actor,
        boundary_digest,
        boundary_version,
        confirmed_at
      ),
      do:
        Hosted.confirm(
          authority,
          project_id,
          actor,
          boundary_digest,
          boundary_version,
          confirmed_at
        )

  def confirm(
        %DeviceWorkspace{} = authority,
        project_id,
        actor,
        boundary_digest,
        boundary_version,
        confirmed_at
      ),
      do:
        Device.confirm(
          authority,
          project_id,
          actor,
          boundary_digest,
          boundary_version,
          confirmed_at
        )

  def confirm(
        _authority,
        _project_id,
        _actor,
        _boundary_digest,
        _boundary_version,
        _confirmed_at
      ),
      do: {:error, :unauthorized}
end
