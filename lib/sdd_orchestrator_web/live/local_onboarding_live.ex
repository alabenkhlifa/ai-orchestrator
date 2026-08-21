defmodule SddOrchestratorWeb.LocalOnboardingLive do
  @moduledoc """
  Accountless local-repository onboarding (`specs/02-local-project-onboarding/`).

  The `Work without GitHub` entry action lands here. The path is accountless: it
  uses the single device workspace (`Devices.establish_workspace/0`) and never a
  hosted account or session. The whole flow lives in this one LiveView as internal
  steps:

    1. `:discovery` — a storage-mode explanation followed by worker discovery
       (`Devices.worker_status/1`). Each of the four states — missing, incompatible,
       unavailable, detected — gets graphical, terminal-free guidance. Missing and
       incompatible carry install/update guidance plus a pairing-code entry (which
       also covers replacement-worker pairing). Unavailable keeps projects visible.
    2. `:selection` — the native folder picker (the local worker stand-in in
       dev/test) yields a path validated entirely on the worker boundary through
       `Devices.select_repository/2`. Existing workspace-authorized identities
       are checked before a fresh portable identity is allocated. Only the
       non-reversible identity crosses the boundary; the name and location are
       shown locally.
       Continuing hands off to the shared storage-selection step
       (`specs/05-project-storage-lifecycle/`): a device-origin onboarding attempt
       is created with the selected repository's fingerprint and name, the detected
       worker's readiness is recorded as a bound receipt, and the user chooses
       on-device storage (or signs in to save to a hosted account) before the flow
       returns here at `:review` for the chosen on-device path.
    3. `:review` — the first-connection privacy disclosure. Before any approved
       onboarding metadata leaves the device it explains what stays local, what is
       shared, and the accountless data-loss limit (recoverable only by importing a
       previous export). The user confirms once; later connections are not
       re-prompted but the disclosure stays accessible. Confirming registers the
       project through `Devices.register_project/2` and opens its dashboard.

  Moved or renamed repositories reconnect through `Locate repository`
  (`?locate=<project_id>`): the selected repository is accepted only when its
  canonical fingerprint matches the project's; a non-matching selection is treated
  as a different repository and never replaces the connection.

  The `:device_worker_stub` flag (on in dev/test, off in prod) drives a local
  worker stand-in so pairing and folder selection are exercisable without the
  signed native worker; with it off the page waits on the real (release-gated)
  worker.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus, only: [device_connection_badge: 1]

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{Pairing, WorkerDiscovery}
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectStorage
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt

  # A device-readiness receipt from the detected worker stays valid for this
  # window while the user completes the storage step.
  @readiness_ttl_seconds 15 * 60

  @impl true
  def mount(_params, _session, socket) do
    {:ok, workspace} = Devices.establish_workspace()

    {:ok,
     socket
     |> assign(:page_title, "Work without GitHub")
     |> assign(:workspace, workspace)
     |> assign(:step, :discovery)
     |> assign(:locate_project, nil)
     |> assign(:project_id, nil)
     |> assign(:deep_link_code, nil)
     |> assign(:onboarding_attempt, nil)
     |> assign(:pairing_error, nil)
     |> assign(:selection_error, nil)
     |> assign(:selected, nil)
     |> assign(:project_name, "")
     |> assign(:name_error, nil)
     |> assign(:duplicate, nil)
     |> assign(:disclosure_required, Devices.list_projects() == [])
     |> assign(:disclosure_confirmed, false)
     |> assign_worker_status()}
  end

  @impl true
  def handle_params(%{"locate" => project_id}, _uri, socket) do
    case Devices.get_project(project_id) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:page_title, "Locate repository")
         |> assign(:locate_project, project)
         |> assign(:step, :selection)
         |> assign(:selected, nil)
         |> assign(:selection_error, nil)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # The shared storage step returns here after the user chose on-device storage,
  # carrying the onboarding attempt. Resume at the review step, reconstructing the
  # selected repository from the attempt (only its fingerprint and name persist).
  def handle_params(%{"attempt" => attempt_id}, _uri, socket) do
    case Projects.get_device_onboarding_attempt(socket.assigns.workspace, attempt_id) do
      %{storage_mode: "device", selected_repository: %{"fingerprint" => fingerprint} = repo} =
          attempt ->
        selected = %{name: repo["name"], fingerprint: fingerprint, location: nil}

        {:noreply,
         socket
         |> assign(:onboarding_attempt, attempt)
         |> assign(:selected, selected)
         |> assign(:step, :review)
         |> assign(:project_name, repo["name"] || "")
         |> assign(:name_error, nil)
         |> assign(:duplicate, nil)
         |> assign(:disclosure_confirmed, false)}

      %{storage_mode: "hosted"} ->
        # Hosted storage for accountless local projects is owned by the
        # atomic-registration task; nothing is created here yet.
        {:noreply,
         put_flash(
           socket,
           :info,
           "Saving local projects to a hosted account is coming soon. On-device projects are ready now."
         )}

      _ ->
        # Unknown, cross-device, or not-yet-chosen attempt: stay put.
        {:noreply, socket}
    end
  end

  # Project-scoped device-setup entry point (`specs/36-local-worker-native-distribution`):
  # a project's own dashboard can link in with `?project=<id>` so this generic,
  # project-less onboarding screen can offer the "Open in App" deep link for that
  # project. The project must resolve in the current device workspace; anything
  # else (unknown id, or — defensively — a foreign workspace) is ignored and the
  # screen behaves exactly as it does with no `project` param at all.
  def handle_params(%{"project" => project_id}, _uri, socket) do
    {:noreply, apply_project_param(socket, project_id)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("recheck", _params, socket) do
    {:noreply, socket |> assign(:pairing_error, nil) |> assign_worker_status()}
  end

  # With the local worker stand-in on, entering a pairing code completes the
  # pairing the way the native worker would over its outbound transport, so the
  # graphical flow can be driven end to end. Replacement-worker pairing reuses the
  # same path: pairing again simply authorizes another worker for this workspace.
  def handle_event("pair", %{"pairing" => %{"code" => code}}, socket) do
    cond do
      String.trim(code) == "" ->
        {:noreply,
         assign(socket, :pairing_error, "Enter the pairing code shown in the worker app.")}

      worker_stub?() ->
        case stub_complete_pairing(socket.assigns.workspace.id) do
          :ok ->
            {:noreply, socket |> assign(:pairing_error, nil) |> assign_worker_status()}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :pairing_error, "Pairing couldn't be completed. Try again.")}
        end

      true ->
        # Without the stand-in the dashboard waits for the real worker to connect
        # after the user enters the code in the worker app; re-check its status.
        {:noreply, socket |> assign(:pairing_error, nil) |> assign_worker_status()}
    end
  end

  def handle_event("continue_to_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :selection)
     |> assign(:selection_error, nil)
     |> assign(:duplicate, nil)
     |> assign(:selected, nil)}
  end

  def handle_event("back_to_discovery", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :discovery)
     |> assign(:selection_error, nil)
     |> assign(:duplicate, nil)
     |> assign(:locate_project, nil)
     |> assign_worker_status()}
  end

  # The native folder picker (the stand-in in dev/test) returns a path. Only the
  # fingerprint leaves the boundary; the name and location are shown locally.
  def handle_event("select_folder", _params, socket) do
    if worker_stub?() do
      validate_selection(socket, stub_folder())
    else
      {:noreply,
       assign(socket, :selection_error, "Connect the worker to open the folder picker.")}
    end
  end

  # Hand off to the shared storage-selection step. A device-origin onboarding
  # attempt carries only the selected repository's fingerprint and display name,
  # and the detected worker's readiness is recorded as a bound receipt so
  # on-device storage is available at the step. On-device is the accountless
  # default; the user can also sign in there to save to a hosted account.
  def handle_event("continue_to_storage", _params, socket) do
    selected = socket.assigns.selected
    workspace = socket.assigns.workspace

    with {:ok, attempt} <- Projects.start_device_onboarding_attempt(workspace),
         {:ok, attempt} <-
           Projects.select_local_repository(workspace, attempt.id, %{
             fingerprint: selected.fingerprint,
             name: selected.name
           }),
         {:ok, _attempt} <-
           Projects.record_device_receipt(
             workspace,
             attempt.id,
             readiness_receipt(attempt, workspace)
           ) do
      {:noreply, push_navigate(socket, to: ~p"/onboarding/local/storage/#{attempt.id}")}
    else
      _ ->
        {:noreply,
         assign(socket, :selection_error, "Couldn't continue to the storage step. Try again.")}
    end
  end

  def handle_event("back_to_selection", _params, socket) do
    {:noreply, assign(socket, step: :selection, name_error: nil, duplicate: nil)}
  end

  def handle_event("toggle_disclosure", _params, socket) do
    {:noreply, assign(socket, :disclosure_confirmed, not socket.assigns.disclosure_confirmed)}
  end

  def handle_event("validate_name", %{"project" => %{"name" => name}}, socket) do
    {:noreply, assign(socket, project_name: name, name_error: nil, duplicate: nil)}
  end

  def handle_event("create_project", %{"project" => %{"name" => name}}, socket) do
    create_project(socket, name)
  end

  def handle_event("create_project", _params, socket) do
    create_project(socket, socket.assigns.project_name)
  end

  # ---- selection / creation internals ----

  defp validate_selection(
         %{assigns: %{locate_project: %{} = project, workspace: workspace}} = socket,
         path
       ) do
    case Devices.locate_repository(path, project, workspace) do
      {:ok, %{project: reconnected, upgraded?: upgraded?}} ->
        message =
          if upgraded?,
            do: "Repository reconnected and ready for future project exports.",
            else: "Repository reconnected."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/local/projects/#{reconnected.id}")}

      {:error, {:repository_already_linked, existing}} ->
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:selection_error, nil)
         |> assign(:duplicate, existing)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:duplicate, nil)
         |> assign(:selection_error, locate_message(reason))}
    end
  end

  defp validate_selection(socket, path) do
    case Devices.select_repository(path, socket.assigns.workspace) do
      {:ok, %{fingerprint: fingerprint}} ->
        resolve_selection(socket, %{
          name: Path.basename(path),
          location: path,
          fingerprint: fingerprint
        })

      {:error, {:repository_already_linked, existing}} ->
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:selection_error, nil)
         |> assign(:duplicate, existing)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:duplicate, nil)
         |> assign(:selection_error, selection_message(reason))}
    end
  end

  defp resolve_selection(socket, selected) do
    {:noreply,
     socket
     |> assign(:selection_error, nil)
     |> assign(:duplicate, nil)
     |> assign(:selected, selected)}
  end

  defp create_project(socket, name) do
    attempt = socket.assigns.onboarding_attempt

    cond do
      socket.assigns.disclosure_required and not socket.assigns.disclosure_confirmed ->
        {:noreply,
         assign(socket, :name_error, "Confirm the data notice above before you continue.")}

      is_nil(attempt) or is_nil(socket.assigns.selected) ->
        # Reached without the storage handoff: restart the flow.
        {:noreply, push_navigate(socket, to: ~p"/onboarding/local")}

      true ->
        register_device_project(socket, attempt, name)
    end
  end

  # Commits the on-device project through the attempt-integrated device
  # registration: the device store owns the atomic worker transaction, and the
  # transient control-plane attempt is acknowledged. A committed retry resolves to
  # the same project by the attempt's idempotency key.
  defp register_device_project(socket, attempt, name) do
    opts = [name: name, allocate_suffix?: false]

    case Projects.register_device_project(socket.assigns.workspace, attempt, opts) do
      {:ok, project} ->
        {:noreply, push_navigate(socket, to: ~p"/local/projects/#{project.id}")}

      {:error, {:repository_already_linked, existing}} ->
        {:noreply, assign(socket, :duplicate, existing)}

      {:error, :name_taken} ->
        {:noreply,
         assign(socket, :name_error, "A project already uses this name. Choose another.")}

      {:error, reason} when reason in [:storage_not_ready, :storage_mode_required] ->
        # The device readiness lapsed: send the user back to re-establish it.
        {:noreply, push_navigate(socket, to: ~p"/onboarding/local")}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :name_error, "Enter a project name (letters, numbers, and spaces).")}
    end
  end

  # A bound, minimized readiness receipt from the detected worker: it marks
  # on-device storage ready for this attempt and this device workspace only.
  defp readiness_receipt(attempt, workspace) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    DeviceStorageReceipt.issue(%{
      token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      attempt_id: attempt.id,
      device_workspace_id: workspace.id,
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      issued_at: now,
      expires_at: DateTime.add(now, @readiness_ttl_seconds, :second)
    })
  end

  defp selection_message(:not_a_git_repository),
    do: "That folder isn't a Git repository. Choose a folder that contains a Git repository."

  defp selection_message(:inaccessible),
    do: "That folder couldn't be opened. Check it still exists and try again."

  defp selection_message(:empty_repository),
    do: "That repository has no commits yet. Make your first commit, then select it again."

  defp locate_message(:repository_mismatch),
    do:
      "That's a different repository, so it can't replace this project's repository. Choose the original repository, or start a new project instead."

  defp locate_message(:invalid_repository_identity),
    do:
      "This project's saved repository identity can't be validated. The project is unchanged; create an export before repairing its connection."

  defp locate_message(reason) when reason in [:identity_changed, :identity_race],
    do: "Projects changed while the repository was checked. Nothing was updated; try again."

  defp locate_message(reason), do: selection_message(reason)

  defp assign_worker_status(socket) do
    status = Devices.worker_status(socket.assigns.workspace.id)
    assign(socket, :worker_status, status)
  end

  # ---- project-scoped device setup (`?project=<id>`) ----

  defp apply_project_param(socket, project_id) do
    case Devices.get_project(project_id) do
      {:ok, %{workspace_id: workspace_id} = project}
      when workspace_id == socket.assigns.workspace.id ->
        socket
        |> assign(:project_id, project.id)
        |> maybe_issue_deep_link_code()

      _not_found_or_foreign_workspace ->
        socket
    end
  end

  # The deep link needs a real single-use pairing code to hand the native app, the
  # same code the graphical pairing form itself is built around
  # (`Devices.Pairing.start_pairing/1`, already used by this file's worker
  # stand-in). Issued once per mount and only when the discovery step would
  # actually show the missing/incompatible pairing UI, so visiting with a
  # `project` param never issues an attempt that goes unused.
  defp maybe_issue_deep_link_code(%{assigns: %{deep_link_code: code}} = socket)
       when is_binary(code),
       do: socket

  defp maybe_issue_deep_link_code(%{assigns: %{worker_status: status}} = socket)
       when status in [:missing, :incompatible] do
    case Pairing.start_pairing(socket.assigns.workspace.id) do
      {:ok, %{code: code}} -> assign(socket, :deep_link_code, code)
      {:error, _reason} -> socket
    end
  end

  defp maybe_issue_deep_link_code(socket), do: socket

  defp create_enabled?(assigns) do
    String.trim(assigns.project_name) != "" and
      (not assigns.disclosure_required or assigns.disclosure_confirmed)
  end

  # ---- local worker stand-in (dev/test only) ----

  defp worker_stub?, do: Application.get_env(:sdd_orchestrator, :device_worker_stub, false)

  # Simulates the native worker completing a dashboard-issued pairing and reporting
  # in, so worker discovery resolves to `:detected` without a signed binary.
  defp stub_complete_pairing(workspace_id) do
    with {:ok, %{code: code}} <- Pairing.start_pairing(workspace_id),
         {:ok, %{worker: worker}} <- Pairing.complete_pairing(code, stub_worker_attrs()),
         {:ok, _seen} <- Pairing.mark_seen(worker) do
      :ok
    end
  end

  defp stub_worker_attrs do
    policy = WorkerDiscovery.compatibility_policy()

    %{
      os_family: policy.os_family,
      os_major: List.last(policy.os_majors),
      protocol_version: List.first(policy.protocol_versions),
      app_version: "0.0.0-stub"
    }
  end

  # The stand-in points the folder picker at a real Git repository so validation
  # runs for real. Tests override this to exercise the invalid/moved/non-matching
  # branches; dev falls back to the working copy, which is itself a Git repo.
  defp stub_folder do
    Application.get_env(:sdd_orchestrator, :device_worker_stub_folder) || File.cwd!()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell brand={false} max_width="max-w-xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/"}>
          <.lucide name="arrow-left" class="size-4" /> Back to sign in
        </.button>
      </:actions>

      <div data-screen="local-onboarding">
        <.discovery_step
          :if={@step == :discovery}
          worker_status={@worker_status}
          pairing_error={@pairing_error}
          project_id={@project_id}
          deep_link_code={@deep_link_code}
        />
        <.selection_step
          :if={@step == :selection}
          selected={@selected}
          selection_error={@selection_error}
          duplicate={@duplicate}
          locate_project={@locate_project}
        />
        <.review_step
          :if={@step == :review}
          selected={@selected}
          project_name={@project_name}
          name_error={@name_error}
          duplicate={@duplicate}
          disclosure_required={@disclosure_required}
          disclosure_confirmed={@disclosure_confirmed}
          create_enabled={create_enabled?(assigns)}
        />
      </div>
    </.app_shell>
    """
  end

  # ---- worker discovery step (with storage-mode explanation) ----

  attr :worker_status, :atom, required: true
  attr :pairing_error, :string, default: nil
  attr :project_id, :string, default: nil
  attr :deep_link_code, :string, default: nil

  defp discovery_step(assigns) do
    ~H"""
    <div data-step="discovery">
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="hard-drive" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">
            Connect a repository on this computer
          </h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            SDD Orchestrator reaches your local repository through a small worker app that runs on
            this Mac. Nothing about your code or its location leaves your computer.
          </p>
        </div>
      </header>

      <.storage_explanation />

      <div class="mt-6" data-worker-status={@worker_status}>
        <.worker_missing
          :if={@worker_status == :missing}
          pairing_error={@pairing_error}
          project_id={@project_id}
          deep_link_code={@deep_link_code}
        />
        <.worker_incompatible
          :if={@worker_status == :incompatible}
          pairing_error={@pairing_error}
          project_id={@project_id}
          deep_link_code={@deep_link_code}
        />
        <.worker_unavailable :if={@worker_status == :unavailable} />
        <.worker_detected :if={@worker_status == :detected} />
      </div>
    </div>
    """
  end

  # Explains the two project-data storage modes before onboarding continues. This
  # slice implements only "On this device"; hosted storage needs an account and is
  # owned by other slices, so it links out rather than being selectable here.
  defp storage_explanation(assigns) do
    ~H"""
    <section
      class="mt-6 rounded-lg border border-line bg-surface p-4"
      data-storage-explanation
      aria-label="Where your project work is saved"
    >
      <h2 class="text-[13px] font-semibold text-ink">Where your project work is saved</h2>
      <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
        Your specifications and project work are stored separately from your code. You have two
        options:
      </p>
      <ul class="mt-3 flex flex-col gap-2.5">
        <li class="flex gap-2.5">
          <.lucide name="hard-drive" class="size-4 flex-none mt-0.5 text-primary" />
          <span class="text-[13px] text-ink">
            <span class="font-semibold">{ProjectStorage.label(:device)}</span>
            — used by this accountless path. Your project stays on this computer and there's no
            account to sign in to.
          </span>
        </li>
        <li class="flex gap-2.5">
          <.lucide name="cloud" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span class="text-[13px] text-ink-muted">
            <span class="font-semibold">{ProjectStorage.label(:hosted)}</span>
            — available from any device you sign in on.
            <.link
              navigate={~p"/hosted/access?#{[return_to: "/onboarding/local"]}"}
              class="font-semibold text-primary underline underline-offset-2"
            >
              Use a verified email
            </.link>
            to set that up instead.
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :pairing_error, :string, default: nil
  attr :project_id, :string, default: nil
  attr :deep_link_code, :string, default: nil

  defp worker_missing(assigns) do
    ~H"""
    <div data-state="missing">
      <.notice variant="info" icon="download">
        No worker is set up on this Mac yet. Install the worker app, then pair it with the code it
        shows — no Terminal needed.
      </.notice>

      <ol class="mt-5 flex flex-col gap-4">
        <li class="flex gap-3">
          <span class="flex-none w-6 h-6 rounded-full bg-primary text-on-primary text-xs font-bold flex items-center justify-center">
            1
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-sm font-semibold text-ink">Download the worker for macOS</p>
            <p class="mt-0.5 text-[13px] leading-relaxed text-ink-muted">
              A signed app you install by dragging it to Applications. Supports macOS 25 and 26.
            </p>
            <.button
              variant="secondary"
              size="sm"
              href="/downloads/worker"
              class="mt-2 w-full sm:w-auto"
            >
              <.lucide name="download" class="size-4" /> Download worker app
            </.button>
          </div>
        </li>
        <li class="flex gap-3">
          <span class="flex-none w-6 h-6 rounded-full bg-primary text-on-primary text-xs font-bold flex items-center justify-center">
            2
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-sm font-semibold text-ink">Open it and enter the pairing code</p>
            <p class="mt-0.5 text-[13px] leading-relaxed text-ink-muted">
              The worker shows a pairing code the first time you open it. Enter it below to link this
              device — the pairing is single-use and stays on this Mac.
            </p>
          </div>
        </li>
      </ol>

      <.pairing_form
        pairing_error={@pairing_error}
        label="Pair worker"
        project_id={@project_id}
        deep_link_code={@deep_link_code}
      />
    </div>
    """
  end

  attr :pairing_error, :string, default: nil
  attr :project_id, :string, default: nil
  attr :deep_link_code, :string, default: nil

  defp worker_incompatible(assigns) do
    ~H"""
    <div data-state="incompatible">
      <.notice variant="warn" icon="triangle-alert">
        The worker on this Mac is too old for this version of SDD Orchestrator. Update it, or
        reinstall the current worker, then pair the replacement.
      </.notice>

      <ul class="mt-5 flex flex-col gap-3 text-sm text-ink-muted">
        <li class="flex gap-2">
          <.lucide name="refresh-cw" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span>Open the worker app and let it update, or download the current worker below.</span>
        </li>
        <li class="flex gap-2">
          <.lucide name="shield" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span>Pair the replacement with its new code. Your projects stay where they are.</span>
        </li>
      </ul>

      <.button variant="secondary" size="sm" href="/downloads/worker" class="mt-4 w-full sm:w-auto">
        <.lucide name="download" class="size-4" /> Download the current worker
      </.button>

      <.pairing_form
        pairing_error={@pairing_error}
        label="Pair replacement worker"
        project_id={@project_id}
        deep_link_code={@deep_link_code}
      />
    </div>
    """
  end

  defp worker_unavailable(assigns) do
    ~H"""
    <div data-state="unavailable">
      <.notice variant="warn" icon="unplug">
        Your worker is paired but not running right now, so this Mac can't reach your repositories.
        Your projects are safe and still listed — they just show an unavailable connection until the
        worker is back.
      </.notice>

      <ul class="mt-5 flex flex-col gap-3 text-sm text-ink-muted">
        <li class="flex gap-2">
          <.lucide name="play" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span>Open the worker app from Applications so it can reconnect.</span>
        </li>
        <li class="flex gap-2">
          <.lucide name="wifi" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span>Once it's running, check again to continue.</span>
        </li>
      </ul>

      <div class="mt-5">
        <.button phx-click="recheck" data-recheck class="w-full sm:w-auto">
          <.lucide name="refresh-cw" class="size-4" /> Check again
        </.button>
      </div>
    </div>
    """
  end

  defp worker_detected(assigns) do
    ~H"""
    <div data-state="detected">
      <div class="flex items-center gap-2">
        <.device_connection_badge status="connected" />
        <span class="text-sm text-ink-muted">Worker connected on this Mac.</span>
      </div>

      <.notice variant="info" icon="folder" class="mt-4">
        You're ready to choose the repository on this computer you want to work on.
      </.notice>

      <div class="mt-5">
        <.button phx-click="continue_to_selection" data-continue class="w-full sm:w-auto">
          Choose repository <.lucide name="arrow-right" class="size-4" />
        </.button>
      </div>
    </div>
    """
  end

  attr :pairing_error, :string, default: nil
  attr :label, :string, required: true
  attr :project_id, :string, default: nil
  attr :deep_link_code, :string, default: nil

  defp pairing_form(assigns) do
    ~H"""
    <form id="pairing-form" phx-submit="pair" class="mt-5" data-pairing-form>
      <.text_field
        id="pairing-code"
        name="pairing[code]"
        label="Pairing code"
        error={@pairing_error}
        placeholder="For example, 4K7Q-2P9X"
        autocomplete="off"
      />
      <div class="mt-3 flex flex-col gap-2.5 sm:flex-row sm:items-center">
        <.button type="submit" data-pair class="w-full sm:w-auto">
          <.lucide name="link" class="size-4" /> {@label}
        </.button>
        <%!--
          A plain anchor, not `.button`/`phx-click`: it must be a real link so the
          browser hands the custom `sddworker://` scheme off to the OS instead of
          LiveView intercepting the click. A machine with no installed app simply
          gets no response from the OS here — the download button above (AC-06's
          install guidance) is what covers that case, not this link.
        --%>
        <a
          :if={@project_id && @deep_link_code}
          href={deep_link_href(@project_id, @deep_link_code)}
          data-open-in-app
          class="inline-flex h-8 w-full items-center justify-center gap-2 rounded-lg border border-line-strong bg-surface px-3 text-[13px] font-semibold text-ink transition hover:bg-raised sm:w-auto"
        >
          <.lucide name="external-link" class="size-4" /> Open in App
        </a>
      </div>
    </form>
    """
  end

  defp deep_link_href(project_id, code) do
    "sddworker://pair?code=#{URI.encode_www_form(code)}&project_id=#{URI.encode_www_form(project_id)}"
  end

  # ---- repository selection step ----

  attr :selected, :map, default: nil
  attr :selection_error, :string, default: nil
  attr :duplicate, :map, default: nil
  attr :locate_project, :map, default: nil

  defp selection_step(assigns) do
    ~H"""
    <div data-step="selection" data-locate={@locate_project && "true"}>
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="folder-git-2" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">
            {(@locate_project && "Locate this repository") || "Choose your repository"}
          </h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            <%= if @locate_project do %>
              Pick where <span class="font-semibold text-ink">{@locate_project.name}</span>'s
              repository lives now. Only the same repository can reconnect — a different one is kept
              separate.
            <% else %>
              The worker opens your Mac's folder picker. We check the folder is a Git repository right
              here on your computer — its path, history, and code never leave this Mac.
            <% end %>
          </p>
        </div>
      </header>

      <div class="mt-6">
        <.button phx-click="select_folder" data-select-folder class="w-full sm:w-auto">
          <.lucide name="folder-open" class="size-4" /> Open folder picker
        </.button>
      </div>

      <div :if={@selection_error} class="mt-5" data-selection-error>
        <.notice variant="err" icon="triangle-alert">{@selection_error}</.notice>
      </div>

      <div :if={@duplicate} class="mt-5" data-duplicate>
        <.notice variant="warn" icon="triangle-alert">
          <div class="flex flex-col gap-2">
            <span>
              This repository is already connected as <span class="font-semibold">{@duplicate.name}</span>. Its existing project was preserved.
            </span>
            <.button
              variant="secondary"
              size="sm"
              navigate={~p"/local/projects/#{@duplicate.id}"}
              class="w-full sm:w-auto"
            >
              Open {@duplicate.name} <.lucide name="arrow-right" class="size-4" />
            </.button>
          </div>
        </.notice>
      </div>

      <div
        :if={@selected}
        class="mt-5 rounded-lg border border-line bg-surface p-4"
        data-selected-repository
      >
        <div class="flex items-center gap-2">
          <.device_connection_badge status="connected" />
          <span class="text-sm font-semibold text-ink" data-repository-name>{@selected.name}</span>
        </div>
        <p class="mt-1.5 text-[13px] text-ink-muted break-all" data-repository-location>
          {@selected.location}
        </p>

        <.button
          :if={!@locate_project}
          phx-click="continue_to_storage"
          data-continue-storage
          class="mt-4 w-full sm:w-auto"
        >
          Continue <.lucide name="arrow-right" class="size-4" />
        </.button>
      </div>

      <div class="mt-6">
        <.button variant="secondary" size="sm" phx-click="back_to_discovery">
          <.lucide name="arrow-left" class="size-4" /> Back
        </.button>
      </div>
    </div>
    """
  end

  # ---- review + first-connection disclosure + create step ----

  attr :selected, :map, default: nil
  attr :project_name, :string, required: true
  attr :name_error, :string, default: nil
  attr :duplicate, :map, default: nil
  attr :disclosure_required, :boolean, required: true
  attr :disclosure_confirmed, :boolean, required: true
  attr :create_enabled, :boolean, required: true

  defp review_step(assigns) do
    ~H"""
    <div data-step="review">
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="shield" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">Before you connect</h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            Here's exactly what happens when you connect <span
              :if={@selected}
              class="font-semibold text-ink"
            >{@selected.name}</span>.
          </p>
        </div>
      </header>

      <.disclosure_body :if={@disclosure_required} data-disclosure />

      <details :if={!@disclosure_required} class="mt-6 rounded-lg border border-line bg-surface p-4">
        <summary class="cursor-pointer text-sm font-semibold text-ink" data-disclosure-summary>
          What stays on this device and what's shared
        </summary>
        <div class="mt-3">
          <.disclosure_body data-disclosure />
        </div>
      </details>

      <form
        id="create-project-form"
        phx-change="validate_name"
        phx-submit="create_project"
        class="mt-6"
      >
        <.text_field
          id="project-name"
          name="project[name]"
          label="Project name"
          value={@project_name}
          error={@name_error}
          hint="Defaults to the repository folder name. You can use spaces and any language."
          autocomplete="off"
          phx-debounce="150"
        />

        <label
          :if={@disclosure_required}
          class="mt-4 flex items-start gap-2.5 text-[13px] text-ink"
          data-confirm-label
        >
          <input
            type="checkbox"
            name="confirm"
            checked={@disclosure_confirmed}
            phx-click="toggle_disclosure"
            data-confirm-disclosure
            class="mt-0.5 size-4 flex-none rounded border-line-strong"
          />
          <span>
            I understand what stays on this device, what is shared, and that project history can't be
            recovered without a previous export.
          </span>
        </label>

        <div
          :if={@duplicate}
          class="mt-4"
          data-duplicate
        >
          <.notice variant="warn" icon="triangle-alert">
            <div class="flex flex-col gap-2">
              <span>
                This repository is already connected as <span class="font-semibold">{@duplicate.name}</span>. One repository can only be one
                project.
              </span>
              <.button
                variant="secondary"
                size="sm"
                navigate={~p"/local/projects/#{@duplicate.id}"}
                class="w-full sm:w-auto"
              >
                Open {@duplicate.name} <.lucide name="arrow-right" class="size-4" />
              </.button>
            </div>
          </.notice>
        </div>

        <div class="mt-6 flex flex-col gap-2.5 sm:flex-row sm:items-center">
          <.button type="submit" disabled={!@create_enabled} data-create class="w-full sm:w-auto">
            <.lucide name="circle-check" class="size-4" /> Connect and create project
          </.button>
          <.button
            type="button"
            variant="secondary"
            phx-click="back_to_selection"
            class="w-full sm:w-auto"
          >
            <.lucide name="arrow-left" class="size-4" /> Back
          </.button>
        </div>
      </form>
    </div>
    """
  end

  attr :rest, :global

  defp disclosure_body(assigns) do
    ~H"""
    <div class="mt-6 flex flex-col gap-3" {@rest}>
      <.notice variant="neutral" icon="hard-drive">
        <p class="font-semibold text-ink">Stays on this Mac</p>
        <p class="mt-0.5">
          Your repository's location, files, folder and file names, Git history, remote URLs, and
          source code never leave this computer.
        </p>
      </.notice>

      <.notice variant="info" icon="external-link">
        <p class="font-semibold text-ink">What's shared</p>
        <p class="mt-0.5">
          Only the minimum needed to keep the connection: a versioned scrambled repository
          identifier that can't be reversed, coarse worker and app version info, and the connection
          status. An independent connection gets a different identifier; the exact identifier is
          copied only when you explicitly export and restore this same project. Never a path, file
          name, URL, or any of your code.
        </p>
      </.notice>

      <.notice variant="warn" icon="triangle-alert">
        <p class="font-semibold">This project has no account</p>
        <p class="mt-0.5">
          It lives only on this Mac. If this device's data is lost, its project history can't be
          recovered by reconnecting the repository — that would start fresh history. Recovery is only
          possible by importing a project export you made earlier (project portability).
        </p>
      </.notice>
    </div>
    """
  end
end
