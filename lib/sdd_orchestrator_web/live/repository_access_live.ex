defmodule SddOrchestratorWeb.RepositoryAccessLive do
  @moduledoc """
  Placeholder destination for the repository-access check.

  The catalog task establishes this route so its empty-workspace continuation and
  `Add project` handoff reach a real, workspace-scoped destination that carries an
  onboarding attempt. The dedicated `Grant repository access` screen, the GitHub
  installation handoff, and the repository picker are owned by the
  repository-picker task, which replaces this placeholder body.

  Mount is scoped to the current workspace: an unknown, malformed, or
  cross-workspace attempt id routes back to the catalog rather than exposing
  another workspace's onboarding state.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Projects

  @impl true
  def mount(%{"attempt_id" => attempt_id}, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Projects.get_onboarding_attempt(workspace, attempt_id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      attempt ->
        {:ok,
         socket
         |> assign(:page_title, "Repository access")
         |> assign(:attempt, attempt)
         |> assign(:identity, Accounts.get_github_identity(account.id))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-xl">
      <:actions>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div data-screen="repository-access" class="text-center py-6 sm:py-10">
        <span class="w-13 h-13 mx-auto rounded-xl bg-primary/10 text-primary flex items-center justify-center p-3">
          <.lucide name="github" class="size-6" />
        </span>
        <h1 class="mt-4 text-xl font-bold text-ink">Repository access</h1>
        <p class="mt-2 max-w-sm mx-auto text-sm leading-relaxed text-ink-muted text-pretty">
          Next, connect a repository to create your project. The grant screen and repository picker
          arrive with the next task.
        </p>

        <div class="mt-6">
          <.button variant="secondary" navigate={~p"/projects"}>
            <.lucide name="arrow-left" class="size-4" /> Back to projects
          </.button>
        </div>
      </div>
    </.app_shell>
    """
  end
end
