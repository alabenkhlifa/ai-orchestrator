defmodule SddOrchestratorWeb.ProjectsLive do
  @moduledoc """
  The protected project catalog and the post-authentication routing decision.

  The screen serves whichever sign-in the browser carries, so it reads the
  account and personal workspace `SddOrchestratorWeb.ActingIdentity` resolved
  rather than the application session's account.

  A workspace that already owns projects renders its catalog with a non-mutating
  `Add project` control; an empty workspace continues straight to the
  repository-access check without another action. `Add project` and the
  empty-workspace continuation both open a fresh onboarding attempt and hand off
  to the repository-access check; neither creates a project or repository
  connection.

  Both of those are GitHub screens, so both are offered only to an acting
  account that has a GitHub identity. An account without one keeps the catalog
  and is pointed at the local repository flow it can actually use. Its header
  drops the identity chip and every control that leads to an
  application-session-only screen, and its sign-out ends the hosted session.

  Each catalog row shows its repository-connection status. The initial paint shows
  the last confirmed state; the connected mount revalidates access and updates
  connected/disconnected transitions, and `Check again` re-runs the revalidation so
  a project that lost access can reconnect without being replaced.

  Both the badge and `Check again` are keyed on the entry having a repository
  connection, the same way `ProjectDashboardLive` keys its GitHub presentation
  (specs/45 Task 6). A hosted project whose repository is a local Git repository
  has no connection row, so both would otherwise report lost access to a
  repository the project never had.

  A row is keyed by storage mode and project id together, not by project id alone.
  Two separately authoritative records may share one stable project id, and the
  catalog deliberately keeps both as their own row; keying on the id alone would
  give those rows one DOM id, which collapses them into a single node for LiveView
  patching and for assistive technology.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Catalog
  alias SddOrchestrator.Projects

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.acting_workspace
    identity = Accounts.get_github_identity(socket.assigns.acting_account.id)

    socket =
      socket
      |> assign(:page_title, "Projects")
      |> assign(:workspace, workspace)
      |> assign(:identity, identity)

    # The empty-workspace continuation goes to the repository-access check, which
    # is a GitHub screen behind the application session. An account with no
    # GitHub identity cannot take it, so it renders the catalog instead.
    if Projects.has_projects?(workspace) or is_nil(identity) do
      {:ok, load_catalog(socket, revalidate: connected?(socket))}
    else
      {:ok, continue_to_repository_access(socket, workspace)}
    end
  end

  # The handoff opens a GitHub screen, so the control is not rendered for an
  # account with no GitHub identity. Not rendering it does not stop the event
  # from arriving, and acting on it would write an onboarding attempt that
  # account can never spend, so the handler refuses it and changes nothing.
  @impl true
  def handle_event("add_project", _params, %{assigns: %{identity: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("add_project", _params, socket) do
    {:noreply, continue_to_repository_access(socket, socket.assigns.workspace)}
  end

  def handle_event("recheck", _params, socket) do
    {:noreply, load_catalog(socket, revalidate: true)}
  end

  defp load_catalog(socket, opts) do
    account = socket.assigns.acting_account
    entries = Catalog.combined(account, socket.assigns.workspace, opts)

    socket
    |> assign(:entries, entries)
    |> assign(:any_needs_attention?, Enum.any?(entries, &needs_attention?/1))
  end

  # Only hosted connections revalidate through `Check again`; a device project's
  # availability follows the local worker, not this control. A hosted project
  # with no repository connection has no GitHub access to recheck either, so it
  # never puts the control on the page by itself.
  defp needs_attention?(%{
         storage_mode: "hosted",
         repository_connection?: true,
         availability: availability
       }),
       do: availability != :connected

  defp needs_attention?(_entry), do: false

  # Non-mutating handoff into onboarding: reuse or open an onboarding attempt and
  # route to the repository-access check. No project or connection is created.
  defp continue_to_repository_access(socket, workspace) do
    {:ok, attempt} = Projects.get_or_start_onboarding_attempt(workspace)
    push_navigate(socket, to: ~p"/onboarding/repository-access/#{attempt.id}")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell>
      <%!-- The identity chip, Notifications, and AI Connections all belong to a
      GitHub owner: the chip has nothing to show without an identity, and both
      screens require the application session, so following either would send a
      passwordless owner back to the entry surface. --%>
      <:actions>
        <span
          :if={@identity}
          class="hidden sm:flex items-center gap-2 text-[13px] text-ink-muted"
        >
          <span class="w-7 h-7 rounded-full bg-raised text-ink-muted flex items-center justify-center text-xs font-bold">
            {initials(@identity)}
          </span>
          {@identity.login}
        </span>
        <.button
          :if={@identity}
          variant="ghost"
          size="sm"
          navigate={~p"/notifications"}
          data-notifications-link
        >
          Notifications
        </.button>
        <.button
          :if={@identity}
          variant="ghost"
          size="sm"
          navigate={~p"/ai-connections"}
          data-ai-connections-link
        >
          <.lucide name="link" class="size-4" /> AI Connections
        </.button>
        <.button variant="secondary" size="sm" href={sign_out_path(@identity)} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div class="flex items-center justify-between gap-4">
        <h1 class="text-xl font-bold text-ink">Projects</h1>
        <div class="flex items-center gap-2.5">
          <.button
            :if={@any_needs_attention?}
            variant="secondary"
            phx-click="recheck"
            data-recheck
          >
            <.lucide name="refresh-cw" class="size-4" /> Check again
          </.button>
          <.button :if={@identity} phx-click="add_project">
            <.lucide name="plus" class="size-4" /> Add project
          </.button>
          <.button variant="secondary" navigate={~p"/restore"} data-restore-backup>
            <.lucide name="folder-open" class="size-4" /> Restore backup
          </.button>
        </div>
      </div>

      <%!-- Only an account without a GitHub identity reaches an empty catalog;
      a GitHub account with an empty workspace continues to the repository-access
      check on mount. So the one way forward offered here is the local
      repository flow, which any session can open. --%>
      <div
        :if={@entries == []}
        data-empty-catalog
        class="mt-6 rounded-xl border border-line bg-surface p-7 text-center"
      >
        <span class="w-12 h-12 mx-auto rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="folder-open" class="size-5" />
        </span>
        <h2 class="mt-4 text-lg font-bold text-ink">No projects yet</h2>
        <p class="mt-2 text-sm leading-relaxed text-ink-muted">
          Create one from a repository on your computer.
        </p>
        <.button
          variant="secondary"
          navigate={~p"/onboarding/local"}
          class="mt-5"
          data-local-onboarding
        >
          <.lucide name="truck" class="size-4" /> Work without GitHub
        </.button>
      </div>

      <ul id="project-catalog" class="mt-6 flex flex-col gap-2.5">
        <li
          :for={entry <- @entries}
          id={"project-#{entry.storage_mode}-#{entry.id}"}
          data-project-row
          data-id={entry.id}
          data-storage-mode={entry.storage_mode}
        >
          <%!-- A hosted row opens the project's landing decision, which is a
          plain request rather than a LiveView, and a device row crosses into
          another live session. Both are a full page load either way, so this
          asks for one directly instead of letting live navigation discover it. --%>
          <.link
            href={entry.route}
            class="flex items-center gap-3 rounded-lg border border-line bg-surface p-4 hover:border-line-strong focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            <span class="flex-none w-9 h-9 rounded-lg bg-raised text-ink-muted flex items-center justify-center">
              <.lucide name={mode_icon(entry.storage_mode)} class="size-[18px]" />
            </span>
            <span class="min-w-0 flex-1">
              <span class="block truncate text-sm font-semibold text-ink">{entry.name}</span>
              <span class="block truncate text-[13px] text-ink-muted">
                {mode_label(entry.storage_mode)}{if entry.repository_label,
                  do: " · " <> entry.repository_label}
              </span>
              <span
                :if={entry.identity_conflict?}
                data-identity-conflict
                class="mt-1 flex items-center gap-1 text-[12px] font-semibold text-err-fg"
              >
                <.lucide name="triangle-alert" class="size-3.5" />
                Identity conflict: this project also exists in another storage location.
              </span>
            </span>
            <%!-- The GitHub badge renders only for a project that has a
            repository connection. Without one there is no GitHub access to
            report, and the badge would read as lost access to a repository the
            project never had. --%>
            <.connection_badge
              :if={entry.storage_mode == "hosted" and entry.repository_connection?}
              status={entry.availability}
              class="flex-none"
            />
            <.device_connection_badge
              :if={entry.storage_mode == "device"}
              status={device_status(entry.availability)}
              class="flex-none"
            />
          </.link>
        </li>
      </ul>
    </.app_shell>
    """
  end

  defp mode_icon("device"), do: "hard-drive"
  defp mode_icon(_hosted), do: "cloud"

  defp mode_label("device"), do: "On this device"
  defp mode_label(_hosted), do: "In my SDD Orchestrator account"

  defp device_status(:available), do: "connected"
  defp device_status(_unavailable), do: "unavailable"

  # Sign out ends the session the person actually holds. Only GitHub sign-in
  # issues the application session, so an account with no GitHub identity is
  # here on its hosted session and that is the one to revoke.
  defp sign_out_path(nil), do: ~p"/hosted/session"
  defp sign_out_path(_identity), do: ~p"/auth/sign_out"

  defp initials(%{login: login}) when is_binary(login) do
    login |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(0, 2) |> String.upcase()
  end

  defp initials(_), do: "?"
end
