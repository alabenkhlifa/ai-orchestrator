defmodule SddOrchestratorWeb.RepositoryAccessLive do
  @moduledoc """
  Repository access and selection.

  On mount the account's `Orchestra-workflow` repository access is re-read with
  the user's token (never trusting an installation return by itself). The result
  drives a small state machine:

    * `:checking` — the access check is in flight (initial paint).
    * `:grant` — no accessible installation; the dedicated grant screen with
      `Continue to GitHub`.
    * `:pending` — an organization installation request awaits approval;
      `Waiting for organization approval` with `Check again`.
    * `:picker` — repositories loaded; a searchable, single-selection list.
    * `:empty` — access is granted but no repositories are available.
    * `:error` — a normalized provider failure (`:unauthorized`, `:rate_limited`,
      `:org_restricted`, `:provider_failure`), each shown as a distinct,
      recoverable state.

  No project or repository connection is created here; only the confirmed
  repository selection is persisted onto the workspace-scoped onboarding attempt
  before handing off to the storage step. Mount is workspace-scoped: an unknown,
  malformed, or cross-workspace attempt id routes back to the catalog.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.Projects

  @impl true
  def mount(%{"attempt_id" => attempt_id}, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Projects.get_onboarding_attempt(workspace, attempt_id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      attempt ->
        socket =
          socket
          |> assign(:page_title, "Repository access")
          |> assign(:workspace, workspace)
          |> assign(:attempt, attempt)
          |> assign(:identity, Accounts.get_github_identity(account.id))
          |> assign(:state, :checking)
          |> assign(:repositories, [])
          |> assign(:query, "")
          |> assign(:selected_id, previously_selected_id(attempt))
          |> assign(:pending_org, nil)
          |> assign(:error_reason, nil)

        # Run the network access check only on the connected mount so the initial
        # paint shows the checking state and the check runs once, not twice.
        if connected?(socket) do
          {:ok, run_access_check(socket)}
        else
          {:ok, socket}
        end
    end
  end

  @impl true
  def handle_event("check_again", _params, socket) do
    {:noreply, socket |> assign(:state, :checking) |> run_access_check()}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :query, query)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, parse_id(id))}
  end

  def handle_event("continue", _params, socket) do
    with id when not is_nil(id) <- socket.assigns.selected_id,
         repo when not is_nil(repo) <- Enum.find(socket.assigns.repositories, &(&1.id == id)),
         {:ok, _attempt} <-
           Projects.select_repository(
             socket.assigns.workspace,
             socket.assigns.attempt.id,
             repo
           ) do
      {:noreply, push_navigate(socket, to: ~p"/onboarding/storage/#{socket.assigns.attempt.id}")}
    else
      # No selection, or persistence failed: stay on the picker with the current
      # selection so the user can retry. No project or connection was created.
      _ -> {:noreply, socket}
    end
  end

  ## Access check

  defp run_access_check(socket) do
    account = socket.assigns.current_account
    identity = socket.assigns.identity

    case Accounts.valid_access_token(account.id) do
      {:error, _reason} ->
        assign(socket, state: :error, error_reason: :unauthorized)

      {:ok, token} ->
        case GitHubIntegration.check_repository_access(token, identity && identity.github_user_id) do
          {:ok, :granted, installations} -> load_repositories(socket, token, installations)
          {:ok, :pending, org} -> assign(socket, state: :pending, pending_org: org)
          {:ok, :none} -> assign(socket, state: :grant)
          {:error, reason} -> assign(socket, state: :error, error_reason: reason)
        end
    end
  end

  defp load_repositories(socket, token, installations) do
    case GitHubIntegration.list_accessible_repositories(token, installations) do
      {:ok, []} ->
        assign(socket, state: :empty)

      {:ok, repos} ->
        socket
        |> assign(:state, :picker)
        |> assign(:repositories, repos)
        |> assign(:selected_id, keep_selection(socket.assigns.selected_id, repos))

      {:error, reason} ->
        assign(socket, state: :error, error_reason: reason)
    end
  end

  defp previously_selected_id(%{selected_repository: %{"repository_id" => id}})
       when is_integer(id),
       do: id

  defp previously_selected_id(_attempt), do: nil

  defp keep_selection(nil, _repos), do: nil

  defp keep_selection(id, repos) do
    if Enum.any?(repos, &(&1.id == id)), do: id, else: nil
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp filtered_repositories(repositories, query) do
    case String.trim(query) do
      "" ->
        repositories

      trimmed ->
        needle = String.downcase(trimmed)

        Enum.filter(repositories, fn repo ->
          String.contains?(String.downcase(repo.full_name || repo.name || ""), needle)
        end)
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/projects"}>
          <.lucide name="arrow-left" class="size-4" /> Projects
        </.button>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div data-screen="repository-access" data-state={@state}>
        <.checking :if={@state == :checking} />
        <.grant :if={@state == :grant} attempt={@attempt} />
        <.pending :if={@state == :pending} org={@pending_org} />
        <.access_empty :if={@state == :empty} />
        <.access_error :if={@state == :error} reason={@error_reason} />
        <.picker
          :if={@state == :picker}
          repositories={@repositories}
          filtered={filtered_repositories(@repositories, @query)}
          query={@query}
          selected_id={@selected_id}
        />
      </div>
    </.app_shell>
    """
  end

  defp checking(assigns) do
    ~H"""
    <div class="flex flex-col items-center text-center py-16">
      <.spinner class="size-6" label="Checking repository access" />
      <p class="mt-4 text-sm text-ink-muted">Checking your GitHub repository access…</p>
    </div>
    """
  end

  defp grant(assigns) do
    ~H"""
    <div class="text-center py-6 sm:py-10">
      <span class="w-13 h-13 mx-auto rounded-xl bg-primary/10 text-primary flex items-center justify-center p-3">
        <.lucide name="github" class="size-6" />
      </span>
      <h1 class="mt-4 text-xl font-bold text-ink">Grant repository access</h1>
      <p class="mt-2 max-w-md mx-auto text-sm leading-relaxed text-ink-muted text-pretty">
        GitHub controls which repositories SDD Orchestrator can see. Install the
        <span class="font-semibold text-ink">Orchestra-workflow</span>
        app on the account or organization whose repository you want to connect. This grants
        read-only access to repository metadata. It never changes your code.
      </p>

      <div class="mt-6 flex flex-col sm:flex-row items-center justify-center gap-3">
        <.button href={~p"/github/install?#{[attempt_id: @attempt.id]}"}>
          <.lucide name="external-link" class="size-4" /> Continue to GitHub
        </.button>
        <.button variant="secondary" phx-click="check_again">
          <.lucide name="refresh-cw" class="size-4" /> Check again
        </.button>
      </div>
    </div>
    """
  end

  defp pending(assigns) do
    ~H"""
    <div class="text-center py-6 sm:py-10">
      <span class="w-13 h-13 mx-auto rounded-xl bg-warn-bg text-warn-fg flex items-center justify-center p-3">
        <.lucide name="lock" class="size-6" />
      </span>
      <h1 class="mt-4 text-xl font-bold text-ink">Waiting for organization approval</h1>
      <p class="mt-2 max-w-md mx-auto text-sm leading-relaxed text-ink-muted text-pretty">
        Your request to install <span class="font-semibold text-ink">Orchestra-workflow</span>{org_suffix(
          @org
        )} is waiting for an organization owner to approve it. You can continue once it is approved.
      </p>

      <div class="mt-6">
        <.button variant="secondary" phx-click="check_again">
          <.lucide name="refresh-cw" class="size-4" /> Check again
        </.button>
      </div>
    </div>
    """
  end

  defp access_empty(assigns) do
    ~H"""
    <.empty_state icon="folder-git-2" title="No repositories available">
      <:description>
        The installed <span class="font-semibold text-ink">Orchestra-workflow</span>
        app has access to no repositories yet. Add repositories to the installation on GitHub,
        then check again.
      </:description>
      <:actions>
        <.button variant="secondary" phx-click="check_again">
          <.lucide name="refresh-cw" class="size-4" /> Check again
        </.button>
      </:actions>
    </.empty_state>
    """
  end

  defp access_error(assigns) do
    ~H"""
    <.failure_state icon={error_icon(@reason)} title={error_title(@reason)}>
      <:description>{error_message(@reason)}</:description>
      <:actions>
        <.button phx-click="check_again">
          <.lucide name="refresh-cw" class="size-4" /> Try again
        </.button>
        <.button variant="secondary" navigate={~p"/projects"}>Back to projects</.button>
      </:actions>
    </.failure_state>
    """
  end

  defp picker(assigns) do
    ~H"""
    <div>
      <h1 class="text-xl font-bold text-ink">Choose a repository</h1>
      <p class="mt-1.5 text-sm text-ink-muted text-pretty">
        Select the repository to connect to your new project. Only the repository you confirm is linked.
      </p>

      <form id="repository-search-form" phx-change="search" class="mt-5" role="search">
        <label for="repository-search" class="sr-only">Search repositories</label>
        <div class="relative">
          <span class="absolute inset-y-0 left-3 flex items-center text-ink-muted">
            <.lucide name="search" class="size-4" />
          </span>
          <input
            id="repository-search"
            name="query"
            type="text"
            value={@query}
            autocomplete="off"
            phx-debounce="150"
            placeholder="Search by name or owner"
            class="w-full h-10 rounded-lg border border-line-strong bg-surface pl-9 pr-3 text-sm text-ink outline-none focus:outline focus:outline-2 focus:outline-offset-0 focus:outline-focus focus:border-focus"
          />
        </div>
      </form>

      <div :if={@filtered == []} class="mt-6">
        <.empty_state icon="search-x" title="No repositories match your search">
          <:description>
            No repository matches “{@query}”. Try a different name or owner.
          </:description>
        </.empty_state>
      </div>

      <div
        :if={@filtered != []}
        id="repository-list"
        role="radiogroup"
        aria-label="Repositories"
        class="mt-5 flex flex-col gap-2"
      >
        <.radio_option
          :for={repo <- @filtered}
          id={"repository-#{repo.id}"}
          selected={@selected_id == repo.id}
          label={repo.full_name || repo.name}
          phx-click="select"
          phx-value-id={repo.id}
        >
          <div class="flex items-center gap-2 min-w-0">
            <span class="min-w-0 truncate text-sm font-semibold text-ink">
              <span class="text-ink-muted font-normal">{repo.owner}/</span>{repo.name}
            </span>
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-1.5">
            <.badge :if={repo.private} variant="neutral" icon="lock">Private</.badge>
            <.badge :if={!repo.private} variant="neutral" icon="globe">Public</.badge>
            <.badge :if={repo.organization} variant="info" icon="building-2">
              {repo.organization}
            </.badge>
          </div>
        </.radio_option>
      </div>

      <div class="mt-6 flex items-center justify-between gap-3">
        <p class="text-xs text-ink-muted">
          {length(@repositories)} {pluralize(length(@repositories), "repository", "repositories")} available
        </p>
        <.button phx-click="continue" disabled={is_nil(@selected_id)}>
          Continue <.lucide name="arrow-right" class="size-4" />
        </.button>
      </div>
    </div>
    """
  end

  ## Copy helpers

  defp org_suffix(nil), do: ""
  defp org_suffix(org), do: " for #{org}"

  defp error_icon(:rate_limited), do: "loader"
  defp error_icon(:org_restricted), do: "shield"
  defp error_icon(_), do: "triangle-alert"

  defp error_title(:unauthorized), do: "GitHub sign-in needs refreshing"
  defp error_title(:rate_limited), do: "GitHub is rate limiting requests"
  defp error_title(:org_restricted), do: "Organization access is restricted"
  defp error_title(_), do: "Couldn’t load repository access"

  defp error_message(:unauthorized),
    do:
      "We couldn’t confirm your GitHub access. Sign in again to refresh the connection, then retry."

  defp error_message(:rate_limited),
    do: "GitHub temporarily limited how many requests we can make. Wait a moment and try again."

  defp error_message(:org_restricted),
    do:
      "An organization policy (such as SSO or an IP allow-list) is blocking repository access. Approve access in GitHub, then try again."

  defp error_message(_),
    do: "Something went wrong reaching GitHub. Please try again."

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural
end
