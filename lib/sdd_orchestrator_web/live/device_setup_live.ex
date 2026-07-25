defmodule SddOrchestratorWeb.DeviceSetupLive do
  @moduledoc """
  Placeholder for the on-device storage setup handoff.

  The storage-selection step routes here when the user chooses to set up
  `On this device`. The real device setup — talking to the local worker and
  producing a readiness receipt — is owned by `specs/02-local-project-onboarding/`
  and replaces this placeholder. This slice owns only the handoff boundary: the
  selected repository and onboarding state are preserved on the attempt, and
  `Back to storage` returns to the same storage step without selecting a mode or
  creating a project (the cancellation/return path). A successful setup writes a
  receipt through `Projects.record_device_receipt/3`, after which the storage step
  shows device storage as available.

  Mount is workspace-scoped: an unknown, malformed, or cross-workspace attempt id
  routes back to the catalog.
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
         |> assign(:page_title, "Device setup")
         |> assign(:attempt, attempt)}
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

      <div data-screen="device-setup" class="text-center py-6 sm:py-10">
        <span class="w-13 h-13 mx-auto rounded-xl bg-primary/10 text-primary flex items-center justify-center p-3">
          <.lucide name="hard-drive" class="size-6" />
        </span>
        <h1 class="mt-4 text-xl font-bold text-ink">Set up on this device</h1>
        <p class="mt-2 max-w-sm mx-auto text-sm leading-relaxed text-ink-muted text-pretty">
          On-device setup arrives with local project onboarding. Your repository selection is kept, so
          you can go back and continue with hosted storage in the meantime.
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
