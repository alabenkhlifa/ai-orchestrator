defmodule SddOrchestratorWeb.LocalOnboardingLive do
  @moduledoc """
  Accountless local-repository onboarding (`specs/02-local-project-onboarding/`).

  The `Work without GitHub` entry action lands here. The path is accountless: it
  uses the single device workspace (`Devices.establish_workspace/0`) and never a
  hosted account or session.

  ## Worker discovery (Task 2)

  On mount the page establishes the device workspace and classifies the local
  worker through `Devices.worker_status/1`:

    * `:missing` — no worker is paired, so the user gets graphical installation
      and pairing guidance (a download/install action and a pairing-code entry)
      without any terminal command.
    * `:incompatible` — a paired worker does not meet the supported macOS/protocol
      policy, so the user is guided to update or reinstall and pair a replacement.
    * `:unavailable` — a compatible worker is paired but not currently running, so
      the user is told to start it and retry; existing projects stay visible with
      an unavailable connection state rather than appearing deleted.
    * `:detected` — a compatible worker has reported in and can open the folder
      picker, so the user continues to repository selection.

  The pairing-code entry uses the dashboard-issued, attempt-bound code. In
  development and test the local worker stand-in
  (`:device_worker_stub`) completes the pairing so the graphical flow is
  exercisable without the signed native worker; with the stand-in off, the page
  waits on the real (release-gated) worker and offers a retry.

  ## Repository selection (Task 2)

  Once a worker is detected, the native folder picker (the stand-in in dev/test)
  yields a path that is validated entirely on the worker boundary through
  `Devices.RepositoryValidation.validate/2`. Only the non-reversible fingerprint
  crosses the boundary; the selected repository name and location are shown to the
  user locally. Invalid, inaccessible, and empty selections are reported without
  creating anything.
  """
  use SddOrchestratorWeb, :live_view

  import SddOrchestratorWeb.ConnectionStatus, only: [device_connection_badge: 1]

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{Pairing, RepositoryValidation, WorkerDiscovery}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, workspace} = Devices.establish_workspace()

    {:ok,
     socket
     |> assign(:page_title, "Work without GitHub")
     |> assign(:workspace, workspace)
     |> assign(:step, :discovery)
     |> assign(:pairing_error, nil)
     |> assign(:selection_error, nil)
     |> assign(:selected, nil)
     |> assign_worker_status()}
  end

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
     |> assign(:selected, nil)}
  end

  def handle_event("back_to_discovery", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :discovery)
     |> assign(:selection_error, nil)
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

  defp validate_selection(socket, path) do
    salt = socket.assigns.workspace.id

    case RepositoryValidation.validate(path, salt) do
      {:ok, %{fingerprint: fingerprint}} ->
        {:noreply,
         socket
         |> assign(:selection_error, nil)
         |> assign(:selected, %{
           name: Path.basename(path),
           location: path,
           fingerprint: fingerprint
         })}

      {:error, reason} ->
        {:noreply,
         socket |> assign(:selected, nil) |> assign(:selection_error, selection_message(reason))}
    end
  end

  defp selection_message(:not_a_git_repository),
    do: "That folder isn't a Git repository. Choose a folder that contains a Git repository."

  defp selection_message(:inaccessible),
    do: "That folder couldn't be opened. Check it still exists and try again."

  defp selection_message(:empty_repository),
    do: "That repository has no commits yet. Make your first commit, then select it again."

  defp assign_worker_status(socket) do
    status = Devices.worker_status(socket.assigns.workspace.id)
    assign(socket, :worker_status, status)
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
        />
        <.selection_step
          :if={@step == :selection}
          selected={@selected}
          selection_error={@selection_error}
        />
      </div>
    </.app_shell>
    """
  end

  # ---- worker discovery step ----

  attr :worker_status, :atom, required: true
  attr :pairing_error, :string, default: nil

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

      <div class="mt-6" data-worker-status={@worker_status}>
        <.worker_missing
          :if={@worker_status == :missing}
          pairing_error={@pairing_error}
          mode={:install}
        />
        <.worker_incompatible :if={@worker_status == :incompatible} pairing_error={@pairing_error} />
        <.worker_unavailable :if={@worker_status == :unavailable} />
        <.worker_detected :if={@worker_status == :detected} />
      </div>
    </div>
    """
  end

  attr :pairing_error, :string, default: nil
  attr :mode, :atom, default: :install

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
              A signed app you install by dragging it to Applications. Supports macOS 14 and 15.
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

      <.pairing_form pairing_error={@pairing_error} label="Pair worker" />
    </div>
    """
  end

  attr :pairing_error, :string, default: nil

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

      <.pairing_form pairing_error={@pairing_error} label="Pair replacement worker" />
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

  defp pairing_form(assigns) do
    ~H"""
    <form phx-submit="pair" class="mt-5" data-pairing-form>
      <.text_field
        id="pairing-code"
        name="pairing[code]"
        label="Pairing code"
        error={@pairing_error}
        placeholder="For example, 4K7Q-2P9X"
        autocomplete="off"
      />
      <.button type="submit" data-pair class="mt-3 w-full sm:w-auto">
        <.lucide name="link" class="size-4" /> {@label}
      </.button>
    </form>
    """
  end

  # ---- repository selection step ----

  attr :selected, :map, default: nil
  attr :selection_error, :string, default: nil

  defp selection_step(assigns) do
    ~H"""
    <div data-step="selection">
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="folder-git-2" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">Choose your repository</h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            The worker opens your Mac's folder picker. We check the folder is a Git repository right
            here on your computer — its path, history, and code never leave this Mac.
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
      </div>

      <div class="mt-6">
        <.button variant="secondary" size="sm" phx-click="back_to_discovery">
          <.lucide name="arrow-left" class="size-4" /> Back
        </.button>
      </div>
    </div>
    """
  end
end
