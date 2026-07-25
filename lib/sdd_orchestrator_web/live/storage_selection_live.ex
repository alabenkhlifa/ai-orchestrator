defmodule SddOrchestratorWeb.StorageSelectionLive do
  @moduledoc """
  The storage-selection step: `Where should your project work be saved?`.

  After a repository is selected, the user explicitly chooses where their project
  work is saved before any project exists. Both modes are always visible:

    * `In my SDD Orchestrator account` (hosted) — available in this slice.
    * `On this device` (device) — available only once the local-device boundary
      has supplied a valid readiness receipt. Until then it stays visible but
      unavailable, explains the missing prerequisite, and offers a setup action
      that hands off to device setup (owned by `specs/02`) without selecting the
      mode or creating a project.

  The explicitly chosen mode is persisted onto the workspace-scoped onboarding
  attempt so the choice is resumable; no project or repository connection is
  created here. Continuation stays blocked until one available mode is selected —
  there is no silent default. Mount is workspace-scoped and requires a repository
  to already be selected on the attempt.
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

      %{selected_repository: nil} = attempt ->
        # No repository chosen yet: send the user back to pick one first.
        {:ok, push_navigate(socket, to: ~p"/onboarding/repository-access/#{attempt.id}")}

      attempt ->
        {:ok,
         socket
         |> assign(:page_title, "Storage")
         |> assign(:workspace, workspace)
         |> assign_attempt(attempt)}
    end
  end

  @impl true
  def handle_event("select_mode", %{"mode" => mode}, socket) do
    with {:ok, parsed} <- ProjectStorage.parse_mode(mode),
         true <- ProjectStorage.available?(parsed, socket.assigns.attempt),
         {:ok, attempt} <-
           Projects.select_storage_mode(
             socket.assigns.workspace,
             socket.assigns.attempt.id,
             mode
           ) do
      {:noreply, assign_attempt(socket, attempt)}
    else
      # Unavailable or unknown mode: never selects a mode silently.
      _ -> {:noreply, socket}
    end
  end

  def handle_event("setup_device", _params, socket) do
    {:noreply,
     push_navigate(socket, to: ~p"/onboarding/device-setup/#{socket.assigns.attempt.id}")}
  end

  def handle_event("continue", _params, socket) do
    mode = socket.assigns.selected_mode

    if mode && ProjectStorage.available?(mode, socket.assigns.attempt) do
      {:noreply, push_navigate(socket, to: ~p"/onboarding/confirm/#{socket.assigns.attempt.id}")}
    else
      {:noreply, socket}
    end
  end

  defp assign_attempt(socket, attempt) do
    socket
    |> assign(:attempt, attempt)
    |> assign(:selected_repository, attempt.selected_repository)
    |> assign(:selected_mode, parse_selected_mode(attempt.storage_mode))
    |> assign(:hosted_available, ProjectStorage.available?(:hosted, attempt))
    |> assign(:device_available, ProjectStorage.available?(:device, attempt))
  end

  defp parse_selected_mode(nil), do: nil

  defp parse_selected_mode(mode) do
    case ProjectStorage.parse_mode(mode) do
      {:ok, parsed} -> parsed
      :error -> nil
    end
  end

  defp continue_enabled?(assigns) do
    assigns.selected_mode == :hosted or
      (assigns.selected_mode == :device and assigns.device_available)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button
          variant="secondary"
          size="sm"
          navigate={~p"/onboarding/repository-access/#{@attempt.id}"}
        >
          <.lucide name="arrow-left" class="size-4" /> Back
        </.button>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div data-screen="storage-selection">
        <h1 class="text-xl font-bold text-ink">Where should your project work be saved?</h1>
        <p class="mt-1.5 text-sm leading-relaxed text-ink-muted text-pretty">
          This is where SDD Orchestrator keeps your specifications and project work — separate from
          your code. Your linked repository
          <span :if={@selected_repository} class="font-semibold text-ink">
            {@selected_repository["full_name"]}
          </span>
          stays exactly where it is on GitHub; nothing about it changes.
        </p>

        <div
          id="storage-options"
          role="radiogroup"
          aria-label="Storage location"
          class="mt-6 flex flex-col gap-3"
        >
          <.radio_option
            id="storage-hosted"
            selected={@selected_mode == :hosted}
            label={ProjectStorage.label(:hosted)}
            phx-click="select_mode"
            phx-value-mode="hosted"
          >
            <div class="flex items-center gap-2">
              <.lucide name="cloud" class="size-4 text-ink-muted" />
              <span class="text-sm font-semibold text-ink">In my SDD Orchestrator account</span>
            </div>
            <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
              Saved in your hosted account. Available from any device you sign in on.
            </p>
          </.radio_option>

          <div>
            <.radio_option
              id="storage-device"
              selected={@selected_mode == :device}
              disabled={!@device_available}
              label={ProjectStorage.label(:device)}
              phx-click="select_mode"
              phx-value-mode="device"
            >
              <div class="flex items-center gap-2">
                <.lucide name="hard-drive" class="size-4 text-ink-muted" />
                <span class="text-sm font-semibold text-ink">On this device</span>
              </div>
              <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
                Saved on this computer. Stays on the device you set up.
              </p>
            </.radio_option>

            <.notice :if={!@device_available} variant="info" icon="hard-drive" class="mt-2">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                <span>On-device storage needs a quick one-time setup on this computer first.</span>
                <.button variant="secondary" size="sm" phx-click="setup_device" class="flex-none">
                  <.lucide name="hard-drive" class="size-4" /> Set up on this device
                </.button>
              </div>
            </.notice>
          </div>
        </div>

        <div class="mt-6 flex items-center justify-end">
          <.button phx-click="continue" disabled={!continue_enabled?(assigns)}>
            Continue <.lucide name="arrow-right" class="size-4" />
          </.button>
        </div>
      </div>
    </.app_shell>
    """
  end
end
