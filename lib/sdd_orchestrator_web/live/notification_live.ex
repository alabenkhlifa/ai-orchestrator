defmodule SddOrchestratorWeb.NotificationLive do
  @moduledoc """
  The accessible, durable notification inbox (specs/17 Task 4, AC-04).

  Lists one signed-in account's guided-delivery notifications across every
  project it currently participates in, newest first. Every read here is
  revalidated by `SddOrchestrator.Delivery.NotificationAccess` at the moment of
  the request, not at the moment the notification was delivered, so a
  notification whose project access ended between render and action simply
  disappears rather than ever disclosing why.

  An unread notification shows a `Mark read` action; a read one shows a `Read`
  badge instead of the button, matching the badge-vs-button precedent already
  used by `HostedSessionsLive`. `Open` resolves the notification's safe
  in-product link on the server before navigating, so a stale or unauthorized
  id is refused with the same non-disclosing flash `mark_read` uses.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Delivery.NotificationAccess
  alias SddOrchestrator.Notifications.AccountNotification

  @unavailable_flash "That notification is no longer available."

  @impl true
  def mount(_params, _session, socket) do
    actor = actor(socket)

    {:ok,
     socket
     |> assign(:page_title, "Notifications")
     |> assign(:actor, actor)
     |> assign(:account_id, actor.account_id)
     |> load_notifications()}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    socket.assigns.account_id
    |> NotificationAccess.mark_read(socket.assigns.actor, id)
    |> case do
      {:ok, _notification} -> {:noreply, load_notifications(socket)}
      {:error, :not_found} -> {:noreply, unavailable(socket)}
    end
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    socket.assigns.account_id
    |> NotificationAccess.resolve_safe_link(socket.assigns.actor, id)
    |> case do
      {:ok, link_path} -> {:noreply, push_navigate(socket, to: link_path)}
      {:error, :not_found} -> {:noreply, unavailable(socket)}
    end
  end

  defp actor(socket) do
    identity = socket.assigns[:current_hosted_identity]
    account = socket.assigns[:current_account]

    %{
      account_id: (account && account.id) || (identity && identity.account_id),
      hosted_identity_id: identity && identity.id
    }
  end

  defp load_notifications(socket) do
    notifications = NotificationAccess.list(socket.assigns.account_id, socket.assigns.actor)
    assign(socket, :notifications, notifications)
  end

  defp unavailable(socket) do
    socket
    |> put_flash(:error, @unavailable_flash)
    |> load_notifications()
  end

  defp format_occurred(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="ghost" size="sm" navigate={~p"/projects"}>
          Projects
        </.button>
      </:actions>

      <h1 class="text-2xl font-bold tracking-tight text-ink">Notifications</h1>
      <p class="mt-2 max-w-xl text-sm leading-relaxed text-ink-muted">
        Guided-delivery updates for every project you currently participate in.
      </p>

      <div :if={@notifications == []} class="mt-6">
        <.empty_state icon="circle-check" title="You're all caught up">
          <:description>Nothing needs your attention right now.</:description>
        </.empty_state>
      </div>

      <ul
        :if={@notifications != []}
        id="notification-list"
        class="mt-6 flex flex-col gap-2.5"
        aria-label="Notifications"
        data-notification-list
      >
        <li
          :for={notification <- @notifications}
          id={"notification-#{notification.id}"}
          class="rounded-xl border border-line bg-surface p-4"
          data-notification
          data-notification-id={notification.id}
          data-notification-unread={to_string(AccountNotification.unread?(notification))}
        >
          <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3">
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="font-semibold text-ink" data-notification-title>
                  {notification.title}
                </h2>
                <.badge :if={!AccountNotification.unread?(notification)} variant="neutral">
                  Read
                </.badge>
              </div>
              <p class="mt-1 text-sm leading-relaxed text-ink-muted" data-notification-body>
                {notification.body}
              </p>
              <p class="mt-1.5 text-xs text-ink-muted">
                <span :if={notification.project_label}>{notification.project_label} · </span>{format_occurred(
                  notification.occurred_at
                )}
              </p>
            </div>

            <div class="flex items-center gap-2 flex-none">
              <.button
                :if={AccountNotification.unread?(notification)}
                id={"notification-#{notification.id}-mark-read"}
                type="button"
                variant="secondary"
                size="sm"
                phx-click="mark_read"
                phx-value-id={notification.id}
              >
                Mark read
              </.button>
              <.button
                id={"notification-#{notification.id}-open"}
                type="button"
                variant="primary"
                size="sm"
                phx-click="open"
                phx-value-id={notification.id}
              >
                Open
              </.button>
            </div>
          </div>
        </li>
      </ul>
    </.app_shell>
    """
  end
end
