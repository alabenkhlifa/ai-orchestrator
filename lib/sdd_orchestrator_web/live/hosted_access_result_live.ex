defmodule SddOrchestratorWeb.HostedAccessResultLive do
  @moduledoc "Account-neutral magic-link success and safe-failure result surface."
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.HostedAccess.ReturnPath

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Hosted access result")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    verified? =
      params["status"] == "verified" and
        not is_nil(socket.assigns.current_hosted_identity)

    {:noreply,
     socket
     |> assign(:verified?, verified?)
     |> assign(:return_to, ReturnPath.sanitize(params["return_to"]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-xl">
      <section
        :if={@verified?}
        id="hosted-access-verified"
        class="rounded-xl border border-line bg-surface p-6 sm:p-8 text-center"
        role="status"
      >
        <span class="w-14 h-14 mx-auto rounded-xl bg-ok-bg text-ok-fg flex items-center justify-center">
          <.lucide name="circle-check" class="size-7" />
        </span>
        <h1
          tabindex="-1"
          phx-mounted={JS.focus()}
          class="mt-4 text-2xl font-bold tracking-tight text-ink outline-none"
        >
          Email verified
        </h1>
        <p class="mt-2 mx-auto max-w-md text-sm leading-relaxed text-ink-muted">
          Your hosted identity and workspace are ready on this device. This session remains
          available across browser restarts until it expires or you revoke it.
        </p>

        <div class="mt-6 flex flex-col sm:flex-row sm:justify-center gap-2.5">
          <.button navigate={@return_to}>
            Continue <.lucide name="arrow-right" class="size-4" />
          </.button>
          <.button variant="secondary" navigate={~p"/hosted/access/sessions"}>
            Manage active sessions
          </.button>
        </div>
      </section>

      <section
        :if={!@verified?}
        id="hosted-access-invalid"
        class="rounded-xl border border-line bg-surface"
      >
        <.failure_state title="This sign-in link is no longer available">
          <:description>
            It may be invalid, expired, already used, or replaced by a newer link. No hosted
            access was opened.
          </:description>
          <:actions>
            <.button navigate={~p"/hosted/access"}>Request a new link</.button>
            <.button variant="secondary" navigate={~p"/"}>Back to sign in</.button>
          </:actions>
        </.failure_state>
      </section>

      <.notice variant="neutral" class="mt-5">
        Losing your verified email isn’t recoverable in this release unless you linked another
        sign-in method before losing access. Support can’t override this boundary.
      </.notice>
    </.app_shell>
    """
  end
end
