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

  alias SddOrchestrator.Participation.InvitationProof

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

          <div :if={@proof_state == :proven} class="mt-4" data-proof-complete>
            <.notice variant="info" icon="circle-check">
              Your email address is confirmed. You are not on this project yet — the next step is
              to accept or decline.
            </.notice>
          </div>

          <div :if={@proof_state != :proven} class="mt-6">
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
