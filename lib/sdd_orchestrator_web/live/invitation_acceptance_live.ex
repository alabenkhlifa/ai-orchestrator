defmodule SddOrchestratorWeb.InvitationAcceptanceLive do
  @moduledoc """
  The invited person's entry point for one project invitation.

  Opening the link proves only that its credential was delivered. Before
  anything else happens, the invited address must be freshly proven through the
  passwordless boundary. When another identity is already active in this
  browser, the page explains that continuing signs this browser in as the
  invited address and leaves that other identity's other devices untouched.

  Nothing here grants project access: the explicit acceptance step is separate.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Acceptance, InvitationProof}

  @accept_messages %{
    invalid_or_expired: "This invitation can't be used anymore.",
    invalid_display_name: "Choose a name people on this project will recognize.",
    display_name_taken: "That name is already used on this project. Pick another one."
  }

  @impl true
  def mount(%{"id" => invitation_id} = params, _session, socket) do
    case resolve(invitation_id, params["token"], socket.assigns[:current_hosted_identity]) do
      {:ok, opened} -> {:ok, assign_invitation(socket, opened, params["token"])}
      {:error, :invalid_or_expired} -> {:ok, assign_unavailable(socket)}
    end
  end

  # The delivered credential opens the invitation on the first visit. After the
  # proof round trip the credential is not carried back, so the proven identity
  # authorizes the return visit instead.
  defp resolve(invitation_id, token, identity) when is_binary(token) do
    case InvitationProof.open(invitation_id, token) do
      {:ok, opened} -> {:ok, opened}
      {:error, :invalid_or_expired} -> InvitationProof.open_for_identity(invitation_id, identity)
    end
  end

  defp resolve(invitation_id, _token, identity),
    do: InvitationProof.open_for_identity(invitation_id, identity)

  @impl true
  def handle_event("request_proof", _params, socket) do
    {:ok, %{status: :accepted}} = InvitationProof.request(socket.assigns.opened)

    {:noreply, assign(socket, :proof_requested?, true)}
  end

  def handle_event("validate_name", %{"member" => %{"display_name" => name}}, socket) do
    {:noreply, socket |> assign(:display_name, name) |> assign(:accept_error, nil)}
  end

  def handle_event("accept", %{"member" => %{"display_name" => name}}, socket) do
    socket.assigns.opened.invitation.id
    |> Acceptance.accept(socket.assigns.current_hosted_identity, name)
    |> case do
      {:ok, accepted} ->
        {:noreply, assign(socket, :outcome, {:joined, accepted.project})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:display_name, name)
         |> assign(:accept_error, Map.fetch!(@accept_messages, reason))}
    end
  end

  def handle_event("decline", _params, socket) do
    socket.assigns.opened.invitation.id
    |> Acceptance.decline(socket.assigns.current_hosted_identity)
    |> case do
      {:ok, _declined} ->
        {:noreply, assign(socket, :outcome, :declined)}

      {:error, reason} ->
        {:noreply, assign(socket, :accept_error, Map.fetch!(@accept_messages, reason))}
    end
  end

  defp assign_invitation(socket, opened, token) do
    identity = socket.assigns[:current_hosted_identity]

    socket
    |> assign(:page_title, "Project invitation")
    |> assign(:available?, true)
    |> assign(:opened, opened)
    |> assign(:token, token)
    |> assign(:project_name, opened.project.name)
    |> assign(:invited_email, opened.invited_email)
    |> assign(:proof_state, InvitationProof.proof_state(opened.invitation, identity))
    |> assign(:proof_requested?, false)
    |> assign(:owner_label, owner_label(opened.project))
    |> assign(:display_name, "")
    |> assign(:accept_error, nil)
    |> assign(:outcome, nil)
  end

  defp owner_label(project) do
    case Participation.owner_profile(project.id) do
      nil -> nil
      profile -> profile.display_name
    end
  end

  defp assign_unavailable(socket) do
    socket
    |> assign(:page_title, "Project invitation")
    |> assign(:available?, false)
    |> assign(:opened, nil)
    |> assign(:token, nil)
    |> assign(:project_name, nil)
    |> assign(:invited_email, nil)
    |> assign(:proof_state, :unavailable)
    |> assign(:proof_requested?, false)
    |> assign(:owner_label, nil)
    |> assign(:display_name, "")
    |> assign(:accept_error, nil)
    |> assign(:outcome, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-lg">
      <div data-screen="invitation-acceptance">
        <div :if={not @available?} data-invitation-unavailable>
          <h1 class="text-xl font-bold text-ink">This invitation can't be used</h1>
          <p class="mt-2 text-sm text-ink-muted">
            The link may have expired, been replaced, or already been used. Ask the person who
            invited you to send a new one.
          </p>
        </div>

        <div :if={@available?}>
          <h1 class="text-xl font-bold text-ink">You're invited to {@project_name}</h1>
          <p class="mt-2 text-sm text-ink-muted">
            This invitation was sent to <span class="font-semibold text-ink" data-invited-email>{@invited_email}</span>.
            Confirm that address to continue. You still choose whether to join afterwards.
          </p>

          <div :if={@proof_state == :different_email} class="mt-4" data-identity-change-warning>
            <.notice variant="warn" icon="triangle-alert">
              You're signed in as someone else in this browser. Continuing signs this browser in
              as {@invited_email}. Your other sign-ins elsewhere are not affected.
            </.notice>
          </div>

          <div
            :if={@proof_state == :proven and is_nil(@outcome)}
            class="mt-4"
            data-proof-complete
          >
            <.notice variant="info" icon="circle-check">
              Your email address is confirmed. You are not on this project yet — choose how your
              name appears, then accept or decline.
            </.notice>
          </div>

          <div :if={@proof_state == :proven and is_nil(@outcome)} class="mt-6">
            <p :if={@owner_label} class="text-[13px] text-ink-muted" data-owner-label>
              {@owner_label} runs this project.
            </p>

            <form
              id="acceptance-form"
              phx-change="validate_name"
              phx-submit="accept"
              class="mt-3"
            >
              <.text_field
                id="member-display-name"
                name="member[display_name]"
                label="Your name on this project"
                value={@display_name}
                error={@accept_error}
                hint="People on this project see this name. It has to be different from every other name on the project."
                autocomplete="off"
                phx-debounce="200"
              />
              <div class="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center">
                <.button type="submit" class="w-full sm:w-auto" data-accept-invitation>
                  <.lucide name="check" class="size-4" /> Join {@project_name}
                </.button>
                <.button
                  type="button"
                  variant="secondary"
                  phx-click="decline"
                  class="w-full sm:w-auto"
                  data-decline-invitation
                >
                  <.lucide name="x" class="size-4" /> No thanks
                </.button>
              </div>
            </form>
          </div>

          <div :if={match?({:joined, _project}, @outcome)} class="mt-6" data-joined>
            <.notice variant="info" icon="circle-check">
              You joined {@project_name}.
            </.notice>
            <.button
              navigate={~p"/projects/#{elem(@outcome, 1).id}"}
              class="mt-4 w-full sm:w-auto"
              data-open-project
            >
              <.lucide name="arrow-right" class="size-4" /> Open {@project_name}
            </.button>
          </div>

          <div :if={@outcome == :declined} class="mt-6" data-declined>
            <.notice variant="info" icon="check">
              You declined this invitation. Nothing was shared with you, and you can be invited
              again later.
            </.notice>
          </div>

          <div :if={@proof_state != :proven and is_nil(@outcome)} class="mt-6">
            <.button
              :if={not @proof_requested?}
              phx-click="request_proof"
              class="w-full sm:w-auto"
              data-request-proof
            >
              <.lucide name="check" class="size-4" /> Confirm {@invited_email}
            </.button>

            <div :if={@proof_requested?} data-proof-requested>
              <.notice variant="info" icon="check">
                If that address can receive mail, a confirmation link is on its way. Open it in
                this browser to continue.
              </.notice>
            </div>
          </div>
        </div>
      </div>
    </.app_shell>
    """
  end
end
