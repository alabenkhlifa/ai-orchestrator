defmodule SddOrchestratorWeb.HostedAccessLive do
  @moduledoc """
  Public passwordless request, acknowledgement, waiting, and resend surface.

  The rendered response never distinguishes invalid, throttled, new, existing,
  or delivery-failed requests and never repeats the submitted address.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.ReturnPath

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Hosted access")
     |> assign(:state, :request)
     |> assign(:submitted_email, nil)
     |> assign(:return_to, ReturnPath.sanitize(params["return_to"]))
     |> assign(:ip_address, request_ip(socket))}
  end

  @impl true
  def handle_event("request", %{"email" => email}, socket) do
    request_magic_link(email, socket)

    {:noreply,
     socket
     |> assign(:state, :waiting)
     |> assign(:submitted_email, email)}
  end

  def handle_event("resend", _params, socket) do
    request_magic_link(socket.assigns.submitted_email, socket)

    {:noreply,
     put_flash(
       socket,
       :info,
       "If the address can receive email, another sign-in link is on its way."
     )}
  end

  def handle_event("use_another", _params, socket) do
    {:noreply,
     socket
     |> assign(:state, :request)
     |> assign(:submitted_email, nil)
     |> clear_flash()}
  end

  defp request_magic_link(email, socket) do
    HostedAccess.request_magic_link(email, %{
      ip_address: socket.assigns.ip_address,
      return_to: socket.assigns.return_to
    })
  end

  defp request_ip(socket) do
    if connected?(socket) do
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _unavailable -> nil
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-xl">
      <:actions>
        <.button
          :if={@current_hosted_identity}
          variant="ghost"
          size="sm"
          navigate={~p"/hosted/access/sessions"}
        >
          Active sessions
        </.button>
      </:actions>

      <section
        :if={@state == :request}
        id="hosted-access-request"
        class="rounded-xl border border-line bg-surface p-5 sm:p-7"
        phx-mounted={JS.focus(to: "#hosted-email")}
      >
        <div class="flex items-start gap-4">
          <span class="w-11 h-11 rounded-xl bg-primary-tint text-primary flex-none flex items-center justify-center">
            <.lucide name="lock" class="size-5" />
          </span>
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-primary">Hosted storage</p>
            <h1 class="mt-1 text-2xl font-bold tracking-tight text-ink">
              Verify your email to continue
            </h1>
            <p class="mt-2 text-sm leading-relaxed text-ink-muted">
              Your verified email is the access method for hosted project data. We’ll send one
              sign-in link that expires after 15 minutes and works once.
            </p>
          </div>
        </div>

        <.notice variant="warn" class="mt-5">
          <p class="font-semibold">Keep access to this email</p>
          <p class="mt-1">
            If you lose it, this release can restore access only through another sign-in method
            you linked beforehand. Support can’t bypass that proof.
          </p>
        </.notice>

        <form id="hosted-access-form" phx-submit="request" class="mt-6 space-y-4">
          <.text_field
            id="hosted-email"
            name="email"
            type="text"
            inputmode="email"
            autocomplete="email"
            maxlength="320"
            label="Email address"
            hint="We use this address only for hosted access and security."
            placeholder="you@example.com"
          />
          <.button type="submit" size="lg" class="w-full">
            Send sign-in link <.lucide name="arrow-right" class="size-4" />
          </.button>
        </form>

        <p class="mt-4 text-xs leading-relaxed text-ink-muted">
          You’ll see the same confirmation whether or not an account already exists.
        </p>
      </section>

      <section
        :if={@state == :waiting}
        id="hosted-access-waiting"
        class="rounded-xl border border-line bg-surface p-6 sm:p-8 text-center"
        role="status"
        aria-live="polite"
      >
        <span class="w-13 h-13 mx-auto rounded-xl bg-info-bg text-info-fg flex items-center justify-center">
          <.lucide name="circle-check" class="size-6" />
        </span>
        <h1
          id="waiting-heading"
          tabindex="-1"
          phx-mounted={JS.focus()}
          class="mt-4 text-2xl font-bold tracking-tight text-ink outline-none"
        >
          Check your email
        </h1>
        <p class="mt-2 mx-auto max-w-md text-sm leading-relaxed text-ink-muted">
          If the address can receive email, a sign-in link is on its way. It expires after 15
          minutes and can be used once.
        </p>

        <div class="mt-6 flex flex-col sm:flex-row sm:justify-center gap-2.5">
          <.button type="button" phx-click="resend">
            <.lucide name="refresh-cw" class="size-4" /> Resend email
          </.button>
          <.button type="button" variant="secondary" phx-click="use_another">
            Use another email
          </.button>
        </div>

        <.notice variant="neutral" class="mt-6 text-left">
          Opening an older link after a resend won’t sign you in. Only the newest link remains
          valid.
        </.notice>
      </section>

      <div class="mt-5 flex items-center justify-between gap-3 text-[13px]">
        <.link
          navigate={~p"/"}
          class="font-semibold text-primary underline underline-offset-2 rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          Back to sign in
        </.link>
        <span class="flex items-center gap-1.5 text-ink-muted">
          <.lucide name="shield" class="size-4" /> No password is stored
        </span>
      </div>
    </.app_shell>
    """
  end
end
