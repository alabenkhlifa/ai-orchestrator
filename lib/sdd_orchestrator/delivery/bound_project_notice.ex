defmodule SddOrchestrator.Delivery.BoundProjectNotice do
  @moduledoc """
  Tells the worker attached for a Mac which projects that Mac now serves.

  A worker paired from the menu bar attaches for its Mac alone and holds no
  project connection, so a run enqueued for a project it was bound to later
  finds nobody on the project-keyed registry. The worker cannot discover the
  binding by itself. Its socket names no project, and the control plane never
  dials a worker. This is the one place that closes that gap.

  Two notices exist. `project_bound` says a project is now this Mac's to serve,
  and `project_unbound` says it no longer is. Each carries the project id and
  nothing else. The repository path never leaves the Mac, the repository
  identity stays on the project record, and the worker exchanges its own
  credential when it opens the project connection, so none of the three has any
  reason to travel here.

  A notice goes to every worker attached for the Mac, not only to the one the
  binding names. The gateway credential exchange already authorizes a project by
  device workspace, so a second worker on the same Mac is entitled to the same
  connection, and a reconnect that briefly overlaps the connection it replaces
  must not miss the notice.

  Nothing here is authoritative and nothing here is retried. The bindings table
  is the record. A worker that was not attached when a notice was sent reads the
  whole list again the next time it attaches, which is what `announce_bound/1`
  is for.
  """

  import Ecto.Query

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo

  @doc "Tells a Mac's attached workers that one project is now theirs to serve."
  @spec bound(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def bound(device_workspace_id, project_id),
    do: notify(device_workspace_id, :project_bound, project_id)

  @doc "Tells a Mac's attached workers that one project is no longer theirs to serve."
  @spec unbound(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def unbound(device_workspace_id, project_id),
    do: notify(device_workspace_id, :project_unbound, project_id)

  @doc """
  Sends one `project_bound` notice for every project already bound to a Mac.

  Called when a worker attaches, because a binding made while no worker was
  listening is otherwise never heard. Sending the whole list rather than a
  difference is what keeps this side free of any belief about what a given
  worker already knows.
  """
  @spec announce_bound(Ecto.UUID.t()) :: :ok
  def announce_bound(device_workspace_id) do
    device_workspace_id
    |> bound_project_ids()
    |> Enum.each(&bound(device_workspace_id, &1))
  end

  @doc "The projects currently bound to a worker of one device workspace."
  @spec bound_project_ids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def bound_project_ids(device_workspace_id) do
    case Ecto.UUID.cast(device_workspace_id) do
      {:ok, device_workspace_id} ->
        Repo.all(
          from binding in HostedLocalRepositoryBinding,
            join: worker in LocalWorker,
            on: worker.id == binding.worker_id,
            where: worker.device_workspace_id == ^device_workspace_id,
            select: binding.project_id
        )

      :error ->
        []
    end
  end

  @doc """
  The Mac a project's binding names, or `nil` when the project has none.

  Read this before the binding row is deleted. The binding holds only a worker,
  so once it is gone there is no way back to the Mac that has to be told.
  """
  @spec bound_device_workspace_id(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def bound_device_workspace_id(project_id) do
    Repo.one(
      from binding in HostedLocalRepositoryBinding,
        join: worker in LocalWorker,
        on: worker.id == binding.worker_id,
        where: binding.project_id == ^project_id,
        select: worker.device_workspace_id
    )
  end

  # The attachment registry is duplicate-keyed, so a Mac can hold more than one
  # live channel. Every one of them is told, exactly as command delivery and the
  # folder picker already treat an overlap as harmless rather than ambiguous.
  defp notify(device_workspace_id, tag, project_id) do
    payload = %{"project_id" => project_id}

    device_workspace_id
    |> WorkerAttachment.attached()
    |> Enum.each(fn {channel, _contract} -> send(channel, {tag, payload}) end)
  end
end
