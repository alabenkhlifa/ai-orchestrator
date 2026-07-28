defmodule SddOrchestratorWeb.DeviceProjectDashboardLive do
  @moduledoc """
  The accountless on-device project dashboard (`specs/02-local-project-onboarding/`).

  Opened directly after local onboarding registers a project, and reachable
  afterwards, it shows the linked repository, the `On this device` storage mode,
  and the current connection status. The connection state is derived live from
  worker availability (`Devices.worker_status/1`) so a worker that stops or a
  repository that moves changes the state without deleting or hiding the project.

  `Locate repository` hands off to the onboarding folder picker in recovery mode
  for this project; only a matching canonical repository restores the connection.
  A previous export can recover lost project history through project portability
  (`specs/06`), which is mentioned here rather than implemented.

  Mount is by device-project id in the local store; an unknown id routes back to
  local onboarding rather than rendering a foreign project.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus, only: [device_connection_badge: 1]

  alias SddOrchestrator.Devices
  alias SddOrchestrator.ProjectStorage

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Devices.get_project(id) do
      {:ok, project} ->
        {:ok, workspace} = Devices.establish_workspace()
        status = connection_status(Devices.worker_status(workspace.id))

        {:ok,
         socket
         |> assign(:page_title, project.name)
         |> assign(:project, project)
         |> assign(:connection_status, status)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/onboarding/local")}
    end
  end

  @impl true
  def handle_event("recheck", _params, socket) do
    {:ok, workspace} = Devices.establish_workspace()
    status = connection_status(Devices.worker_status(workspace.id))
    {:noreply, assign(socket, :connection_status, status)}
  end

  # Live connection state from worker availability. A detected worker means the
  # device can reach the repository; anything else keeps the project visible in a
  # non-connected state rather than hiding it.
  defp connection_status(:detected), do: "connected"
  defp connection_status(:unavailable), do: "unavailable"
  defp connection_status(_missing_or_incompatible), do: "authorization_required"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/onboarding/local"}>
          <.lucide name="arrow-left" class="size-4" /> Local onboarding
        </.button>
      </:actions>

      <div data-screen="device-project-dashboard">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h1 class="text-xl font-bold text-ink truncate" data-project-name>{@project.name}</h1>
            <p class="mt-1 text-sm text-ink-muted">Your project is ready on this device.</p>
          </div>
          <span class="flex-none" data-connection-status={@connection_status}>
            <.device_connection_badge status={@connection_status} />
          </span>
        </div>

        <div :if={@connection_status != "connected"} class="mt-4" data-connection-notice>
          <.notice variant="warn" icon="unplug">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span>
                {connection_message(@connection_status)}
              </span>
              <.button
                variant="secondary"
                size="sm"
                phx-click="recheck"
                data-recheck
                class="flex-none"
              >
                <.lucide name="refresh-cw" class="size-4" /> Check again
              </.button>
            </div>
          </.notice>
        </div>

        <dl class="mt-6 flex flex-col gap-3">
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name="folder-git-2" class="size-4" /> Repository
            </dt>
            <dd class="mt-1.5 text-sm font-semibold text-ink" data-repository>
              Local Git repository on this Mac
            </dd>
          </div>

          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name="hard-drive" class="size-4" /> Project work saved
            </dt>
            <dd class="mt-1.5 text-sm font-semibold text-ink" data-storage-mode>
              {ProjectStorage.label(:device)}
            </dd>
          </div>
        </dl>

        <div class="mt-6 rounded-lg border border-line bg-surface p-4">
          <p class="text-[13px] font-semibold text-ink">Moved or renamed the repository?</p>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Point this project at the repository's new location. Only the same repository can
            reconnect — a different one is kept as a separate project.
          </p>
          <.button
            variant="secondary"
            size="sm"
            navigate={~p"/onboarding/local?#{[locate: @project.id]}"}
            data-locate-repository
            class="mt-3 w-full sm:w-auto"
          >
            <.lucide name="search" class="size-4" /> Locate repository
          </.button>
        </div>

        <div class="mt-4 rounded-lg border border-line bg-surface p-4" data-portability>
          <p class="text-[13px] font-semibold text-ink">Back up this project</p>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            This project lives only on this device. Recovery after device data loss is possible
            only from a backup you downloaded earlier through project portability.
          </p>
          <.button
            variant="secondary"
            size="sm"
            navigate={~p"/local/projects/#{@project.id}/backup"}
            data-backup-project
            class="mt-3 w-full sm:w-auto"
          >
            <.lucide name="download" class="size-4" /> Create backup
          </.button>
        </div>
      </div>
    </.app_shell>
    """
  end

  defp connection_message("unavailable"),
    do:
      "The worker on this Mac isn't running, so this project's repository can't be reached right now. Your project is safe — start the worker, then check again."

  defp connection_message(_authorization_required),
    do:
      "No worker is connected on this Mac, so this project's repository can't be reached. Set up or pair a worker, then check again."
end
