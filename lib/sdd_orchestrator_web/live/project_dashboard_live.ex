defmodule SddOrchestratorWeb.ProjectDashboardLive do
  @moduledoc """
  The created project's dashboard (Task 8).

  Opened after registration commits, it shows the linked repository, the selected
  storage mode, and the current connection status. The initial paint shows the
  last confirmed state; the connected mount revalidates GitHub access and persists
  connected/disconnected transitions, while a transient provider outage shows a
  temporarily-unavailable indicator without overwriting the last confirmed state.
  `Check again` re-runs the revalidation so a project that lost access can
  reconnect to the same project without being replaced.

  The post-creation name control is wired to the reusable `Projects.rename_project/2`
  operation (owned by Task 7): a valid rename saves inline; an invalid or
  case-insensitively conflicting name returns inline feedback without changing the
  project or repository identity.

  Mount is workspace-scoped: an unknown, malformed, or cross-workspace project id
  routes back to the catalog so a foreign project is never rendered.

  A project whose repository is a local Git repository also shows its worker
  connection state (specs/37 Task 3): connected, temporarily unavailable, or not
  connected. That state is derived on read through
  `HostedLocalRepositoryBindings.connection_state/3` and is deliberately reduced
  to the state atom alone, so no repository path, credential, worker id, device
  label, compatibility descriptor, or last validation time can be rendered. A
  GitHub-backed project has no such region at all, and the region never claims the
  project itself is missing or broken — it is a machine link that can be
  established or moved.

  The connect action (specs/37 Task 4) is wired here: it resolves the device
  workspace, asks `HostedLocalRepositoryMachines` which machines can be chosen,
  points the chosen machine at a folder through `HostedLocalRepositoryFolder`,
  and calls `HostedLocalRepositoryConnection.connect/6`. Every refusal keeps the
  project exactly as it was and names what the owner can do next.

  The same action moves a connected project to a different machine (specs/37
  Task 5): replacement runs through the identical gate, so it is atomic and a
  failed replacement leaves the previous machine authoritative. Disconnect
  removes the routing only and is idempotent; the project, its specifications,
  and its repository are untouched.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.PortableRepositoryIdentity

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBindings,
    HostedLocalRepositoryConnection,
    HostedLocalRepositoryFolder,
    HostedLocalRepositoryMachines
  }

  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Connections
  alias SddOrchestrator.ProjectStorage

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    account = socket.assigns.current_account
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Connections.project(account, workspace, project_id, revalidate: connected?(socket)) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      entry ->
        {:ok,
         socket
         |> assign(:workspace, workspace)
         |> assign_entry(entry)
         |> assign(:name, entry.project.name)
         |> assign(:name_error, nil)
         |> assign(:rename_saved?, false)
         |> assign(:actor, %{account_id: account.id, hosted_identity_id: nil})
         |> reset_connect()
         |> assign_worker_connection()}
    end
  end

  # Starting the action re-reads the paired set rather than trusting anything the
  # page rendered earlier. One machine connects straight away; more than one is a
  # question only the owner can answer.
  @impl true
  def handle_event("connect_machine", _params, socket) do
    case HostedLocalRepositoryMachines.offer(device_workspace()) do
      {:ok, %{selection: :single, preselected_worker_id: worker_id}} ->
        {:noreply, connect_machine(socket, worker_id)}

      {:ok, %{selection: :explicit, machines: machines}} ->
        {:noreply,
         socket
         |> reset_connect()
         |> assign(:connect_step, :choosing_machine)
         |> assign(:connect_machines, machines)}

      {:error, :no_worker_paired} ->
        {:noreply,
         socket
         |> reset_connect()
         |> assign(:connect_step, :no_worker_paired)}
    end
  end

  def handle_event("connect_selected_machine", %{"worker_id" => worker_id}, socket) do
    {:noreply, connect_machine(socket, worker_id)}
  end

  def handle_event("cancel_connect", _params, socket) do
    {:noreply, reset_connect(socket)}
  end

  # Disconnect removes the routing and nothing else. Repeating it succeeds, so a
  # double submit cannot turn into an error the owner has to interpret.
  def handle_event("disconnect_machine", _params, socket) do
    HostedLocalRepositoryBindings.disconnect(
      socket.assigns.workspace,
      socket.assigns.project.id
    )

    {:noreply, socket |> reset_connect() |> assign_worker_connection()}
  end

  def handle_event("recheck", _params, socket) do
    entry =
      Connections.project(
        socket.assigns.current_account,
        socket.assigns.workspace,
        socket.assigns.project.id,
        revalidate: true
      )

    {:noreply, assign_entry(socket, entry)}
  end

  def handle_event("validate_name", %{"project" => %{"name" => name}}, socket) do
    {:noreply, assign(socket, name: name, name_error: nil, rename_saved?: false)}
  end

  def handle_event("rename", %{"project" => %{"name" => name}}, socket) do
    case Projects.rename_project(socket.assigns.project, name) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:page_title, project.name)
         |> assign(:name, project.name)
         |> assign(:name_error, nil)
         |> assign(:rename_saved?, true)}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           name: name,
           name_error: name_error_message(changeset),
           rename_saved?: false
         )}
    end
  end

  defp assign_entry(socket, entry) do
    socket
    |> assign(:page_title, entry.project.name)
    |> assign(:project, entry.project)
    |> assign(:connection, entry.connection)
    |> assign(:status, entry.status)
  end

  defp name_error_message(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:name] do
      {message, _opts} -> message
      nil -> "is invalid"
    end
  end

  # The chosen machine is confirmed against the paired set as it is now, the
  # machine is pointed at a folder, and only then is the authority gate called.
  # A cancelled folder selection attempts nothing and says nothing.
  defp connect_machine(socket, worker_id) do
    device_workspace = device_workspace()

    with {:ok, confirmed_worker_id} <-
           HostedLocalRepositoryMachines.confirm(device_workspace, worker_id),
         {:ok, proof} <- HostedLocalRepositoryFolder.select(),
         {:ok, _connected} <-
           HostedLocalRepositoryConnection.connect(
             socket.assigns.workspace,
             socket.assigns.project.id,
             device_workspace,
             confirmed_worker_id,
             proof
           ) do
      socket |> reset_connect() |> assign_worker_connection()
    else
      {:error, :cancelled} ->
        socket |> reset_connect() |> assign_worker_connection()

      {:error, :no_worker_paired} ->
        socket |> reset_connect() |> assign(:connect_step, :no_worker_paired)

      {:error, reason} ->
        socket
        |> reset_connect()
        |> assign(:connect_error, connect_message(reason))
        |> assign_worker_connection()
    end
  end

  defp reset_connect(socket) do
    socket
    |> assign(:connect_step, nil)
    |> assign(:connect_machines, [])
    |> assign(:connect_error, nil)
  end

  # The device store is the worker's own boundary. A machine with no worker
  # running at all answers the same as a machine with no paired worker — install
  # and pair — rather than failing the page.
  defp device_workspace do
    case Devices.get_workspace() do
      {:ok, workspace} -> workspace
      {:error, :not_found} -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp connect_message(:repository_mismatch),
    do:
      "That folder isn't this project's repository. Choose the folder that holds this project's " <>
        "repository and try again."

  defp connect_message(:legacy_repository_identity),
    do:
      "This project still uses a repository identity tied to its original device workspace, " <>
        "which can't be matched exactly. Upgrade that identity by locating the source " <>
        "repository first, then connect a machine."

  defp connect_message(:invalid_repository_identity),
    do:
      "This project's repository identity can't be read, so no machine can prove it. Restore " <>
        "the project from a backup package to re-establish its identity."

  defp connect_message(:worker_unavailable),
    do: "That machine isn't reachable right now. Open the worker app on it, then try again."

  defp connect_message(:unauthorized_worker),
    do:
      "That machine isn't paired with your account any more. Pair it again, then connect this " <>
        "project."

  defp connect_message(:selection_required),
    do: "Another machine was paired just now. Choose which machine to connect."

  defp connect_message(:not_a_git_repository),
    do: "That folder isn't a Git repository. Choose a folder that contains a Git repository."

  defp connect_message(:repository_unavailable),
    do: "That folder couldn't be read. Check it still exists on that machine, then try again."

  defp connect_message(:picker_unavailable),
    do: "Connect the worker on that machine to open its folder picker."

  defp connect_message(_reason),
    do: "That machine couldn't check the folder. Try again."

  # Only the derived state is kept. The binding itself carries the worker id and
  # the last validation time, and neither may reach the page.
  defp assign_worker_connection(socket) do
    project = socket.assigns.project

    cond do
      not local_repository_project?(project) ->
        assign(socket, :worker_connection, nil)

      # A local project whose repository identity cannot be parsed — a legacy
      # workspace-scoped value, or a malformed one — has no binding and cannot be
      # given one. It is still a local-repository project and still not
      # connected, so it keeps its region and the connect action explains why.
      # That case is decided here rather than read from the binding boundary's
      # error, which does not promise it in its own contract.
      not portable_identity?(project.canonical_repository_id) ->
        assign(socket, :worker_connection, :disconnected)

      true ->
        assign_derived_worker_connection(socket, project)
    end
  end

  defp assign_derived_worker_connection(socket, project) do
    case HostedLocalRepositoryBindings.connection_state(socket.assigns.workspace, project.id) do
      {:ok, %{state: state}} -> assign(socket, :worker_connection, state)
      {:error, _reason} -> assign(socket, :worker_connection, nil)
    end
  end

  defp local_repository_project?(%{storage_mode: "hosted", repository_provider: "local"}),
    do: true

  defp local_repository_project?(_project), do: false

  defp portable_identity?(repository_id),
    do: match?({:ok, _identity}, PortableRepositoryIdentity.parse(repository_id))

  defp connect_label(:disconnected), do: "Connect this machine"
  defp connect_label(_connected), do: "Connect a different machine"

  # A worker carries no device label, so machines are distinguished by the order
  # they are offered plus whether they can be reached right now. Presenting more
  # worker data is the deferred minimization decision this slice records.
  defp machine_label(%{available?: true}, index), do: "Machine #{index} — ready"
  defp machine_label(%{available?: false}, index), do: "Machine #{index} — not reachable"

  defp worker_icon(:connected), do: "link"
  defp worker_icon(:temporarily_unavailable), do: "wifi"
  defp worker_icon(:disconnected), do: "unplug"

  defp worker_tone(:connected), do: "text-ok-fg"
  defp worker_tone(:temporarily_unavailable), do: "text-warn-fg"
  defp worker_tone(:disconnected), do: "text-ink-muted"

  defp worker_title(:connected), do: "Connected to your machine"
  defp worker_title(:temporarily_unavailable), do: "Your machine isn't reachable right now"
  defp worker_title(:disconnected), do: "No machine connected yet"

  defp worker_detail(:connected),
    do:
      "This project's repository is on a machine you connected. Development runs use that machine."

  defp worker_detail(:temporarily_unavailable),
    do:
      "The connected machine hasn't checked in recently. Your project, its specifications, and " <>
        "your repository are unaffected — it reappears as connected once the machine is back."

  defp worker_detail(:disconnected),
    do:
      "This project's repository lives on your own machine. Connect that machine to run " <>
        "development here. Your project and its specifications are already saved."

  defp storage_icon("device"), do: "hard-drive"
  defp storage_icon(_), do: "cloud"

  defp storage_label(mode) do
    case ProjectStorage.parse_mode(mode) do
      {:ok, parsed} -> ProjectStorage.label(parsed)
      :error -> mode
    end
  end

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

      <div data-screen="project-dashboard">
        <%!-- Mount is workspace-scoped, so reaching this screen already proves
        ownership. A device-authoritative project has no participation and no
        feature board, so it is offered no project navigation. --%>
        <.project_nav
          :if={@project.storage_mode == "hosted"}
          project_id={@project.id}
          current={:overview}
          owner?={true}
          class="mb-6"
        />

        <.live_component
          :if={@project.storage_mode == "hosted"}
          module={SddOrchestratorWeb.ProjectAssistantPanel}
          id={"project-assistant-" <> @project.id}
          project_id={@project.id}
          actor={@actor}
          account={@current_account}
        />

        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h1 class="text-xl font-bold text-ink truncate" data-project-name>{@project.name}</h1>
            <p class="mt-1 text-sm text-ink-muted">Your project is ready.</p>
          </div>
          <.connection_badge status={@status} class="flex-none" />
        </div>

        <div :if={@status == :disconnected} data-disconnected class="mt-4">
          <.notice variant="warn" icon="unplug">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span>
                GitHub access to this repository was lost. Your project is safe — restore access on
                GitHub, then check again.
              </span>
              <.button
                variant="secondary"
                size="sm"
                phx-click="recheck"
                data-recheck
                class="flex-none"
              >
                <.lucide name="refresh-cw" class="size-4" /> Check again
              </.button>
            </div>
          </.notice>
        </div>

        <div :if={@status == :temporarily_unavailable} data-unavailable class="mt-4">
          <.notice variant="info" icon="refresh-cw">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span>
                GitHub is temporarily unreachable, so the connection can't be confirmed right now.
              </span>
              <.button
                variant="secondary"
                size="sm"
                phx-click="recheck"
                data-recheck
                class="flex-none"
              >
                <.lucide name="refresh-cw" class="size-4" /> Check again
              </.button>
            </div>
          </.notice>
        </div>

        <div
          :if={@worker_connection}
          data-worker-connection={@worker_connection}
          class="mt-4 rounded-lg border border-line bg-surface p-4"
        >
          <div class="flex items-start gap-3">
            <.lucide
              name={worker_icon(@worker_connection)}
              class={["size-5 flex-none mt-px", worker_tone(@worker_connection)]}
            />
            <div class="min-w-0 flex-1">
              <p class="text-sm font-semibold text-ink" data-worker-connection-title>
                {worker_title(@worker_connection)}
              </p>
              <p
                class="mt-1 text-[13px] leading-relaxed text-ink-muted"
                data-worker-connection-detail
              >
                {worker_detail(@worker_connection)}
              </p>

              <div
                :if={@connect_step != :choosing_machine}
                class="mt-3 flex flex-col gap-2 sm:flex-row sm:items-center"
              >
                <.button
                  variant="secondary"
                  size="sm"
                  phx-click="connect_machine"
                  data-connect-machine
                  class="w-full sm:w-auto"
                >
                  <.lucide name="link" class="size-4" /> {connect_label(@worker_connection)}
                </.button>

                <.button
                  :if={@worker_connection != :disconnected}
                  variant="ghost"
                  size="sm"
                  phx-click="disconnect_machine"
                  data-disconnect-machine
                  class="w-full sm:w-auto"
                >
                  <.lucide name="unplug" class="size-4" /> Disconnect
                </.button>
              </div>

              <div :if={@connect_step == :choosing_machine} class="mt-3" data-choose-machine>
                <p class="text-[13px] font-semibold text-ink">
                  Choose which machine holds this repository
                </p>
                <div class="mt-2 flex flex-col gap-2">
                  <.button
                    :for={{machine, index} <- Enum.with_index(@connect_machines, 1)}
                    variant="secondary"
                    size="sm"
                    phx-click="connect_selected_machine"
                    phx-value-worker_id={machine.worker_id}
                    data-machine-option={machine.worker_id}
                    class="w-full sm:w-auto"
                  >
                    <.lucide name="hard-drive" class="size-4" />
                    {machine_label(machine, index)}
                  </.button>
                </div>
                <.button
                  variant="ghost"
                  size="sm"
                  phx-click="cancel_connect"
                  data-cancel-connect
                  class="mt-2 w-full sm:w-auto"
                >
                  Not now
                </.button>
              </div>

              <div :if={@connect_step == :no_worker_paired} class="mt-3" data-no-worker-paired>
                <p class="text-[13px] leading-relaxed text-ink-muted">
                  {HostedLocalRepositoryMachines.guidance().headline}
                </p>
                <ol class="mt-2 flex flex-col gap-2">
                  <li
                    :for={step <- HostedLocalRepositoryMachines.guidance().steps}
                    class="text-[13px] leading-relaxed text-ink-muted"
                  >
                    <span class="font-semibold text-ink">{step.title}</span> — {step.detail}
                  </li>
                </ol>
                <.button
                  variant="secondary"
                  size="sm"
                  href="/downloads/worker"
                  class="mt-3 w-full sm:w-auto"
                >
                  <.lucide name="download" class="size-4" /> Download worker app
                </.button>
              </div>

              <div :if={@connect_error} class="mt-3" role="alert" data-connect-error>
                <.notice variant="warn" icon="triangle-alert">{@connect_error}</.notice>
              </div>
            </div>
          </div>
        </div>

        <dl class="mt-6 flex flex-col gap-3">
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name="github" class="size-4" /> Repository
            </dt>
            <dd :if={@connection} class="mt-1.5 text-sm font-semibold text-ink" data-repository>
              {@connection.full_name || @connection.name}
            </dd>
          </div>

          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name={storage_icon(@project.storage_mode)} class="size-4" /> Project work saved
            </dt>
            <dd class="mt-1.5 text-sm font-semibold text-ink" data-storage-mode>
              {storage_label(@project.storage_mode)}
            </dd>
          </div>
        </dl>

        <form id="project-rename-form" phx-change="validate_name" phx-submit="rename" class="mt-6">
          <.text_field
            id="project-name"
            name="project[name]"
            label="Project name"
            value={@name}
            error={@name_error}
            hint="You can use spaces and any language. Renaming keeps the linked repository."
            autocomplete="off"
            phx-debounce="200"
          />
          <div class="mt-3 flex items-center gap-3">
            <.button type="submit">
              <.lucide name="pencil" class="size-4" /> Save name
            </.button>
            <span
              :if={@rename_saved?}
              class="inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
              data-rename-saved
            >
              <.lucide name="circle-check" class="size-4" /> Saved
            </span>
          </div>
        </form>

        <div class="mt-6 rounded-lg border border-line bg-surface p-4">
          <p class="text-[13px] font-semibold text-ink">Back up this project</p>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Download an encrypted package containing this project's identity, repository identity,
            and current specifications.
          </p>
          <.button
            variant="secondary"
            size="sm"
            navigate={~p"/projects/#{@project.id}/backup"}
            data-backup-project
            class="mt-3 w-full sm:w-auto"
          >
            <.lucide name="download" class="size-4" /> Create backup
          </.button>
        </div>
      </div>
    </.app_shell>
    """
  end
end
