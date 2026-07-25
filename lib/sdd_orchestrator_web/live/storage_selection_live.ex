defmodule SddOrchestratorWeb.StorageSelectionLive do
  @moduledoc """
  Placeholder destination for the storage-selection step.

  The repository-picker task establishes this route so its `Continue` action —
  after persisting the confirmed repository onto the onboarding attempt — reaches
  a real, workspace-scoped destination. The `Where should your project work be
  saved?` step, its device and hosted choices, and the resumable device-setup
  handoff are owned by the storage-selection task, which replaces this
  placeholder body.

  Mount is scoped to the current workspace: an unknown, malformed, or
  cross-workspace attempt id routes back to the catalog rather than exposing
  another workspace's onboarding state. It shows the repository the picker just
  selected so the handoff is visible end to end.
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
         |> assign(:page_title, "Storage")
         |> assign(:attempt, attempt)
         |> assign(:selected_repository, attempt.selected_repository)}
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

      <div data-screen="storage-selection" class="text-center py-6 sm:py-10">
        <span class="w-13 h-13 mx-auto rounded-xl bg-primary/10 text-primary flex items-center justify-center p-3">
          <.lucide name="hard-drive" class="size-6" />
        </span>
        <h1 class="mt-4 text-xl font-bold text-ink">Where should your project work be saved?</h1>
        <p class="mt-2 max-w-sm mx-auto text-sm leading-relaxed text-ink-muted text-pretty">
          <span :if={@selected_repository}>
            Selected repository: <span class="font-semibold text-ink" data-selected-repository>
              {@selected_repository["full_name"]}
            </span>.
          </span>
          The storage choices arrive with the next task.
        </p>

        <div class="mt-6">
          <.button variant="secondary" navigate={~p"/onboarding/repository-access/#{@attempt.id}"}>
            <.lucide name="arrow-left" class="size-4" /> Back to repositories
          </.button>
        </div>
      </div>
    </.app_shell>
    """
  end
end
