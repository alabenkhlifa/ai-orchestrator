defmodule SddOrchestratorWeb.ProjectConfirmationLive do
  @moduledoc """
  Placeholder destination for the final confirmation and project-creation step.

  The storage-selection step routes here once an available storage mode is
  explicitly chosen. The real final-confirmation surface — repository and storage
  summaries, the editable project name, default-name and suffix allocation, and
  the atomic project-registration transaction — is owned by the project-
  confirmation task, which replaces this placeholder. It shows the selected
  repository and storage mode so the handoff is visible end to end.

  Mount is workspace-scoped: an unknown, malformed, or cross-workspace attempt id
  routes back to the catalog; an attempt without a repository and storage mode is
  sent back to the storage step.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectStorage

  @impl true
  def mount(%{"attempt_id" => attempt_id}, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Projects.get_onboarding_attempt(workspace, attempt_id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      %{selected_repository: repo, storage_mode: mode} = attempt
      when is_nil(repo) or is_nil(mode) ->
        {:ok, push_navigate(socket, to: ~p"/onboarding/storage/#{attempt.id}")}

      attempt ->
        {:ok,
         socket
         |> assign(:page_title, "Confirm project")
         |> assign(:attempt, attempt)
         |> assign(:selected_repository, attempt.selected_repository)
         |> assign(:storage_mode, attempt.storage_mode)}
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

      <div data-screen="project-confirmation" class="text-center py-6 sm:py-10">
        <span class="w-13 h-13 mx-auto rounded-xl bg-primary/10 text-primary flex items-center justify-center p-3">
          <.lucide name="folder-git-2" class="size-6" />
        </span>
        <h1 class="mt-4 text-xl font-bold text-ink">Confirm your project</h1>
        <p class="mt-2 max-w-sm mx-auto text-sm leading-relaxed text-ink-muted text-pretty">
          Repository
          <span class="font-semibold text-ink" data-selected-repository>
            {@selected_repository["full_name"]}
          </span>
          · storage <span class="font-semibold text-ink" data-storage-mode>
            {ProjectStorage.label(String.to_existing_atom(@storage_mode))}
          </span>. Naming and creation arrive with the next task.
        </p>

        <div class="mt-6">
          <.button variant="secondary" navigate={~p"/onboarding/storage/#{@attempt.id}"}>
            <.lucide name="arrow-left" class="size-4" /> Back to storage
          </.button>
        </div>
      </div>
    </.app_shell>
    """
  end
end
