defmodule SddOrchestratorWeb.ParticipationLive do
  @moduledoc """
  Participation settings for one hosted project.

  The immutable project owner establishes their project-specific display name
  here before the first invitation can be sent, and may later correct only
  their own label. The label is presentation only: it never changes project
  ownership, and the owner's email is never used as, or shown as, the project
  identity.

  A request from any identity other than the current owner fails closed and
  returns to the project catalog without exposing project content.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Participation

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    account = socket.assigns.current_account

    case Participation.owned_project(account.id, project_id) do
      {:ok, project} ->
        {:ok, assign_project(socket, project)}

      {:error, :unauthorized} ->
        {:ok, push_navigate(socket, to: ~p"/projects")}
    end
  end

  @impl true
  def handle_event("validate_display_name", %{"owner" => %{"display_name" => name}}, socket) do
    {:noreply,
     socket
     |> assign(:display_name, name)
     |> assign(:display_name_error, nil)
     |> assign(:saved?, false)}
  end

  def handle_event("save_display_name", %{"owner" => %{"display_name" => name}}, socket) do
    socket.assigns.project
    |> Participation.save_owner_profile(socket.assigns.current_account.id, name)
    |> case do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:owner_profile, profile)
         |> assign(:display_name, profile.display_name)
         |> assign(:display_name_error, nil)
         |> assign(:saved?, true)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:display_name, name)
         |> assign(:display_name_error, display_name_error(changeset))
         |> assign(:saved?, false)}
    end
  end

  defp assign_project(socket, project) do
    profile = Participation.owner_profile(project.id)

    socket
    |> assign(:page_title, "Participation")
    |> assign(:project, project)
    |> assign(:owner_profile, profile)
    |> assign(:display_name, (profile && profile.display_name) || "")
    |> assign(:display_name_error, nil)
    |> assign(:saved?, false)
  end

  defp display_name_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:display_name] do
      {message, _opts} -> message
      nil -> "is not an available project label"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/projects/#{@project.id}"}>
          <.lucide name="arrow-left" class="size-4" /> Project
        </.button>
      </:actions>

      <div data-screen="participation-settings">
        <h1 class="text-xl font-bold text-ink">People on {@project.name}</h1>
        <p class="mt-1 text-sm text-ink-muted">
          Invite people by email to work on this project. They see your project display name,
          never your email address.
        </p>

        <div :if={is_nil(@owner_profile)} class="mt-4" data-owner-profile-required>
          <.notice variant="warn" icon="user-round-pen">
            Choose how your name appears on this project before you send the first invitation.
          </.notice>
        </div>

        <form
          id="owner-profile-form"
          phx-change="validate_display_name"
          phx-submit="save_display_name"
          class="mt-6"
        >
          <.text_field
            id="owner-display-name"
            name="owner[display_name]"
            label="Your name on this project"
            value={@display_name}
            error={@display_name_error}
            hint="People on this project see this name. It has to be different from every other name on the project."
            autocomplete="off"
            phx-debounce="200"
          />
          <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center">
            <.button type="submit" class="w-full sm:w-auto" data-save-owner-profile>
              <.lucide name="check" class="size-4" /> Save name
            </.button>
            <span
              :if={@saved?}
              class="inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
              data-owner-profile-saved
            >
              <.lucide name="circle-check" class="size-4" /> Saved
            </span>
          </div>
        </form>

        <div class="mt-6 rounded-lg border border-line bg-surface p-4">
          <p class="text-[13px] font-semibold text-ink">Invitations</p>
          <p
            :if={is_nil(@owner_profile)}
            class="mt-1 text-[13px] leading-relaxed text-ink-muted"
            data-invitations-unavailable
          >
            Save your project name first. Invitations become available right after.
          </p>
          <p
            :if={@owner_profile}
            class="mt-1 text-[13px] leading-relaxed text-ink-muted"
            data-invitations-available
          >
            You can invite people to this project by email.
          </p>
        </div>
      </div>
    </.app_shell>
    """
  end
end
