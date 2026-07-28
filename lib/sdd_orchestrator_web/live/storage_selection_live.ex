defmodule SddOrchestratorWeb.StorageSelectionLive do
  @moduledoc """
  The shared storage-selection step: `Where should your project work be saved?`.

  One LiveView serves both repository sources through its `live_action` scope:

    * `:hosted` — GitHub onboarding while signed in. The attempt is hosted-origin,
      so hosted storage is always available; device stays visible but unavailable
      until the local-device boundary supplies a readiness receipt.
    * `:device` — accountless local onboarding. The attempt is device-origin, so
      hosted stays visible but unavailable until a verified sign-in records the
      hosted prerequisite, at which point the same step refreshes hosted
      availability without selecting it or disclosing an identity on failure.

  Both modes are always visible; an unavailable mode explains its missing
  prerequisite and offers the relevant setup action (device setup or hosted
  sign-in) that hands off and returns to this same step without selecting a mode
  or creating a project. The explicitly chosen mode is persisted on the attempt so
  the choice is resumable; there is no silent default. Mount is scoped to the
  origin workspace and requires a repository to already be selected.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectStorage

  @impl true
  def mount(%{"attempt_id" => attempt_id}, _session, %{assigns: %{live_action: :device}} = socket) do
    {:ok, workspace} = Devices.establish_workspace()

    case Projects.get_device_onboarding_attempt(workspace, attempt_id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/onboarding/local")}

      %{selected_repository: nil} ->
        # No repository chosen yet: return to the accountless flow to pick one.
        {:ok, push_navigate(socket, to: ~p"/onboarding/local")}

      attempt ->
        # A verified sign-in returns here with a hosted session; recording the
        # proven hosted workspace only refreshes hosted availability. An
        # unsuccessful sign-in returns without a session, so nothing is attached
        # and no hosted identity is disclosed.
        attempt =
          maybe_record_hosted_prerequisite(
            workspace,
            attempt,
            socket.assigns[:current_hosted_workspace]
          )

        {:ok,
         socket
         |> assign(:page_title, "Storage")
         |> assign(:scope, :device)
         |> assign(:workspace, workspace)
         |> assign_attempt(attempt)}
    end
  end

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
         |> assign(:scope, :hosted)
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
    {:noreply, push_navigate(socket, to: device_setup_path(socket.assigns))}
  end

  def handle_event("setup_hosted", _params, socket) do
    # Hand off to passwordless sign-in (owned by specs/03), bound to a one-time
    # return to this same accountless storage step. Sign-in never selects a mode.
    return_to = ~p"/onboarding/local/storage/#{socket.assigns.attempt.id}"
    {:noreply, push_navigate(socket, to: ~p"/hosted/access?#{[return_to: return_to]}")}
  end

  def handle_event("continue", _params, socket) do
    mode = socket.assigns.selected_mode

    if mode && ProjectStorage.available?(mode, socket.assigns.attempt) do
      {:noreply, push_navigate(socket, to: continue_path(socket.assigns))}
    else
      {:noreply, socket}
    end
  end

  # A hosted session present on the accountless step proves the sign-in
  # prerequisite; record it once so hosted becomes available. Availability only —
  # no mode is selected and no project is created.
  defp maybe_record_hosted_prerequisite(_workspace, attempt, nil), do: attempt

  defp maybe_record_hosted_prerequisite(
         workspace,
         %{hosted_prerequisite_workspace_id: nil} = attempt,
         %PersonalWorkspace{} = hosted_workspace
       ) do
    case Projects.record_hosted_prerequisite(workspace, attempt.id, hosted_workspace) do
      {:ok, updated} -> updated
      {:error, _reason} -> attempt
    end
  end

  defp maybe_record_hosted_prerequisite(_workspace, attempt, _hosted_workspace), do: attempt

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

  # Source-neutral display label for the selected repository. GitHub supplies a
  # `full_name` (`owner/name`); the local adapter supplies only a display `name`
  # with no path or URL. Falls back gracefully so neither source leaks the other's
  # shape into the shared surface.
  defp repository_label(%{"full_name" => full_name}) when is_binary(full_name), do: full_name
  defp repository_label(%{"name" => name}) when is_binary(name), do: name
  defp repository_label(_repository), do: "your repository"

  defp continue_enabled?(assigns) do
    (assigns.selected_mode == :hosted and assigns.hosted_available) or
      (assigns.selected_mode == :device and assigns.device_available)
  end

  # Back returns to the origin's own step: the GitHub repository picker for a
  # hosted attempt, or the accountless local flow for a device attempt.
  defp back_path(%{scope: :device}), do: ~p"/onboarding/local"
  defp back_path(%{attempt: attempt}), do: ~p"/onboarding/repository-access/#{attempt.id}"

  # Device setup is source-owned: the hosted flow hands off to its device-setup
  # step; the accountless flow prepares the device in the local onboarding flow.
  defp device_setup_path(%{scope: :device}), do: ~p"/onboarding/local"
  defp device_setup_path(%{attempt: attempt}), do: ~p"/onboarding/device-setup/#{attempt.id}"

  # Continuing to project creation is source-owned. The hosted flow proceeds to
  # its confirmation step; the accountless flow returns to the local flow with the
  # attempt, which owns on-device project creation.
  defp continue_path(%{scope: :device, attempt: attempt}),
    do: ~p"/onboarding/local?#{[attempt: attempt.id]}"

  defp continue_path(%{attempt: attempt}), do: ~p"/onboarding/confirm/#{attempt.id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={back_path(assigns)}>
          <.lucide name="arrow-left" class="size-4" /> Back
        </.button>
        <.button
          :if={@scope == :hosted}
          variant="secondary"
          size="sm"
          href={~p"/auth/sign_out"}
          method="delete"
        >
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div data-screen="storage-selection">
        <h1 class="text-xl font-bold text-ink">{ProjectStorage.question()}</h1>
        <p class="mt-1.5 text-sm leading-relaxed text-ink-muted text-pretty">
          {ProjectStorage.work_explanation()}
        </p>
        <p
          :if={@selected_repository}
          class="mt-1 text-[13px] text-ink-muted"
          data-selected-repository
        >
          Linked repository:
          <span class="font-semibold text-ink">{repository_label(@selected_repository)}</span>
        </p>

        <div
          id="storage-options"
          role="radiogroup"
          aria-label="Storage location"
          class="mt-6 flex flex-col gap-3"
        >
          <div>
            <.radio_option
              id="storage-hosted"
              selected={@selected_mode == :hosted}
              disabled={!@hosted_available}
              label={ProjectStorage.label(:hosted)}
              phx-click="select_mode"
              phx-value-mode="hosted"
            >
              <div class="flex items-center gap-2">
                <.lucide name="cloud" class="size-4 text-ink-muted" />
                <span class="text-sm font-semibold text-ink">{ProjectStorage.label(:hosted)}</span>
              </div>
              <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
                {ProjectStorage.description(:hosted)}
              </p>
            </.radio_option>

            <.notice :if={!@hosted_available} variant="info" icon="cloud" class="mt-2">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                <span>Hosted storage needs you to sign in to your SDD Orchestrator account first.</span>
                <.button variant="secondary" size="sm" phx-click="setup_hosted" class="flex-none">
                  <.lucide name="log-in" class="size-4" /> Sign in
                </.button>
              </div>
            </.notice>
          </div>

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
                <span class="text-sm font-semibold text-ink">{ProjectStorage.label(:device)}</span>
              </div>
              <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
                {ProjectStorage.description(:device)}
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
