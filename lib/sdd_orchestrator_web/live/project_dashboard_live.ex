defmodule SddOrchestratorWeb.ProjectDashboardLive do
  @moduledoc """
  The created project's dashboard (Task 8).

  Opened after registration commits, it shows the linked repository, the selected
  storage mode, and the current connection status. The initial paint shows the
  last confirmed state; the connected mount revalidates GitHub access and persists
  connected/disconnected transitions, while a transient provider outage shows a
  temporarily-unavailable indicator without overwriting the last confirmed state.
  `Check again` re-runs the revalidation so a project that lost access can
  reconnect to the same project without being replaced.

  The post-creation name control is wired to the reusable `Projects.rename_project/2`
  operation (owned by Task 7): a valid rename saves inline; an invalid or
  case-insensitively conflicting name returns inline feedback without changing the
  project or repository identity.

  Mount is workspace-scoped: an unknown, malformed, or cross-workspace project id
  routes back to the catalog so a foreign project is never rendered.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Connections
  alias SddOrchestrator.ProjectStorage

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Connections.project(account, workspace, project_id, revalidate: connected?(socket)) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      entry ->
        {:ok,
         socket
         |> assign(:workspace, workspace)
         |> assign_entry(entry)
         |> assign(:name, entry.project.name)
         |> assign(:name_error, nil)
         |> assign(:rename_saved?, false)}
    end
  end

  @impl true
  def handle_event("recheck", _params, socket) do
    entry =
      Connections.project(
        socket.assigns.current_account,
        socket.assigns.workspace,
        socket.assigns.project.id,
        revalidate: true
      )

    {:noreply, assign_entry(socket, entry)}
  end

  def handle_event("validate_name", %{"project" => %{"name" => name}}, socket) do
    {:noreply, assign(socket, name: name, name_error: nil, rename_saved?: false)}
  end

  def handle_event("rename", %{"project" => %{"name" => name}}, socket) do
    case Projects.rename_project(socket.assigns.project, name) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:page_title, project.name)
         |> assign(:name, project.name)
         |> assign(:name_error, nil)
         |> assign(:rename_saved?, true)}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           name: name,
           name_error: name_error_message(changeset),
           rename_saved?: false
         )}
    end
  end

  defp assign_entry(socket, entry) do
    socket
    |> assign(:page_title, entry.project.name)
    |> assign(:project, entry.project)
    |> assign(:connection, entry.connection)
    |> assign(:status, entry.status)
  end

  defp name_error_message(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:name] do
      {message, _opts} -> message
      nil -> "is invalid"
    end
  end

  defp storage_icon("device"), do: "hard-drive"
  defp storage_icon(_), do: "cloud"

  defp storage_label(mode) do
    case ProjectStorage.parse_mode(mode) do
      {:ok, parsed} -> ProjectStorage.label(parsed)
      :error -> mode
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
          <.connection_badge status={@status} class="flex-none" />
        </div>

        <div :if={@status == :disconnected} data-disconnected class="mt-4">
          <.notice variant="warn" icon="unplug">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span>
                GitHub access to this repository was lost. Your project is safe — restore access on
                GitHub, then check again.
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

        <div :if={@status == :temporarily_unavailable} data-unavailable class="mt-4">
          <.notice variant="info" icon="refresh-cw">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span>
                GitHub is temporarily unreachable, so the connection can't be confirmed right now.
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

        <form id="project-rename-form" phx-change="validate_name" phx-submit="rename" class="mt-6">
          <.text_field
            id="project-name"
            name="project[name]"
            label="Project name"
            value={@name}
            error={@name_error}
            hint="You can use spaces and any language. Renaming keeps the linked repository."
            autocomplete="off"
            phx-debounce="200"
          />
          <div class="mt-3 flex items-center gap-3">
            <.button type="submit">
              <.lucide name="pencil" class="size-4" /> Save name
            </.button>
            <span
              :if={@rename_saved?}
              class="inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
              data-rename-saved
            >
              <.lucide name="circle-check" class="size-4" /> Saved
            </span>
          </div>
        </form>

        <div class="mt-6 rounded-lg border border-line bg-surface p-4">
          <p class="text-[13px] font-semibold text-ink">Back up this project</p>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Download an encrypted package containing this project's identity, repository identity,
            and current specifications.
          </p>
          <.button
            variant="secondary"
            size="sm"
            navigate={~p"/projects/#{@project.id}/backup"}
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
end
