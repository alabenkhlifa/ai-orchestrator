defmodule SddOrchestratorWeb.ProjectDashboardLive do
  @moduledoc """
  Placeholder destination for a newly created project's dashboard.

  Project registration routes here after the creation transaction commits. This
  placeholder shows the linked repository, selected storage mode, and current
  connection status so the post-creation handoff is visible end to end. The full
  dashboard — the post-creation rename control, connection revalidation, and the
  connected/disconnected/temporarily-unavailable recovery states — is owned by the
  project-dashboard task (Task 8), which replaces this placeholder.

  Mount is workspace-scoped: an unknown, malformed, or cross-workspace project id
  routes back to the catalog so a foreign project is never rendered.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectStorage

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Projects.get_project(workspace, project_id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      project ->
        {:ok,
         socket
         |> assign(:page_title, project.name)
         |> assign(:project, project)
         |> assign(:connection, project.repository_connection)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/projects"}>
          <.lucide name="arrow-left" class="size-4" /> Projects
        </.button>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div data-screen="project-dashboard">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h1 class="text-xl font-bold text-ink truncate" data-project-name>{@project.name}</h1>
            <p class="mt-1 text-sm text-ink-muted">Your project is ready.</p>
          </div>
          <.badge variant={connection_variant(@connection)} icon={connection_icon(@connection)}>
            {connection_label(@connection)}
          </.badge>
        </div>

        <dl class="mt-6 flex flex-col gap-3">
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name="github" class="size-4" /> Repository
            </dt>
            <dd :if={@connection} class="mt-1.5 text-sm font-semibold text-ink" data-repository>
              {@connection.full_name || @connection.name}
            </dd>
          </div>

          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name={storage_icon(@project.storage_mode)} class="size-4" /> Project work saved
            </dt>
            <dd class="mt-1.5 text-sm font-semibold text-ink" data-storage-mode>
              {storage_label(@project.storage_mode)}
            </dd>
          </div>
        </dl>
      </div>
    </.app_shell>
    """
  end

  defp connection_variant(%{state: "connected"}), do: "ok"
  defp connection_variant(_), do: "warn"

  defp connection_icon(%{state: "connected"}), do: "circle-check"
  defp connection_icon(_), do: "unplug"

  defp connection_label(%{state: "connected"}), do: "Connected"
  defp connection_label(_), do: "Disconnected"

  defp storage_icon("device"), do: "hard-drive"
  defp storage_icon(_), do: "cloud"

  defp storage_label(mode) do
    case ProjectStorage.parse_mode(mode) do
      {:ok, parsed} -> ProjectStorage.label(parsed)
      :error -> mode
    end
  end
end
