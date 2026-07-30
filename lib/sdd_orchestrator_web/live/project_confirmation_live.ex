defmodule SddOrchestratorWeb.ProjectConfirmationLive do
  @moduledoc """
  The final-confirmation step: review the selected repository, storage choice, and
  editable project name, then create the project.

  The name field is pre-filled with the repository-derived default, allocating the
  lowest available numeric suffix when the name is already used in the workspace.
  Accepting the suggested default stays safe under concurrency (the next suffix is
  allocated on a race); an edited name that collides returns inline feedback rather
  than being silently changed. Creation is atomic — the project, its canonical
  repository connection, and its storage state commit together or not at all — and
  a repository already linked in the workspace is reported with the existing
  project instead of creating a duplicate.

  Mount is workspace-scoped: an unknown, malformed, or cross-workspace attempt id
  routes back to the catalog; an attempt missing a repository or storage mode is
  sent back to the storage step; an already-consumed attempt routes to the project
  it created.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectStorage

  @impl true
  def mount(%{"attempt_id" => attempt_id}, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Projects.get_onboarding_attempt(workspace, attempt_id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      %{consumed_at: consumed} = attempt when not is_nil(consumed) ->
        # Already created: route to the project rather than re-confirm.
        {:ok, route_to_created_project(socket, workspace, attempt)}

      %{selected_repository: repo, storage_mode: mode} = attempt
      when is_nil(repo) or is_nil(mode) ->
        {:ok, push_navigate(socket, to: ~p"/onboarding/storage/#{attempt.id}")}

      attempt ->
        {:ok, mount_confirmation(socket, workspace, attempt)}
    end
  end

  defp mount_confirmation(socket, workspace, attempt) do
    default_name =
      Projects.default_project_name(workspace, repository_name(attempt.selected_repository))

    socket
    |> assign(:page_title, "Confirm project")
    |> assign(:workspace, workspace)
    |> assign(:attempt, attempt)
    |> assign(:selected_repository, attempt.selected_repository)
    |> assign(:storage_mode, attempt.storage_mode)
    |> assign(:storage_label, storage_label(attempt.storage_mode))
    |> assign(:suggested_default, default_name)
    |> assign(:name, default_name)
    |> assign(:name_edited?, false)
    |> assign(:name_error, nil)
    |> assign(:repo_conflict, nil)
    |> assign(:transaction_error, nil)
  end

  # A created project hands off to its landing decision, which is a plain
  # request rather than a LiveView, so this redirects instead of navigating.
  defp route_to_created_project(socket, workspace, attempt) do
    case Projects.register_project(workspace, attempt, []) do
      {:ok, project} -> redirect(socket, to: ~p"/projects/#{project.id}")
      _ -> push_navigate(socket, to: ~p"/projects")
    end
  end

  @impl true
  def handle_event("validate", %{"project" => %{"name" => name}}, socket) do
    {:noreply,
     socket
     |> assign(:name, name)
     |> assign(:name_edited?, String.trim(name) != socket.assigns.suggested_default)
     |> assign(:name_error, nil)
     |> assign(:repo_conflict, nil)
     |> assign(:transaction_error, nil)}
  end

  def handle_event("create", %{"project" => %{"name" => name}}, socket) do
    opts = [name: name, allocate_suffix?: not socket.assigns.name_edited?]

    case Projects.register_project(socket.assigns.workspace, socket.assigns.attempt, opts) do
      {:ok, project} ->
        {:noreply, redirect(socket, to: ~p"/projects/#{project.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, name: name, name_error: name_error_message(changeset))}

      {:error, {:repository_already_linked, existing}} ->
        {:noreply, assign(socket, name: name, repo_conflict: existing)}

      {:error, reason} ->
        {:noreply, assign(socket, name: name, transaction_error: transaction_message(reason))}
    end
  end

  defp name_error_message(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:name] do
      {message, _opts} -> message
      nil -> "is invalid"
    end
  end

  defp transaction_message(reason) when reason in [:storage_not_ready, :storage_mode_required],
    do: "Storage isn't ready yet. Go back and choose an available option."

  defp transaction_message(_reason),
    do: "Something went wrong creating your project. Please try again."

  defp storage_label(mode) do
    case ProjectStorage.parse_mode(mode) do
      {:ok, parsed} -> ProjectStorage.label(parsed)
      :error -> mode
    end
  end

  defp repository_name(repo) when is_map(repo), do: repo["name"] || repo["full_name"] || "project"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/onboarding/storage/#{@attempt.id}"}>
          <.lucide name="arrow-left" class="size-4" /> Back
        </.button>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div data-screen="project-confirmation">
        <h1 class="text-xl font-bold text-ink">Confirm your project</h1>
        <p class="mt-1.5 text-sm leading-relaxed text-ink-muted text-pretty">
          Review the details below, then create your project. Nothing on GitHub changes and no agent
          starts.
        </p>

        <dl class="mt-6 flex flex-col gap-3">
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name="github" class="size-4" /> Repository
            </dt>
            <dd class="mt-1.5 flex flex-wrap items-center gap-2">
              <span class="text-sm font-semibold text-ink" data-selected-repository>
                {@selected_repository["full_name"] || @selected_repository["name"]}
              </span>
              <.badge :if={repo_visibility(@selected_repository)} variant="neutral" icon="lock">
                {repo_visibility(@selected_repository)}
              </.badge>
              <.badge :if={@selected_repository["organization"]} variant="info" icon="building-2">
                {@selected_repository["organization"]}
              </.badge>
            </dd>
          </div>

          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name={storage_icon(@storage_mode)} class="size-4" /> Project work saved
            </dt>
            <dd class="mt-1.5 text-sm font-semibold text-ink" data-storage-mode>
              {@storage_label}
            </dd>
          </div>
        </dl>

        <form id="project-confirmation-form" phx-change="validate" phx-submit="create" class="mt-6">
          <.text_field
            id="project-name"
            name="project[name]"
            label="Project name"
            value={@name}
            error={@name_error}
            hint="You can use spaces and any language. You can rename it later."
            autocomplete="off"
            phx-debounce="200"
          />

          <.notice :if={@repo_conflict} variant="warn" icon="folder-git-2" class="mt-4">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span>
                This repository is already linked to
                <span class="font-semibold">{@repo_conflict.name}</span>
                in this workspace.
              </span>
              <.button
                variant="secondary"
                size="sm"
                href={~p"/projects/#{@repo_conflict.id}"}
                class="flex-none"
              >
                Open {@repo_conflict.name}
              </.button>
            </div>
          </.notice>

          <.notice :if={@transaction_error} variant="err" icon="triangle-alert" class="mt-4">
            {@transaction_error}
          </.notice>

          <div class="mt-6 flex items-center justify-end">
            <.button type="submit" disabled={@repo_conflict != nil}>
              <.lucide name="folder-git-2" class="size-4" /> Create project
            </.button>
          </div>
        </form>
      </div>
    </.app_shell>
    """
  end

  defp repo_visibility(repo) when is_map(repo) do
    case Map.get(repo, "visibility") do
      v when is_binary(v) and v != "" -> v
      _ -> if Map.get(repo, "private"), do: "private", else: "public"
    end
  end

  defp repo_visibility(_), do: nil

  defp storage_icon("device"), do: "hard-drive"
  defp storage_icon(_), do: "cloud"
end
