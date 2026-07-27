defmodule SddOrchestratorWeb.HostedSessionsLive do
  @moduledoc "Protected active-device visibility and revocation surface."
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.HostedAccess.Sessions

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Active sessions")
     |> load_sessions()}
  end

  @impl true
  def handle_event("revoke", %{"id" => session_id}, socket) do
    :ok = Sessions.revoke(socket.assigns.current_hosted_identity, session_id)

    {:noreply,
     socket
     |> load_sessions()
     |> put_flash(:info, "That device session has been signed out.")}
  end

  defp load_sessions(socket) do
    current_cookie = socket.assigns.current_hosted_access.session_cookie.value

    assign(
      socket,
      :sessions,
      Sessions.list_active(socket.assigns.current_hosted_identity, current_cookie)
    )
  end

  defp format_seen(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="ghost" size="sm" navigate={~p"/hosted/access"}>
          Hosted access
        </.button>
      </:actions>

      <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">Account security</p>
          <h1 class="mt-1 text-2xl font-bold tracking-tight text-ink">Active sessions</h1>
          <p class="mt-2 max-w-xl text-sm leading-relaxed text-ink-muted">
            Each browser or device has an independent hosted session. Device names are coarse
            hints only; no IP address or fingerprint is stored.
          </p>
        </div>
        <.button
          variant="secondary"
          size="sm"
          href={~p"/hosted/session"}
          method="delete"
          class="sm:flex-none"
        >
          <.lucide name="log-out" class="size-4" /> Sign out this device
        </.button>
      </div>

      <ul id="active-session-list" class="mt-6 space-y-3" aria-label="Active device sessions">
        <li
          :for={entry <- @sessions}
          id={"session-#{entry.session.id}"}
          class="rounded-xl border border-line bg-surface p-4"
        >
          <div class="flex flex-col sm:flex-row sm:items-center gap-4">
            <span class="w-10 h-10 rounded-lg bg-raised text-ink-muted flex-none flex items-center justify-center">
              <.lucide name="globe" class="size-5" />
            </span>

            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="font-semibold text-ink">
                  {entry.session.user_agent_family || "Unknown browser"} on {entry.session.os_family ||
                    "Unknown OS"}
                </h2>
                <.badge :if={entry.current?} variant="ok">Current device</.badge>
              </div>
              <p class="mt-1 text-xs text-ink-muted">
                First seen {format_seen(entry.session.first_seen_at)} · Last active {format_seen(
                  entry.session.last_seen_at
                )}
              </p>
            </div>

            <.button
              :if={!entry.current?}
              type="button"
              variant="secondary"
              size="sm"
              phx-click="revoke"
              phx-value-id={entry.session.id}
              aria-label={"Sign out #{entry.session.user_agent_family || "unknown browser"} on #{entry.session.os_family || "unknown OS"}"}
            >
              Sign out
            </.button>
          </div>
        </li>
      </ul>

      <.notice variant="warn" class="mt-6">
        <p class="font-semibold">Lost access to your email?</p>
        <p class="mt-1">
          Only a sign-in method linked before the loss can restore this identity. An active
          session, support request, or newly asserted method can’t change the verified email.
        </p>
      </.notice>

      <div class="mt-6 rounded-xl border border-err-fg/40 bg-err-bg p-4 sm:flex sm:items-center sm:justify-between gap-4">
        <div>
          <h2 class="font-semibold text-err-fg">Sign out all devices</h2>
          <p class="mt-1 text-sm leading-relaxed text-err-fg">
            Every hosted session, including this one, will require a new verified sign-in.
          </p>
        </div>
        <.button
          variant="secondary"
          size="sm"
          href={~p"/hosted/sessions"}
          method="delete"
          class="mt-3 sm:mt-0 sm:flex-none"
        >
          Sign out all devices
        </.button>
      </div>
    </.app_shell>
    """
  end
end
