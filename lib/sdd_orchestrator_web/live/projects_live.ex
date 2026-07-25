defmodule SddOrchestratorWeb.ProjectsLive do
  @moduledoc """
  The protected project catalog and the post-authentication routing decision.

  On entry the account's personal workspace is restored (created on first use).
  A workspace that already owns projects renders its catalog with a non-mutating
  `Add project` control; an empty workspace continues straight to the
  repository-access check without another action. `Add project` and the
  empty-workspace continuation both open a fresh onboarding attempt and hand off
  to the repository-access check; neither creates a project or repository
  connection.

  Per-row connection status is added by the connection-recovery task; the
  repository-access check itself is owned by the repository-picker task, which
  replaces the placeholder this handoff targets.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Projects

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    if Projects.has_projects?(workspace) do
      {:ok,
       socket
       |> assign(:page_title, "Projects")
       |> assign(:workspace, workspace)
       |> assign(:identity, Accounts.get_github_identity(account.id))
       |> assign(:projects, Projects.list_catalog(workspace))}
    else
      {:ok, continue_to_repository_access(socket, workspace)}
    end
  end

  @impl true
  def handle_event("add_project", _params, socket) do
    {:noreply, continue_to_repository_access(socket, socket.assigns.workspace)}
  end

  # Non-mutating handoff into onboarding: reuse or open an onboarding attempt and
  # route to the repository-access check. No project or connection is created.
  defp continue_to_repository_access(socket, workspace) do
    {:ok, attempt} = Projects.get_or_start_onboarding_attempt(workspace)
    push_navigate(socket, to: ~p"/onboarding/repository-access/#{attempt.id}")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell>
      <:actions>
        <span class="hidden sm:flex items-center gap-2 text-[13px] text-ink-muted">
          <span class="w-7 h-7 rounded-full bg-raised text-ink-muted flex items-center justify-center text-xs font-bold">
            {initials(@identity)}
          </span>
          {@identity.login}
        </span>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div class="flex items-center justify-between gap-4">
        <h1 class="text-xl font-bold text-ink">Projects</h1>
        <.button phx-click="add_project">
          <.lucide name="plus" class="size-4" /> Add project
        </.button>
      </div>

      <ul id="project-catalog" class="mt-6 flex flex-col gap-2.5">
        <li :for={project <- @projects} id={"project-#{project.id}"}>
          <div class="flex items-center gap-3 rounded-lg border border-line bg-surface p-4">
            <span class="flex-none w-9 h-9 rounded-lg bg-raised text-ink-muted flex items-center justify-center">
              <.lucide name="folder-git-2" class="size-[18px]" />
            </span>
            <span class="min-w-0 flex-1 truncate text-sm font-semibold text-ink">
              {project.name}
            </span>
          </div>
        </li>
      </ul>
    </.app_shell>
    """
  end

  defp initials(%{login: login}) when is_binary(login) do
    login |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(0, 2) |> String.upcase()
  end

  defp initials(_), do: "?"
end
