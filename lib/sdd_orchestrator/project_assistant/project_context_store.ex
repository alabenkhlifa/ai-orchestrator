defmodule SddOrchestrator.ProjectAssistant.ProjectContextStore do
  @moduledoc """
  Shared authoritative store for one project's destination-local
  `ProjectContextProjection`.

  Hosted and device authorities implement the same logical operations behind
  one dispatch, mirroring `SddOrchestrator.ProjectAssistantStore` and
  `SddOrchestrator.SpecificationStore`. `refresh/3` assembles the current
  context through `SddOrchestrator.ProjectAssistant.ProjectContextAssembler`
  and replaces the project's single stored projection idempotently: a
  rebuild from unchanged underlying data produces the same
  `context_version` and leaves the stored row equivalent, never a second
  row. `get/3` and `delete/3` revalidate the same authorization the
  assembler itself checks — nothing here caches an authorization result
  across calls or serves a stored projection past the access it depended on.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.ParticipantGuard

  alias SddOrchestrator.ProjectAssistant.{
    DeviceProjectContextProjection,
    ProjectContextProjection
  }

  alias SddOrchestrator.ProjectAssistant.ProjectContextStore.{Device, Hosted}

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: ParticipantGuard.actor()
  @type projection :: ProjectContextProjection.t() | DeviceProjectContextProjection.t()

  @doc """
  Assembles the acting participant's currently authorized project context
  and replaces the project's one stored projection with it.
  """
  @spec refresh(authority(), String.t(), actor()) ::
          {:ok, projection()} | {:error, :unauthorized | term()}
  def refresh(%PersonalWorkspace{} = authority, project_id, actor),
    do: Hosted.refresh(authority, project_id, actor)

  def refresh(%DeviceWorkspace{} = authority, project_id, actor),
    do: Device.refresh(authority, project_id, actor)

  def refresh(_authority, _project_id, _actor), do: {:error, :unauthorized}

  @doc """
  Reads the project's current stored projection, or `nil` when none has been
  built yet. Revalidates the acting participant's current authorization
  exactly like `refresh/3` does.
  """
  @spec get(authority(), String.t(), actor()) ::
          {:ok, projection() | nil} | {:error, :unauthorized}
  def get(%PersonalWorkspace{} = authority, project_id, actor),
    do: Hosted.get(authority, project_id, actor)

  def get(%DeviceWorkspace{} = authority, project_id, actor),
    do: Device.get(authority, project_id, actor)

  def get(_authority, _project_id, _actor), do: {:error, :unauthorized}

  @doc """
  Immediately deletes the project's stored projection. Idempotent: deleting
  an already-absent projection still succeeds.
  """
  @spec delete(authority(), String.t(), actor()) :: :ok | {:error, :unauthorized}
  def delete(%PersonalWorkspace{} = authority, project_id, actor),
    do: Hosted.delete(authority, project_id, actor)

  def delete(%DeviceWorkspace{} = authority, project_id, actor),
    do: Device.delete(authority, project_id, actor)

  def delete(_authority, _project_id, _actor), do: {:error, :unauthorized}
end
