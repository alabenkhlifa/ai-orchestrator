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
       also covers replacement-worker pairing). Unavailable keeps projects visible
       and offers `Pair again`, which reveals that same pairing entry and its
       deep link, so a person whose worker record is stale still has a way
       forward. Pairing again authorizes another worker for this workspace and
       keeps the old record.

       The waiting state is session state, not a reading of the status. It says a
       code was accepted, so it appears only after this session accepted one
       (`code_accepted?`). Any other not-detected status renders its own state
       instead, because the control plane knows nothing about a code that was
       never entered.
    2. `:selection` — the folder question is asked of the Mac's attached worker
       and answered by a person (specs/40 Task 7). The worker opens its own
       native picker, runs the Git check there, compares the folder against the
       identities this workspace already holds, and answers with verdicts only:
       which candidates matched, the folder's own name, and a fresh portable
       identity. No path reaches this screen, so none can be rendered or stored.
       A non-empty match list is the duplicate outcome
       `Devices.select_repository/2` used to compute here from a path.
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
  (`?locate=<project_id>`): the selected repository is accepted only when the
  worker reports that the folder matches the project's own identity; a
  non-matching selection is treated as a different repository and never replaces
  the connection. A project still carrying a legacy identity is upgraded on the
  same answer, because the other projects rode along as candidates and the
  worker generated the replacement.

  Both modes share one waiting state with `Cancel` and one no-answer state with
  `Try again`, the states `ProjectDashboardLive` renders for the same facts. The
  request is bound to this LiveView process, so leaving the page closes the
  panel on the Mac.

  The folder-picker stand-in is no longer a flag inside this screen. It is the
  `RepositorySelection` transport chosen by configuration, present only in tests
  and under `E2E_MODE`. The `:device_worker_stub` flag that remains here drives
  the pairing stand-in alone.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus, only: [device_connection_badge: 1]

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{Pairing, PairingGuidance, PortableRepositoryIdentity}
  alias SddOrchestrator.Devices.WorkerDiscovery
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectStorage
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.SelectionResult
  alias SddOrchestratorWeb.RepositoryAssessmentLive

  # A device-readiness receipt from the detected worker stays valid for this
  # window while the user completes the storage step.
  @readiness_ttl_seconds 15 * 60

  # How often the screen re-checks while a bound code waits for its app to finish.
  @worker_poll_ms 2_000

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
     |> assign(:code_accepted?, false)
     |> assign(:pair_again?, false)
     |> assign(:selection_error, nil)
     |> assign(:selected, nil)
     |> assign(:proving_worker_id, nil)
     |> assign(:project_name, "")
     |> assign(:name_error, nil)
     |> assign(:duplicate, nil)
     |> assign(:disclosure_required, Devices.list_projects() == [])
     |> assign(:disclosure_confirmed, false)
     |> reset_selection()
     |> assign_worker_status()
     |> assign_awaiting_worker()}
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
         |> assign(:selection_error, nil)
         |> reset_selection()}

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
        selected = %{name: repo["name"], fingerprint: fingerprint}

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

  # Re-reads the worker and reports what the control plane knows at that moment.
  # It never invents the waiting state: that state says a code was accepted, and
  # only this session's own accepted code can make it true.
  @impl true
  def handle_event("recheck", _params, socket) do
    {:noreply,
     socket
     |> assign(:pairing_error, nil)
     |> assign_worker_status()
     |> assign_awaiting_worker()}
  end

  # An unavailable worker is a paired record with nothing attached, which is also
  # what a worker that was reinstalled or removed looks like. Pairing again is the
  # ordinary pairing flow: it authorizes another worker for this same workspace
  # and keeps the old record, so nothing here changes pairing itself.
  def handle_event("pair_again", _params, socket) do
    {:noreply,
     socket
     |> assign(:pair_again?, true)
     |> assign(:pairing_error, nil)
     |> maybe_issue_deep_link_code()}
  end

  # The submitted code is redeemed for real (`specs/38`): redemption is the moment
  # an attempt the worker app obtained for itself stops being inert, binding to
  # this browser's own device workspace and authorizing one worker. Replacement
  # pairing reuses the same path, since pairing again simply authorizes another
  # worker for this workspace.
  #
  # Redemption is attempted first and always. The local worker stand-in only
  # catches what redemption refused, and only where the stand-in is enabled at
  # all: development and the browser suite, where there is no native app to hand
  # out a code and the flow still has to be drivable end to end. A real code
  # therefore behaves identically in development and in production, and the
  # stand-in can no longer hide a redemption that genuinely failed.
  def handle_event("pair", %{"pairing" => %{"code" => code}}, socket) do
    trimmed = String.trim(code)

    if trimmed == "" do
      {:noreply,
       assign(socket, :pairing_error, "Enter the pairing code shown in the worker app.")}
    else
      {:noreply, complete_pairing(socket, trimmed)}
    end
  end

  def handle_event("continue_to_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :selection)
     |> clear_selection_feedback()
     |> reset_selection()}
  end

  def handle_event("back_to_discovery", _params, socket) do
    cancel_open_request(socket)

    {:noreply,
     socket
     |> assign(:step, :discovery)
     |> clear_selection_feedback()
     |> reset_selection()
     |> assign(:locate_project, nil)
     |> assign_worker_status()}
  end

  # The folder is on this Mac and this node is not, so the question goes to the
  # worker and the screen waits. The answer arrives as one
  # `{:repository_selection, request_id, outcome}` message, and only then does
  # anything change.
  def handle_event("select_folder", _params, socket) do
    {:noreply, request_selection(socket)}
  end

  # The request server tells the worker to close its panel and then sends this
  # process `:cancelled`, so the screen returns to the picker through the one
  # handler every outcome goes through.
  def handle_event("cancel_selection", _params, socket) do
    cancel_open_request(socket)
    {:noreply, socket}
  end

  # Hand off to the shared storage-selection step. A device-origin onboarding
  # attempt carries the selected repository's fingerprint and display name, plus
  # the worker that proved it, because hosted storage binds the project to that
  # worker. The detected worker's readiness is recorded as a bound receipt so
  # on-device storage is available at the step. On-device is the accountless
  # default; the user can also sign in there to save to a hosted account.
  def handle_event("continue_to_storage", _params, socket) do
    selected = socket.assigns.selected
    workspace = socket.assigns.workspace

    with {:ok, attempt} <- Projects.start_device_onboarding_attempt(workspace),
         {:ok, attempt} <-
           Projects.select_local_repository(workspace, attempt.id, %{
             fingerprint: selected.fingerprint,
             name: selected.name,
             worker_id: socket.assigns.proving_worker_id
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

  @impl true
  def handle_info(:check_worker, socket) do
    socket = socket |> assign_worker_status() |> assign_awaiting_worker()

    if socket.assigns.awaiting_worker do
      {:noreply, schedule_worker_check(socket)}
    else
      # The worker arrived, or the person moved on. Either way stop polling
      # rather than run a timer forever.
      {:noreply, socket}
    end
  end

  # Exactly one outcome arrives per request. An outcome naming a request this
  # screen is not waiting on belongs to a request it already finished or
  # cancelled, so it changes nothing.
  def handle_info({:repository_selection, request_id, outcome}, socket) do
    if request_id == socket.assigns.selection_request_id do
      {:noreply, selection_outcome(socket, outcome)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ---- asking the worker ----

  # An unavailable worker gets the refusal, not a request: nobody should be sent
  # looking for a folder no worker is there to check.
  defp request_selection(socket) do
    workspace = socket.assigns.workspace
    socket = socket |> clear_selection_feedback() |> reset_selection()

    with {:ok, plan} <- selection_plan(socket),
         {:ok, worker_id} <- available_worker(workspace.id),
         {:ok, request_id} <-
           RepositorySelection.request(%{device_workspace_id: workspace.id}, worker_id,
             candidates: plan.candidates,
             generate: plan.generate?
           ) do
      socket
      |> assign(:picker_step, :waiting)
      |> assign(:selection_request_id, request_id)
      |> assign(:selection_projects, plan.projects)
      # The worker that is about to prove this repository. A hosted project is
      # bound to it, so it has to outlive the request it answers.
      |> assign(:proving_worker_id, worker_id)
    else
      {:error, reason} -> assign(socket, :selection_error, refusal_message(socket, reason))
    end
  end

  # Selection mode. Every project this workspace holds rides along as a
  # candidate and a new project needs a fresh identity, which reproduces exactly
  # what `Devices.select_repository/2` did from a path: its
  # `ensure_repository_unlinked` is the worker's match list, and its
  # `PortableRepositoryIdentity.generate/1` is the worker's `generate`. Task 10
  # made the worker's comparison identical to `Devices.matches_repository?/3`,
  # legacy identities included, so the duplicate rule is preserved rather than
  # weakened.
  defp selection_plan(%{assigns: %{locate_project: nil}}) do
    {:ok, plan(Devices.list_projects(), true)}
  end

  # Locate mode. A portable identity only has to be recognised, so it travels
  # alone and no identity is generated. A legacy one is upgraded on this same
  # answer, so it needs both halves of the upgrade: every other project rides
  # along, because that is the `ensure_repository_unlinked` recheck the upgrade
  # performs, and `generate: true` produces the replacement identity.
  defp selection_plan(%{assigns: %{locate_project: project}}) do
    case PortableRepositoryIdentity.parse(project.repository_fingerprint) do
      {:ok, _portable} ->
        {:ok, plan([project], false)}

      {:error, :legacy_identifier} ->
        others = Enum.reject(Devices.list_projects(), &(&1.id == project.id))
        {:ok, plan([project | others], true)}

      # An identity no worker could compare is refused before a panel opens.
      {:error, :invalid_identifier} ->
        {:error, :invalid_repository_identity}
    end
  end

  # A project is its own reference, so the worker's `matches` name projects
  # directly. A record with no usable identity is left out of the request rather
  # than sent as a candidate that could never match.
  defp plan(projects, generate?) do
    compared = Enum.filter(projects, &is_binary(&1.repository_fingerprint))

    %{
      projects: Map.new(compared, &{&1.id, &1}),
      candidates: Enum.map(compared, &%{ref: &1.id, identity: &1.repository_fingerprint}),
      generate?: generate?
    }
  end

  # Only a worker attached right now may be asked to open a picker, and this
  # reads availability the way the rest of the screen does: through
  # `WorkerDiscovery.status/2`, whose `:detected` is `Devices.worker_available?/1`
  # plus compatibility and staleness. Reading anything else here would let the
  # screen say the worker is connected and then refuse the click.
  defp available_worker(workspace_id) do
    workspace_id
    |> Pairing.active_workers()
    |> Enum.find(&(WorkerDiscovery.status([&1]) == :detected))
    |> case do
      nil -> {:error, :worker_unavailable}
      worker -> {:ok, worker.id}
    end
  end

  defp cancel_open_request(socket) do
    case socket.assigns.selection_request_id do
      request_id when is_binary(request_id) -> RepositorySelection.cancel(request_id)
      _nothing_open -> :ok
    end
  end

  # ---- what the worker answered ----

  defp selection_outcome(socket, {:selected, %SelectionResult{} = result}) do
    compared = socket.assigns.selection_projects
    socket = reset_selection(socket)

    case socket.assigns.locate_project do
      nil -> selected_repository(socket, compared, result)
      project -> located_repository(socket, project, compared, result)
    end
  end

  # The person dismissed the panel, or left this step. Nothing was chosen, so
  # the screen simply offers the picker again.
  defp selection_outcome(socket, :cancelled), do: reset_selection(socket)

  defp selection_outcome(socket, {:refused, reason}) do
    socket
    |> reset_selection()
    |> assign(:selected, nil)
    |> assign(:duplicate, nil)
    |> assign(:selection_error, refusal_message(socket, reason))
  end

  # A timeout and a lost attachment are one fact to the person: nothing came
  # back. The screen says only that, and offers the action that can change it.
  defp selection_outcome(socket, no_answer) when no_answer in [:timeout, :worker_lost] do
    socket |> reset_selection() |> assign(:picker_step, :no_answer)
  end

  defp selected_repository(socket, compared, %SelectionResult{} = result) do
    case matched_projects(compared, result.matches) do
      [existing | _rest] -> duplicate_repository(socket, existing)
      [] -> new_repository(socket, result)
    end
  end

  defp new_repository(socket, %SelectionResult{identity: identity, folder_name: name})
       when is_binary(identity) and is_binary(name) do
    socket
    |> assign(:selection_error, nil)
    |> assign(:duplicate, nil)
    |> assign(:selected, %{name: name, fingerprint: identity})
  end

  # A `generate: true` request answered without an identity or a folder name is
  # an answer this screen cannot use. It is reported as a failed check rather
  # than turned into a project with no identity.
  defp new_repository(socket, _result),
    do: assign(socket, :selection_error, selection_message(:incomplete_answer))

  defp located_repository(socket, project, compared, %SelectionResult{} = result) do
    matched = matched_projects(compared, result.matches)

    cond do
      not Enum.any?(matched, &(&1.id == project.id)) ->
        locate_error(socket, :repository_mismatch)

      match?({:ok, _portable}, PortableRepositoryIdentity.parse(project.repository_fingerprint)) ->
        reconnected(socket, project, false)

      true ->
        upgrade_legacy_repository(socket, project, compared, matched, result)
    end
  end

  # Locating a legacy identity does more than reconnect. It replaces the stored
  # value with a fresh portable one, after rechecking that no other project
  # matches the same repository, and reports that upgrade to the person. Both
  # halves came back in this one answer: the other projects rode along as
  # candidates, so the match list is that recheck, and `generate: true` produced
  # the replacement.
  defp upgrade_legacy_repository(socket, project, compared, matched, %SelectionResult{
         identity: identity
       })
       when is_binary(identity) do
    case Enum.find(matched, &(&1.id != project.id)) do
      nil -> replace_legacy_identity(socket, project, compared, identity)
      other -> duplicate_repository(socket, other)
    end
  end

  defp upgrade_legacy_repository(socket, _project, _compared, _matched, _result),
    do: locate_error(socket, :incomplete_answer)

  # The atomic replacement is not reimplemented here. `Devices` still owns it,
  # and it still runs against the exact set of identities the comparison used,
  # so a project or an identity that changed while the panel was open reports
  # `:identity_race` and leaves this project alone.
  defp replace_legacy_identity(socket, project, compared, identity) do
    snapshot =
      compared
      |> Map.delete(project.id)
      |> Map.new(fn {id, other} -> {id, other.repository_fingerprint} end)

    case Devices.upgrade_located_repository_identity(project, identity, snapshot) do
      {:ok, upgraded} -> reconnected(socket, upgraded, true)
      {:error, {:repository_already_linked, existing}} -> duplicate_repository(socket, existing)
      {:error, reason} -> locate_error(socket, reason)
    end
  end

  defp reconnected(socket, project, upgraded?) do
    message =
      if upgraded?,
        do: "Repository reconnected and ready for future project exports.",
        else: "Repository reconnected."

    socket
    |> put_flash(:info, message)
    |> push_navigate(to: ~p"/local/projects/#{project.id}")
  end

  defp duplicate_repository(socket, existing) do
    socket
    |> assign(:selected, nil)
    |> assign(:selection_error, nil)
    |> assign(:duplicate, existing)
  end

  defp locate_error(socket, reason) do
    socket
    |> assign(:selected, nil)
    |> assign(:duplicate, nil)
    |> assign(:selection_error, locate_message(reason))
  end

  # A reference crosses the wire as a string, so a real answer names a project by
  # its own id. A reference this screen did not send names nothing.
  defp matched_projects(compared, matches) do
    matches
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Map.get(compared, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp refusal_message(%{assigns: %{locate_project: %{}}}, reason), do: locate_message(reason)
  defp refusal_message(_socket, reason), do: selection_message(reason)

  defp clear_selection_feedback(socket) do
    socket
    |> assign(:selection_error, nil)
    |> assign(:duplicate, nil)
    |> assign(:selected, nil)
    |> assign(:proving_worker_id, nil)
  end

  defp reset_selection(socket) do
    socket
    |> assign(:picker_step, nil)
    |> assign(:selection_request_id, nil)
    |> assign(:selection_projects, %{})
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

  # The one owned wording for no worker being attached, read from its owner, so
  # the refusal and the discovery state cannot drift apart.
  defp selection_message(reason) when reason in [:worker_unavailable, :no_worker],
    do: RepositoryAssessmentLive.worker_unavailable_message()

  defp selection_message(:worker_needs_update),
    do:
      "The worker app on this Mac is too old to open a folder picker. Update it, then try again."

  defp selection_message(_reason),
    do: "The worker couldn't answer the folder request. Try again."

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

  # The one derivation of the waiting state, so every caller reads the same rule.
  # Waiting means a code this session accepted has not produced a worker yet. A
  # status alone can never make it true, because the control plane cannot know
  # about a code the person never entered.
  defp assign_awaiting_worker(socket) do
    awaiting? = socket.assigns.code_accepted? and socket.assigns.worker_status != :detected
    assign(socket, :awaiting_worker, awaiting?)
  end

  # The one rule for the pairing entry being on screen, so the deep-link code is
  # minted exactly where the form that carries it renders: this workspace has no
  # usable worker, or the person asked to pair again from the unavailable state.
  defp pairing_offered?(assigns) do
    assigns.worker_status in [:missing, :incompatible] or
      (assigns.pair_again? and assigns.worker_status == :unavailable)
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
  # stand-in). Issued once per session, and only when the screen actually shows
  # the pairing entry the link sits in, so no attempt is created that goes unused.
  # `Pair again` reaches the same issuance rather than repeating it.
  defp maybe_issue_deep_link_code(%{assigns: %{project_id: nil}} = socket), do: socket

  defp maybe_issue_deep_link_code(%{assigns: %{deep_link_code: code}} = socket)
       when is_binary(code),
       do: socket

  defp maybe_issue_deep_link_code(socket) do
    if pairing_offered?(socket.assigns) do
      case Pairing.start_pairing(socket.assigns.workspace.id) do
        {:ok, %{code: code}} -> assign(socket, :deep_link_code, code)
        {:error, _reason} -> socket
      end
    else
      socket
    end
  end

  defp create_enabled?(assigns) do
    String.trim(assigns.project_name) != "" and
      (not assigns.disclosure_required or assigns.disclosure_confirmed)
  end

  # The waiting sentence is one wording with one variable part: which repository
  # the person is being asked to point at.
  defp picker_target(nil), do: "your repository"
  defp picker_target(_locate_project), do: "this project's repository"

  # ---- pairing stand-in (dev/test only) ----

  # `:device_worker_stub` now drives pairing alone. The folder picker used to
  # read the same flag here; it is answered by the `RepositorySelection`
  # transport instead, so this name says which stand-in is left.
  defp pairing_stub?, do: Application.get_env(:sdd_orchestrator, :device_worker_stub, false)

  # Simulates the native worker completing a dashboard-issued pairing and reporting
  # in, so worker discovery resolves to `:detected` without a signed binary.
  # One safe answer for every refused code. Expired, already used, belonging to
  # another workspace, malformed, and never issued are indistinguishable here
  # because `redeem_pairing/3` already makes them indistinguishable, and saying
  # more would undo that.
  @refused_pairing "That code didn't work. Get a new one from the worker app and try again."

  defp complete_pairing(socket, code) do
    case Pairing.bind_pairing(code, socket.assigns.workspace.id) do
      :ok ->
        # The one moment a code is accepted in this session, and the only thing
        # that entitles the screen to say so.
        socket
        |> assign(:pairing_error, nil)
        |> assign(:code_accepted?, true)
        |> await_worker()

      {:error, :invalid_code} ->
        refused(socket)
    end
  end

  # Where the local worker stand-in is configured, a code that did not bind still
  # drives the flow, because there is no app to issue a real one and the other
  # slices' browser scenarios type a placeholder. The stand-in exists only in
  # development and the browser suite, never in a production build, so this
  # cannot soften a refusal a real person would see.
  defp refused(socket) do
    if pairing_stub?() and stub_complete_pairing(socket.assigns.workspace.id) == :ok do
      socket |> assign(:pairing_error, nil) |> assign_worker_status()
    else
      assign(socket, :pairing_error, @refused_pairing)
    end
  end

  # The code is bound, so the worker is authorized to finish. It does that for
  # itself against `POST /worker_pairings`, reporting versions only it knows, so
  # the screen waits rather than showing a worker it cannot yet describe.
  #
  # Where the local worker stand-in is configured — development and the browser
  # suite, never a production build — it plays the app's part and finishes
  # immediately, so the flow stays drivable with no native app installed.
  defp await_worker(socket) do
    if pairing_stub?() do
      stub_complete_pairing(socket.assigns.workspace.id)
    end

    socket = socket |> assign_worker_status() |> assign_awaiting_worker()

    if socket.assigns.awaiting_worker do
      schedule_worker_check(socket)
    else
      socket
    end
  end

  # Only a connected LiveView polls; the first static render has no socket to
  # deliver the message to and would leak a timer for nothing.
  defp schedule_worker_check(socket) do
    if connected?(socket), do: Process.send_after(self(), :check_worker, @worker_poll_ms)
    socket
  end

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
          awaiting_worker={@awaiting_worker}
          pair_again={@pair_again?}
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
          picker_step={@picker_step}
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
  attr :awaiting_worker, :boolean, default: false
  attr :pair_again, :boolean, default: false
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
        <%!--
          A bound code is waiting on its own app to finish, which it does against
          `POST /worker_pairings` a moment later. Showing the pairing form again
          here would read as "nothing happened" and invite the person to paste a
          code that has already been used.
        --%>
        <.worker_awaiting :if={@awaiting_worker} />
        <.worker_missing
          :if={!@awaiting_worker and @worker_status == :missing}
          pairing_error={@pairing_error}
          project_id={@project_id}
          deep_link_code={@deep_link_code}
        />
        <.worker_incompatible
          :if={!@awaiting_worker and @worker_status == :incompatible}
          pairing_error={@pairing_error}
          project_id={@project_id}
          deep_link_code={@deep_link_code}
        />
        <.worker_unavailable
          :if={!@awaiting_worker and @worker_status == :unavailable}
          pair_again={@pair_again}
          pairing_error={@pairing_error}
          project_id={@project_id}
          deep_link_code={@deep_link_code}
        />
        <.worker_detected :if={@worker_status == :detected} />
      </div>
    </div>
    """
  end

  # The code was accepted and the app is finishing on its own. This is a real
  # state, not a spinner over nothing: the worker is authorized and the screen is
  # waiting for it to report the versions only it can.
  defp worker_awaiting(assigns) do
    ~H"""
    <div data-worker-awaiting>
      <.notice variant="info" icon="refresh-cw">
        <p class="font-semibold text-ink">Code accepted. Finishing on your Mac…</p>
        <p class="mt-0.5">
          The worker app is connecting itself. This usually takes a moment and needs nothing
          from you.
        </p>
      </.notice>

      <div class="mt-3">
        <.button variant="secondary" phx-click="recheck" data-recheck class="w-full sm:w-auto">
          <.lucide name="refresh-cw" class="size-4" /> Check again
        </.button>
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
            <span class="font-semibold">{ProjectStorage.label(:device)}</span>: used by this
            accountless path. Your project stays on this computer and there's no account to sign
            in to.
          </span>
        </li>
        <li class="flex gap-2.5">
          <.lucide name="cloud" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span class="text-[13px] text-ink-muted">
            <span class="font-semibold">{ProjectStorage.label(:hosted)}</span>: available from any
            device you sign in on.
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
    guidance = PairingGuidance.guidance()

    assigns =
      assigns
      |> assign(:headline, guidance.headline)
      |> assign(:steps, guidance.steps ++ [PairingGuidance.paste_step()])

    ~H"""
    <div data-state="missing">
      <.notice variant="info" icon="download">
        {@headline}
      </.notice>

      <ol class="mt-5 flex flex-col gap-4">
        <li :for={{step, index} <- Enum.with_index(@steps, 1)} class="flex gap-3">
          <span class="flex-none w-6 h-6 rounded-full bg-primary text-on-primary text-xs font-bold flex items-center justify-center">
            {index}
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-sm font-semibold text-ink">{step.title}</p>
            <p class="mt-0.5 text-[13px] leading-relaxed text-ink-muted">{step.detail}</p>
            <.button
              :if={step.action == :open}
              variant="secondary"
              size="sm"
              href="/downloads/worker"
              class="mt-2 w-full sm:w-auto"
            >
              <.lucide name="download" class="size-4" /> Download worker app
            </.button>
            <.pairing_form
              :if={step.action == :paste}
              pairing_error={@pairing_error}
              label="Pair worker"
              project_id={@project_id}
              deep_link_code={@deep_link_code}
            />
          </div>
        </li>
      </ol>
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

  # A paired worker with nothing attached. The screen states only that, in the one
  # owned wording every unavailable surface renders, and never claims the app is
  # missing or stopped: a browser cannot see either. The second route matters as
  # much as the first, because a worker record left over from a reinstall looks
  # exactly like this and only pairing again clears it.
  attr :pair_again, :boolean, default: false
  attr :pairing_error, :string, default: nil
  attr :project_id, :string, default: nil
  attr :deep_link_code, :string, default: nil

  defp worker_unavailable(assigns) do
    ~H"""
    <div data-state="unavailable">
      <.notice variant="warn" icon="unplug">
        <p>{RepositoryAssessmentLive.worker_unavailable_message()}</p>
        <p class="mt-0.5">
          Your projects are safe and still listed. They show an unavailable connection until a
          worker is back.
        </p>
      </.notice>

      <ul class="mt-5 flex flex-col gap-3 text-sm text-ink-muted">
        <li class="flex gap-2">
          <.lucide name="play" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span>Open the worker app on this Mac so it can attach again.</span>
        </li>
        <li class="flex gap-2">
          <.lucide name="wifi" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span>Then check again to continue.</span>
        </li>
        <li class="flex gap-2">
          <.lucide name="link" class="size-4 flex-none mt-0.5 text-ink-muted" />
          <span>
            Installed the worker again on this Mac? Pair it again. The worker you paired before is
            kept.
          </span>
        </li>
      </ul>

      <div class="mt-5 flex flex-col gap-2.5 sm:flex-row sm:items-center">
        <.button phx-click="recheck" data-recheck class="w-full sm:w-auto">
          <.lucide name="refresh-cw" class="size-4" /> Check again
        </.button>
        <.button
          :if={!@pair_again}
          variant="secondary"
          phx-click="pair_again"
          data-pair-again
          class="w-full sm:w-auto"
        >
          <.lucide name="link" class="size-4" /> Pair again
        </.button>
      </div>

      <.pairing_form
        :if={@pair_again}
        pairing_error={@pairing_error}
        label="Pair worker"
        project_id={@project_id}
        deep_link_code={@deep_link_code}
      />
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
        placeholder="Paste the code from the worker app"
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
  attr :picker_step, :atom, default: nil

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
              repository lives now. Only the same repository can reconnect. A different one is kept
              separate.
            <% else %>
              The worker opens your Mac's folder picker. We check the folder is a Git repository right
              here on your computer. Its path, history, and code never leave this Mac.
            <% end %>
          </p>
        </div>
      </header>

      <div :if={!@picker_step} class="mt-6">
        <.button phx-click="select_folder" data-select-folder class="w-full sm:w-auto">
          <.lucide name="folder-open" class="size-4" /> Open folder picker
        </.button>
      </div>

      <%!-- The screen says what it asked the worker to do and what it heard
      back. It cannot see this Mac, so it never claims a panel is on screen. --%>
      <div :if={@picker_step == :waiting} class="mt-6" data-selection-waiting>
        <.notice variant="info" icon="refresh-cw">
          <p class="font-semibold text-ink">Waiting for the worker</p>
          <p class="mt-0.5">
            We asked the worker app to open a folder picker. Choose the folder that holds {picker_target(
              @locate_project
            )}.
          </p>
        </.notice>

        <div class="mt-3">
          <.button
            variant="secondary"
            phx-click="cancel_selection"
            data-cancel-selection
            class="w-full sm:w-auto"
          >
            Cancel
          </.button>
        </div>
      </div>

      <div :if={@picker_step == :no_answer} class="mt-6" data-selection-no-answer>
        <.notice variant="warn" icon="unplug">
          <p class="font-semibold text-ink">No answer came back</p>
          <p class="mt-0.5">
            The worker didn't answer the folder request. Open the worker app on this Mac, then try
            again.
          </p>
        </.notice>

        <div class="mt-3">
          <.button phx-click="select_folder" data-retry-selection class="w-full sm:w-auto">
            <.lucide name="refresh-cw" class="size-4" /> Try again
          </.button>
        </div>
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
        <%!-- The worker answered with the folder's own name and nothing else,
        so there is no location to show and none is stored. --%>
        <div class="flex items-center gap-2">
          <.device_connection_badge status="connected" />
          <span class="text-sm font-semibold text-ink" data-repository-name>{@selected.name}</span>
        </div>

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
          recovered by reconnecting the repository. That would start fresh history. Recovery is only
          possible by importing a project export you made earlier (project portability).
        </p>
      </.notice>
    </div>
    """
  end
end
