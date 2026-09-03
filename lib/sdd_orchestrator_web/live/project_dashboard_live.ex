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

  The account it acts as comes from `SddOrchestratorWeb.ActingIdentity`, so a
  person signed in only through the passwordless email link opens the projects
  their account owns (specs/45 Task 2). The screen never picks a credential
  itself, and the workspace scoping above is still the only authorization.

  The GitHub connection presentation is keyed on the project having a repository
  connection (specs/45 Task 6): the status badge, the access-lost notice with
  `Check again`, and the `Repository` row all render only when `@connection` is
  present. A hosted project whose repository is a local Git repository has no
  connection row, so those three would report a lost GitHub repository the
  project never had. The machine region below is the one place that states where
  such a repository is and whether that Mac is reachable.

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

  The folder question is asked of the machine, not answered on this node
  (specs/40 Task 6). The repository is on the owner's Mac and a person takes
  tens of seconds to answer a native panel, so the connect action confirms the
  machine, checks its worker is attached, asks that worker to open its picker,
  and then waits. The owner's answer arrives as one
  `{:repository_selection, request_id, outcome}` message and only then is the
  connect gate called. Waiting, cancel, and no-answer are page states rather
  than a blocked call, and the request is bound to this LiveView process, so
  closing the tab closes the panel.

  The same action moves a connected project to a different machine (specs/37
  Task 5): replacement runs through the identical gate, so it is atomic and a
  failed replacement leaves the previous machine authoritative. Disconnect
  removes the routing only and is idempotent; the project, its specifications,
  and its repository are untouched.

  The screen's own controls follow the acting account's GitHub identity
  (specs/45 Task 7), the same way the catalog's do: a control is offered only
  when the acting session can open what it leads to, and sign-out ends the
  session that person actually holds. Only the GitHub sign-in issues the
  application session, so an account with no GitHub identity signs out through
  `SddOrchestratorWeb.SessionControls.sign_out_path/1` and is offered no backup,
  which stays behind that session.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus
  import SddOrchestratorWeb.SessionControls

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Devices.WorkerDiscovery

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBindings,
    HostedLocalRepositoryConnection,
    HostedLocalRepositoryFolder,
    HostedLocalRepositoryMachines
  }

  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Connections
  alias SddOrchestrator.ProjectStorage
  alias SddOrchestrator.RepositorySelection

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    account = socket.assigns.acting_account
    workspace = socket.assigns.acting_workspace

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
         |> assign(:identity, Accounts.get_github_identity(account.id))
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

  # The request server tells the worker to close its panel and then sends this
  # process `:cancelled`, so the page returns to the offer through the one
  # handler every outcome goes through.
  def handle_event("cancel_selection", _params, socket) do
    case socket.assigns.connect_request_id do
      request_id when is_binary(request_id) -> RepositorySelection.cancel(request_id)
      _nothing_open -> :ok
    end

    {:noreply, socket}
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
        socket.assigns.acting_account,
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

  # Exactly one outcome arrives per request. An outcome naming a request this
  # page is not waiting on belongs to a request it already finished or
  # cancelled, so it changes nothing.
  @impl true
  def handle_info({:repository_selection, request_id, outcome}, socket) do
    if request_id == socket.assigns.connect_request_id do
      {:noreply, selection_outcome(socket, outcome)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The proof is built against the identity this page actually asked about, so a
  # verdict cannot be applied to a different one.
  defp selection_outcome(socket, {:selected, result}) do
    proof = HostedLocalRepositoryFolder.proof(result, socket.assigns.connect_identity)

    connect_selected(socket, proof)
  end

  defp selection_outcome(socket, :cancelled) do
    socket |> reset_connect() |> assign_worker_connection()
  end

  defp selection_outcome(socket, {:refused, reason}) do
    socket
    |> reset_connect()
    |> assign(:connect_error, connect_message(refusal(reason)))
    |> assign_worker_connection()
  end

  # A timeout and a lost attachment are one fact to the owner: nothing came
  # back. The page says only that, and offers the action that can change it.
  defp selection_outcome(socket, no_answer) when no_answer in [:timeout, :worker_lost] do
    socket
    |> reset_connect()
    |> assign(:connect_step, :no_answer)
    |> assign_worker_connection()
  end

  defp refusal(:inaccessible), do: :repository_unavailable
  defp refusal(reason), do: reason

  # The gate is called with the machine the request was sent to. It rechecks
  # ownership, worker authorization, and worker availability itself, so a
  # machine revoked or stopped while the panel was open is refused here rather
  # than connected on a stale decision.
  defp connect_selected(socket, proof) do
    worker_id = socket.assigns.connect_worker_id

    case device_workspace() do
      nil ->
        socket |> reset_connect() |> assign(:connect_step, :no_worker_paired)

      device_workspace ->
        socket
        |> reset_connect()
        |> connected(device_workspace, worker_id, proof)
    end
  end

  defp connected(socket, device_workspace, worker_id, proof) do
    case HostedLocalRepositoryConnection.connect(
           socket.assigns.workspace,
           socket.assigns.project.id,
           device_workspace,
           worker_id,
           proof
         ) do
      {:ok, _connected} ->
        assign_worker_connection(socket)

      {:error, reason} ->
        socket
        |> assign(:connect_error, connect_message(reason))
        |> assign_worker_connection()
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

  # The chosen machine is confirmed against the paired set as it is now, its
  # worker must be attached, and the project must hold an identity a machine can
  # actually prove. Only then is the owner asked to point at a folder, because
  # asking first and refusing afterwards wastes the one step only they can do.
  defp connect_machine(socket, worker_id) do
    device_workspace = device_workspace()

    with {:ok, confirmed_worker_id} <-
           HostedLocalRepositoryMachines.confirm(device_workspace, worker_id),
         :ok <- available_machine(device_workspace, confirmed_worker_id),
         {:ok, identity} <- connectable_identity(socket.assigns.project),
         {:ok, request_id} <-
           HostedLocalRepositoryFolder.request(
             %{
               device_workspace_id: device_workspace.id,
               project_id: socket.assigns.project.id
             },
             confirmed_worker_id,
             identity
           ) do
      socket
      |> reset_connect()
      |> assign(:connect_step, :waiting)
      |> assign(:connect_request_id, request_id)
      |> assign(:connect_worker_id, confirmed_worker_id)
      |> assign(:connect_identity, identity)
      |> assign_worker_connection()
    else
      {:error, :no_worker_paired} ->
        socket |> reset_connect() |> assign(:connect_step, :no_worker_paired)

      {:error, reason} ->
        socket
        |> reset_connect()
        |> assign(:connect_error, connect_message(reason))
        |> assign_worker_connection()
    end
  end

  # Only a worker attached right now may be asked to open a picker, and this
  # pre-check reads that through `WorkerDiscovery.status/2` deliberately: it is
  # the same reading the machine picker offers on and the same one
  # `HostedLocalRepositoryConnection.connect/6` refuses on, so a machine cannot
  # pass here and be refused after the owner has already picked a folder.
  # `Devices.worker_available?/1` is the definition underneath; `status/2` is
  # how both the list and the action ask it, because it also applies
  # compatibility and staleness.
  #
  # This screen already owns one sentence for a machine not being reachable, so
  # the refusal is reported as `:worker_unavailable` and rendered by
  # `connect_message/1` rather than given a second wording of its own.
  defp available_machine(device_workspace, worker_id) do
    device_workspace.id
    |> Pairing.active_workers()
    |> Enum.find(&(&1.id == worker_id))
    |> case do
      nil ->
        {:error, :unauthorized_worker}

      worker ->
        if WorkerDiscovery.status([worker]) == :detected,
          do: :ok,
          else: {:error, :worker_unavailable}
    end
  end

  # A project whose identity no machine can prove is refused before a panel
  # opens. The connect gate refuses the same two values for the same reasons;
  # asking here only decides whether the owner is sent looking for a folder that
  # could never match.
  defp connectable_identity(project) do
    case PortableRepositoryIdentity.parse(project.canonical_repository_id) do
      {:ok, _identity} -> {:ok, project.canonical_repository_id}
      {:error, :legacy_identifier} -> {:error, :legacy_repository_identity}
      {:error, :invalid_identifier} -> {:error, :invalid_repository_identity}
    end
  end

  defp reset_connect(socket) do
    socket
    |> assign(:connect_step, nil)
    |> assign(:connect_machines, [])
    |> assign(:connect_error, nil)
    |> assign(:connect_request_id, nil)
    |> assign(:connect_worker_id, nil)
    |> assign(:connect_identity, nil)
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

  # The one sentence this screen has for the machine the owner chose not being
  # reachable. The pre-check and the connect gate report the same fact, so both
  # render this value.
  defp connect_message(:worker_unavailable),
    do: "That machine isn't reachable right now. Open the worker app on it, then try again."

  defp connect_message(:worker_needs_update),
    do:
      "That machine's worker app is too old to open a folder picker. Update it there, then try " <>
        "again."

  defp connect_message(:unauthorized_worker),
    do:
      "That machine isn't paired with your account any more. Pair it again, then connect this " <>
        "project."

  defp connect_message(:selection_required),
    do: "Another machine was paired just now. Choose which machine to connect."

  defp connect_message(:not_a_git_repository),
    do: "That folder isn't a Git repository. Choose a folder that contains a Git repository."

  defp connect_message(:empty_repository),
    do: "That folder is a Git repository with no commits yet. Choose this project's repository."

  defp connect_message(:repository_unavailable),
    do: "That folder couldn't be read. Check it still exists on that machine, then try again."

  # The transport refusing to reach a worker and the gate finding none reachable
  # are the same fact to the owner, so this renders the one sentence above
  # rather than a second copy of it.
  defp connect_message(:no_worker), do: connect_message(:worker_unavailable)

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
  defp machine_label(%{available?: true}, index), do: "Machine #{index} (ready)"
  defp machine_label(%{available?: false}, index), do: "Machine #{index} (not reachable)"

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
        "your repository are unaffected. It reappears as connected once the machine is back."

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
        <%!-- One `Sign out` label, and only the target follows the session the
        person holds. --%>
        <.button variant="secondary" size="sm" href={sign_out_path(@identity)} method="delete">
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
          account={@acting_account}
        />

        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h1 class="text-xl font-bold text-ink truncate" data-project-name>{@project.name}</h1>
            <p class="mt-1 text-sm text-ink-muted">Your project is ready.</p>
          </div>
          <%!-- The badge and the two notices below report GitHub access, so they
          render only for a project that has a repository connection. Without one
          there is no GitHub access to report, and `@status` is `:disconnected`
          for the absence of a connection rather than for lost access. --%>
          <.connection_badge :if={@connection} status={@status} class="flex-none" />
        </div>

        <div :if={@connection && @status == :disconnected} data-disconnected class="mt-4">
          <.notice variant="warn" icon="unplug">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span>
                GitHub access to this repository was lost. Your project is safe. Restore access on
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

        <div
          :if={@connection && @status == :temporarily_unavailable}
          data-unavailable
          class="mt-4"
        >
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
                :if={@connect_step not in [:choosing_machine, :waiting, :no_answer]}
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

              <%!-- The page says what it asked the machine to do and what it
              heard back. It cannot see the Mac, so it never claims a panel is
              on screen. --%>
              <div :if={@connect_step == :waiting} class="mt-3" data-selection-waiting>
                <p class="text-[13px] font-semibold text-ink">Waiting for that machine</p>
                <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
                  We asked its worker app to open a folder picker. Choose the folder that holds
                  this project's repository.
                </p>
                <.button
                  variant="ghost"
                  size="sm"
                  phx-click="cancel_selection"
                  data-cancel-selection
                  class="mt-2 w-full sm:w-auto"
                >
                  Cancel
                </.button>
              </div>

              <div :if={@connect_step == :no_answer} class="mt-3" data-selection-no-answer>
                <p class="text-[13px] font-semibold text-ink">No answer came back</p>
                <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
                  That machine didn't answer the folder request. Open the worker app on it, then
                  try again.
                </p>
                <.button
                  variant="secondary"
                  size="sm"
                  phx-click="connect_machine"
                  data-retry-connect
                  class="mt-2 w-full sm:w-auto"
                >
                  <.lucide name="refresh-cw" class="size-4" /> Try again
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
                    <span class="font-semibold text-ink">{step.title}</span>. {step.detail}
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
          <%!-- The row names a GitHub repository, so it renders only when there
          is one. A project with no connection had an empty labelled row. --%>
          <div :if={@connection} class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink-muted">
              <.lucide name="github" class="size-4" /> Repository
            </dt>
            <dd class="mt-1.5 text-sm font-semibold text-ink" data-repository>
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

        <%!-- The backup screen stays behind the application session, which only
        the GitHub sign-in issues. The section exists to carry that one control,
        and its heading and sentence promise the download it opens, so an
        account with no GitHub identity is offered neither rather than a
        promise it cannot follow. --%>
        <div :if={@identity} class="mt-6 rounded-lg border border-line bg-surface p-4">
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
