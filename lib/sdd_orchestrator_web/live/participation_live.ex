defmodule SddOrchestratorWeb.ParticipationLive do
  @moduledoc """
  Participation settings for one hosted project.

  Every member corrects only their own project-specific display name here. The
  label is presentation only: it never changes project ownership, and the
  owner's email is never used as, or shown as, the project identity.

  A hosted project already carries the owner label from registration, so the
  invitation action shows the name the invitee will read and offers an inline
  correction beside it instead of holding the first invitation until the owner
  has typed something.

  A request from any identity other than the current owner fails closed and
  returns to the project catalog without exposing project content.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Invitations, Revocations}

  @invite_messages %{
    unauthorized: "Only the project owner can invite people to this project.",
    not_hosted_project: "This project is stored on your device, so it can't be shared yet.",
    invalid_email: "Enter a complete email address.",
    invitation_already_pending: "That address already has a pending invitation.",
    existing_owner: "That address is the project owner.",
    existing_participant: "That person is already on this project.",
    no_pending_invitation: "There is no pending invitation for that address.",
    not_cancelable: "That invitation has already finished and can't be canceled."
  }

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    account_id = acting_account_id(socket)
    identity_id = acting_identity_id(socket)

    case Participation.visible_project(project_id, account_id, identity_id) do
      {:ok, project, role} ->
        socket =
          socket
          |> assign_project(project, role, account_id)
          |> assign(:actor, %{account_id: account_id, hosted_identity_id: identity_id})

        {:ok, socket}

      {:error, :unauthorized} ->
        {:ok, push_navigate(socket, to: ~p"/projects")}
    end
  end

  # Participation is a hosted-identity feature, so the acting person may arrive
  # through the application session as the project owner or through a hosted
  # session as a participant.
  defp acting_account_id(socket) do
    cond do
      account = socket.assigns[:current_account] -> account.id
      identity = socket.assigns[:current_hosted_identity] -> identity.account_id
      true -> nil
    end
  end

  defp acting_identity_id(socket) do
    case socket.assigns[:current_hosted_identity] do
      nil -> nil
      identity -> identity.id
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
    socket
    |> save_display_name(name)
    |> case do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:display_name, profile.display_name)
         |> assign(:display_name_error, nil)
         |> assign(:saved?, true)
         |> refresh()}

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

  def handle_event("correct_owner_label", _params, socket) do
    {:noreply,
     socket
     |> assign(:correcting_owner_label?, true)
     |> assign(:owner_label_draft, owner_label_draft(socket.assigns.owner_profile))
     |> assign(:owner_label_error, nil)
     |> assign(:owner_label_saved?, false)}
  end

  def handle_event("cancel_owner_label", _params, socket) do
    {:noreply,
     socket
     |> assign(:correcting_owner_label?, false)
     |> assign(:owner_label_draft, owner_label_draft(socket.assigns.owner_profile))
     |> assign(:owner_label_error, nil)}
  end

  def handle_event("validate_owner_label", %{"owner_label" => %{"display_name" => name}}, socket) do
    {:noreply,
     socket
     |> assign(:owner_label_draft, name)
     |> assign(:owner_label_error, nil)
     |> assign(:owner_label_saved?, false)}
  end

  # The inline correction is the same owner self-edit action the standalone
  # form runs, so trimming, case-insensitive project uniqueness, preserved
  # spelling, and explicit conflict rejection without a suffix all come from the
  # one domain path. Anyone who is not the immutable owner fails closed here.
  def handle_event("save_owner_label", %{"owner_label" => %{"display_name" => name}}, socket) do
    socket.assigns.project
    |> Participation.save_owner_profile(socket.assigns.acting_account_id, name)
    |> case do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:correcting_owner_label?, false)
         |> assign(:display_name, profile.display_name)
         |> assign(:owner_label_error, nil)
         |> assign(:owner_label_saved?, true)
         |> refresh()}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:correcting_owner_label?, true)
         |> assign(:owner_label_draft, name)
         |> assign(:owner_label_error, display_name_error(changeset))
         |> assign(:owner_label_saved?, false)}
    end
  end

  def handle_event("validate_invite", %{"invite" => %{"email" => email}}, socket) do
    {:noreply,
     socket
     |> assign(:invite_email, email)
     |> assign(:invite_error, nil)
     |> assign(:invite_sent?, false)
     |> assign(:invite_canceled?, false)
     |> assign(:resendable?, false)}
  end

  def handle_event("invite", %{"invite" => %{"email" => email}}, socket) do
    socket.assigns.project
    |> Invitations.create(socket.assigns.current_account.id, email)
    |> case do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:invite_email, "")
         |> assign(:invite_error, nil)
         |> assign(:invite_sent?, true)
         |> assign(:invite_canceled?, false)
         |> assign(:resendable?, false)
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:invite_email, email)
         |> assign(:invite_error, invite_message(reason))
         |> assign(:invite_sent?, false)
         |> assign(:invite_canceled?, false)
         |> assign(:resendable?, reason == :invitation_already_pending)}
    end
  end

  def handle_event("leave_project", _params, socket) do
    socket.assigns.project
    |> Revocations.leave(socket.assigns.acting_account_id, acting_identity_id(socket))
    |> case do
      {:ok, _left} -> {:noreply, push_navigate(socket, to: ~p"/projects")}
      {:error, _reason} -> {:noreply, socket |> assign(:removed?, false) |> refresh()}
    end
  end

  def handle_event("remove_member", %{"account" => account_id}, socket) do
    socket.assigns.project
    |> Revocations.remove(
      socket.assigns.acting_account_id,
      hosted_identity_for(socket.assigns.project, account_id)
    )
    |> case do
      {:ok, _removed} ->
        {:noreply, socket |> assign(:removed?, true) |> refresh()}

      {:error, _reason} ->
        {:noreply, socket |> assign(:removed?, false) |> refresh()}
    end
  end

  def handle_event("cancel_invitation", _params, socket) do
    socket.assigns.project
    |> Invitations.cancel(socket.assigns.current_account.id, socket.assigns.invite_email)
    |> case do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> assign(:invite_email, "")
         |> assign(:invite_error, nil)
         |> assign(:invite_canceled?, true)
         |> assign(:resendable?, false)
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:invite_error, invite_message(reason))
         |> assign(:invite_canceled?, false)
         |> assign(:resendable?, false)}
    end
  end

  def handle_event("resend", _params, socket) do
    socket.assigns.project
    |> Invitations.resend(socket.assigns.current_account.id, socket.assigns.invite_email)
    |> case do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:invite_email, "")
         |> assign(:invite_error, nil)
         |> assign(:invite_sent?, true)
         |> assign(:resendable?, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:invite_error, invite_message(reason))
         |> assign(:invite_sent?, false)
         |> assign(:resendable?, false)}
    end
  end

  # The owner may still be establishing their first label, so creation and
  # renaming share one action; a participant already has one from acceptance.
  defp save_display_name(%{assigns: %{role: :owner}} = socket, name) do
    Participation.save_owner_profile(
      socket.assigns.project,
      socket.assigns.acting_account_id,
      name
    )
  end

  defp save_display_name(socket, name) do
    Participation.rename_member_profile(
      socket.assigns.project,
      socket.assigns.acting_account_id,
      acting_identity_id(socket),
      name
    )
  end

  defp invite_message({:existing_role, :owner}), do: Map.fetch!(@invite_messages, :existing_owner)

  defp invite_message({:existing_role, :participant}),
    do: Map.fetch!(@invite_messages, :existing_participant)

  defp invite_message(reason), do: Map.fetch!(@invite_messages, reason)

  defp assign_project(socket, project, role, account_id) do
    profile = Participation.owner_profile(project.id)

    socket
    |> assign(:page_title, "Participation")
    |> assign(:project, project)
    |> assign(:role, role)
    |> assign(:acting_account_id, account_id)
    |> assign(:members, Participation.members(project, role, account_id))
    |> assign(:invitations, invitations_for(project, role))
    |> assign(:owner_profile, profile)
    |> assign(:display_name, current_label(project, role, account_id))
    |> assign(:display_name_error, nil)
    |> assign(:saved?, false)
    |> assign(:correcting_owner_label?, false)
    |> assign(:owner_label_draft, owner_label_draft(profile))
    |> assign(:owner_label_error, nil)
    |> assign(:owner_label_saved?, false)
    |> assign(:invite_email, "")
    |> assign(:invite_error, nil)
    |> assign(:invite_sent?, false)
    |> assign(:invite_canceled?, false)
    |> assign(:resendable?, false)
    |> assign(:removed?, false)
  end

  # The list presents accounts; removal needs the stable hosted identity that
  # holds the authorization.
  defp hosted_identity_for(project, account_id) do
    project.id
    |> Participation.active_participants()
    |> Enum.find_value(fn participant ->
      if Participation.member_profile(project.id, account_id) &&
           participant_account_id(participant) == account_id,
         do: participant.hosted_identity_id
    end)
  end

  defp participant_account_id(participant) do
    case participant.hosted_identity_id do
      nil ->
        nil

      hosted_identity_id ->
        SddOrchestrator.Repo.get(SddOrchestrator.Accounts.HostedIdentity, hosted_identity_id)
        |> case do
          nil -> nil
          identity -> identity.account_id
        end
    end
  end

  defp current_label(project, :owner, _account_id) do
    case Participation.owner_profile(project.id) do
      nil -> ""
      profile -> profile.display_name
    end
  end

  defp current_label(project, :participant, account_id) do
    case Participation.member_profile(project.id, account_id) do
      nil -> ""
      profile -> profile.display_name
    end
  end

  # The name an invitee actually reads. A project registered before owner
  # profiles existed falls back to the same neutral role label the rest of the
  # product uses; an email address is never presented as a project label.
  defp invitation_owner_name(nil), do: Participation.default_owner_display_name()
  defp invitation_owner_name(profile), do: profile.display_name

  defp owner_label_draft(nil), do: ""
  defp owner_label_draft(profile), do: profile.display_name

  defp role_label(:owner), do: "Runs this project"
  defp role_label(:participant), do: "On this project"

  defp invitation_label(%{status: "pending"}), do: "Waiting for a reply"
  defp invitation_label(%{status: "accepted"}), do: "Joined"
  defp invitation_label(%{status: "declined"}), do: "Declined"
  defp invitation_label(%{status: "canceled"}), do: "Canceled"
  defp invitation_label(%{status: "expired"}), do: "Expired"

  defp invitations_for(project, :owner), do: Invitations.list(project.id)
  defp invitations_for(_project, _role), do: []

  defp refresh(socket) do
    project = socket.assigns.project
    role = socket.assigns.role
    account_id = socket.assigns.acting_account_id

    socket
    |> assign(:members, Participation.members(project, role, account_id))
    |> assign(:invitations, invitations_for(project, role))
    |> assign(:owner_profile, Participation.owner_profile(project.id))
    |> assign(:display_name, current_label(project, role, account_id))
    |> sync_owner_label_draft()
  end

  # An open correction keeps whatever the owner is still typing; a closed one
  # follows the stored label so both edit paths always show the same name.
  defp sync_owner_label_draft(%{assigns: %{correcting_owner_label?: true}} = socket), do: socket

  defp sync_owner_label_draft(socket),
    do: assign(socket, :owner_label_draft, owner_label_draft(socket.assigns.owner_profile))

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
      <div data-screen="participation-settings">
        <.project_nav
          project_id={@project.id}
          current={:people}
          owner?={@role == :owner}
          class="mb-6"
        />

        <.live_component
          module={SddOrchestratorWeb.ProjectAssistantPanel}
          id={"project-assistant-" <> @project.id}
          project_id={@project.id}
          actor={@actor}
          account={@current_account}
        />

        <h1 class="text-xl font-bold text-ink">People on {@project.name}</h1>
        <p class="mt-1 text-sm text-ink-muted">
          Invite people by email to work on this project. They see your project display name,
          never your email address.
        </p>

        <section class="mt-6" data-members>
          <h2 class="text-[13px] font-semibold text-ink">People on this project</h2>
          <p
            :if={@removed?}
            class="mt-2 inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
            data-member-removed
          >
            <.lucide name="circle-check" class="size-4" /> That person no longer has access.
          </p>
          <ul class="mt-3 flex flex-col gap-2">
            <li
              :for={member <- @members}
              class="flex flex-col gap-1 rounded-lg border border-line bg-surface p-3.5 sm:flex-row sm:items-center sm:justify-between"
              data-member
              data-member-role={member.role}
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-semibold text-ink" data-member-name>
                  {member.display_name}
                </p>
                <p :if={member.email} class="truncate text-xs text-ink-muted" data-member-email>
                  {member.email}
                </p>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-[13px] text-ink-muted" data-member-role-label>
                  {role_label(member.role)}
                </span>
                <.button
                  :if={@role == :owner and member.role == :participant}
                  type="button"
                  variant="secondary"
                  size="sm"
                  phx-click="remove_member"
                  phx-value-account={member.account_id}
                  data-remove-member
                >
                  <.lucide name="x" class="size-4" /> Remove
                </.button>
              </div>
            </li>
          </ul>
        </section>

        <form
          :if={@role == :owner}
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

        <div :if={@role == :owner} class="mt-6 rounded-lg border border-line bg-surface p-4">
          <p class="text-[13px] font-semibold text-ink">Invitations</p>

          <div data-invitations-available>
            <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
              Enter the email address of the person you want to invite. They join only after
              they confirm that address and accept.
            </p>

            <div class="mt-4 rounded-lg border border-line bg-raised p-3" data-invitation-owner-label>
              <p class="text-[13px] leading-relaxed text-ink-muted">
                The invitation shows you as
                <span class="font-semibold text-ink" data-invitation-owner-name>
                  {invitation_owner_name(@owner_profile)}
                </span>
              </p>

              <div
                :if={!@correcting_owner_label?}
                class="mt-2 flex flex-col gap-3 sm:flex-row sm:items-center"
              >
                <.button
                  type="button"
                  variant="secondary"
                  size="sm"
                  phx-click="correct_owner_label"
                  class="w-full sm:w-auto"
                  data-correct-owner-label
                >
                  <.lucide name="user-round-pen" class="size-4" /> Change this name
                </.button>
                <span
                  :if={@owner_label_saved?}
                  class="inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
                  data-invitation-owner-name-saved
                >
                  <.lucide name="circle-check" class="size-4" /> Name updated
                </span>
              </div>

              <form
                :if={@correcting_owner_label?}
                id="invitation-owner-name-form"
                phx-change="validate_owner_label"
                phx-submit="save_owner_label"
                class="mt-3"
              >
                <.text_field
                  id="invitation-owner-name-input"
                  name="owner_label[display_name]"
                  label="The name people you invite will see"
                  value={@owner_label_draft}
                  error={@owner_label_error}
                  hint="It has to be different from every other name on this project."
                  autocomplete="off"
                  phx-debounce="200"
                />
                <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center">
                  <.button
                    type="submit"
                    size="sm"
                    class="w-full sm:w-auto"
                    data-save-invitation-owner-name
                  >
                    <.lucide name="check" class="size-4" /> Use this name
                  </.button>
                  <.button
                    type="button"
                    variant="secondary"
                    size="sm"
                    phx-click="cancel_owner_label"
                    class="w-full sm:w-auto"
                    data-cancel-invitation-owner-name
                  >
                    <.lucide name="x" class="size-4" /> Keep the current name
                  </.button>
                </div>
              </form>
            </div>

            <form id="invitation-form" phx-change="validate_invite" phx-submit="invite" class="mt-4">
              <.text_field
                id="invite-email"
                name="invite[email]"
                type="email"
                label="Email address"
                value={@invite_email}
                error={@invite_error}
                hint="We send one invitation link to this address. It expires in 7 days."
                autocomplete="off"
                phx-debounce="200"
              />
              <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center">
                <.button type="submit" class="w-full sm:w-auto" data-send-invitation>
                  <.lucide name="users" class="size-4" /> Send invitation
                </.button>
                <.button
                  :if={@resendable?}
                  type="button"
                  variant="secondary"
                  phx-click="resend"
                  class="w-full sm:w-auto"
                  data-resend-invitation
                >
                  <.lucide name="refresh-cw" class="size-4" /> Send a new link instead
                </.button>
                <.button
                  :if={@resendable?}
                  type="button"
                  variant="secondary"
                  phx-click="cancel_invitation"
                  class="w-full sm:w-auto"
                  data-cancel-invitation
                >
                  <.lucide name="x" class="size-4" /> Cancel that invitation
                </.button>
                <span
                  :if={@invite_canceled?}
                  class="inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
                  data-invitation-canceled
                >
                  <.lucide name="circle-check" class="size-4" /> Invitation canceled
                </span>
                <span
                  :if={@invite_sent?}
                  class="inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
                  data-invitation-sent
                >
                  <.lucide name="circle-check" class="size-4" /> Invitation sent
                </span>
              </div>
            </form>

            <ul :if={@invitations != []} class="mt-4 flex flex-col gap-2" data-invitation-list>
              <li
                :for={invitation <- @invitations}
                class="flex flex-col gap-1 rounded-lg border border-line p-3 sm:flex-row sm:items-center sm:justify-between"
                data-invitation
                data-invitation-status={invitation.status}
              >
                <span class="truncate text-[13px] text-ink" data-invitation-email>
                  {invitation.delivery_email}
                </span>
                <span class="text-xs text-ink-muted" data-invitation-state>
                  {invitation_label(invitation)}
                </span>
              </li>
            </ul>
          </div>
        </div>

        <div :if={@role == :participant} class="mt-6" data-participant-view>
          <form
            id="member-profile-form"
            phx-change="validate_display_name"
            phx-submit="save_display_name"
          >
            <.text_field
              id="member-display-name"
              name="owner[display_name]"
              label="Your name on this project"
              value={@display_name}
              error={@display_name_error}
              hint="People on this project see this name. It has to be different from every other name on the project."
              autocomplete="off"
              phx-debounce="200"
            />
            <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center">
              <.button type="submit" class="w-full sm:w-auto" data-save-member-profile>
                <.lucide name="check" class="size-4" /> Save name
              </.button>
              <span
                :if={@saved?}
                class="inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
                data-member-profile-saved
              >
                <.lucide name="circle-check" class="size-4" /> Saved
              </span>
            </div>
          </form>

          <div class="mt-6">
            <.notice variant="info" icon="users">
              You're on this project. Only the project owner can invite or remove people.
            </.notice>
          </div>

          <div class="mt-6 rounded-lg border border-line bg-surface p-4">
            <p class="text-[13px] font-semibold text-ink">Leave this project</p>
            <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
              You keep your account and your other projects. Your past contributions stay on this
              project under your current name.
            </p>
            <.button
              type="button"
              variant="secondary"
              phx-click="leave_project"
              class="mt-3 w-full sm:w-auto"
              data-leave-project
            >
              <.lucide name="log-out" class="size-4" /> Leave project
            </.button>
          </div>
        </div>
      </div>
    </.app_shell>
    """
  end
end
