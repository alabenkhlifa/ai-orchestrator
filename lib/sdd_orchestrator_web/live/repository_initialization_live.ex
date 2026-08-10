defmodule SddOrchestratorWeb.RepositoryInitializationLive do
  @moduledoc """
  Empty-repository initialization: eligibility and the guided question gate
  (`specs/16-empty-repository-initialization/` Task 2 — AC-01, AC-02, AC-03).

  Mirrors `SddOrchestratorWeb.LocalOnboardingLive`'s accountless entry: it
  uses the single device workspace (`Devices.establish_workspace/0`), never
  requires a hosted account or session, and drives the same local-worker
  stand-in (`:device_worker_stub`) for folder selection in dev/test. Steps:

    1. `:discovery` — worker discovery (`Devices.worker_status/1`), with the
       same graphical missing/incompatible/unavailable/detected guidance
       pattern `LocalOnboardingLive` uses.
    2. `:selecting_target` — the folder picker (the worker stand-in in
       dev/test) yields a path classified through
       `RepositoryInitialization.Eligibility.classify/1` — not
       `Devices.select_repository/2`, which requires root commits and is the
       wrong classifier for this flow. Only a classifier-eligible path
       (an empty directory or an unborn Git repository) creates a plan; a
       mature repository or a non-empty non-Git directory stops here with a
       clear message and no mutation.
    3. `:guided_questions` — the plan's `current_field` cursor
       (`purpose -> users -> first_outcome -> constraints ->
       technical_foundation -> ready`) drives one question at a time. Each
       field's question text comes from one read-only support-conversation
       turn (`RepositoryInitialization.SupportDispatch`, negotiating only the
       `plan_discovery` capability grant) when a turn can be dispatched, or a
       static fallback question otherwise; either way, the field can only be
       accepted through the user's own submitted answer
       (`RepositoryInitialization.answer_field/3`), which enforces the same
       decision gate a second time. Reaching `"ready"` ends this task's flow;
       Task 3 owns what happens next.

  The selected directory's real absolute path is kept only in this process's
  own `socket.assigns` for the life of this LiveView session — it is never
  written to the plan, never appears in a dispatched manifest, and never
  logged (AC-01's "opaque target reference" rule).
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.{Eligibility, SupportDispatch}

  @fallback_questions %{
    "purpose" => "What are you building, in a sentence or two?",
    "users" => "Who is this for?",
    "first_outcome" => "What's the first outcome this should deliver?",
    "constraints" =>
      "Any hard constraints — a deadline, compliance need, or a tool you must use?",
    "technical_foundation" =>
      "What's the minimum technical foundation this needs — language, framework, or runtime?"
  }

  @field_labels %{
    "purpose" => "Purpose",
    "users" => "Users",
    "first_outcome" => "First outcome",
    "constraints" => "Constraints",
    "technical_foundation" => "Technical foundation"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, workspace} = Devices.establish_workspace()

    {:ok,
     socket
     |> assign(:page_title, "Start with an empty repository")
     |> assign(:workspace, workspace)
     |> assign(:step, :discovery)
     |> assign(:pairing_error, nil)
     |> assign(:target_error, nil)
     |> assign(:target_path, nil)
     |> assign(:plan, nil)
     |> assign(:question_text, nil)
     |> assign(:answer_error, nil)
     |> assign_worker_status()}
  end

  @impl true
  def handle_event("recheck", _params, socket) do
    {:noreply, socket |> assign(:pairing_error, nil) |> assign_worker_status()}
  end

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
        {:noreply, socket |> assign(:pairing_error, nil) |> assign_worker_status()}
    end
  end

  def handle_event("continue_to_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :selecting_target)
     |> assign(:target_error, nil)}
  end

  def handle_event("back_to_discovery", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :discovery)
     |> assign(:target_error, nil)
     |> assign_worker_status()}
  end

  def handle_event("select_folder", _params, socket) do
    if worker_stub?() do
      classify_target(socket, stub_folder())
    else
      {:noreply, assign(socket, :target_error, "Connect the worker to open the folder picker.")}
    end
  end

  def handle_event("submit_answer", %{"field" => field, "value" => value}, socket) do
    case RepositoryInitialization.answer_field(socket.assigns.plan, field, value) do
      {:ok, plan} ->
        {:noreply, socket |> assign(:plan, plan) |> load_current_question()}

      {:error, :out_of_order} ->
        {:noreply,
         assign(
           socket,
           :answer_error,
           "That question was already answered. Refresh to continue."
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, :answer_error, "Enter an answer before continuing.")}
    end
  end

  # ---- target selection internals ----

  defp classify_target(socket, path) do
    case Eligibility.classify(path) do
      {:ok, eligibility} -> create_plan_and_advance(socket, path, eligibility)
      {:error, reason} -> {:noreply, assign(socket, :target_error, target_error_message(reason))}
    end
  end

  defp create_plan_and_advance(socket, path, eligibility) do
    attrs = %{
      device_workspace_id: socket.assigns.workspace.id,
      account_id: account_id(socket.assigns[:current_account]),
      target_reference: WorkerProtocol.generate_id(),
      eligibility: Atom.to_string(eligibility)
    }

    case RepositoryInitialization.create_plan(attrs) do
      {:ok, plan} ->
        socket =
          socket
          |> assign(:target_path, path)
          |> assign(:target_error, nil)
          |> assign(:plan, plan)
          |> assign(:step, :guided_questions)
          |> load_current_question()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, assign(socket, :target_error, "Couldn't start this plan. Try again.")}
    end
  end

  defp target_error_message(:mature_repository),
    do:
      "That folder already has commits, so it isn't eligible for empty-repository initialization here."

  defp target_error_message(:non_empty_directory),
    do:
      "That folder has existing files, so it isn't eligible for empty-repository initialization. Choose an empty folder."

  defp target_error_message(:inaccessible),
    do: "That folder couldn't be opened. Check it still exists and try again."

  defp account_id(nil), do: nil
  defp account_id(%{id: id}), do: id

  # ---- guided-question internals ----

  defp load_current_question(socket) do
    plan = socket.assigns.plan

    socket = assign(socket, :answer_error, nil)

    case plan.current_field do
      "ready" ->
        assign(socket, :question_text, nil)

      field ->
        text = dispatched_or_fallback_question(plan, socket.assigns[:current_account], field)
        assign(socket, :question_text, text)
    end
  end

  defp dispatched_or_fallback_question(plan, account, field) do
    case SupportDispatch.dispatch_turn(plan, account) do
      {:ok, %{text: text}} when is_binary(text) -> text
      _skipped_or_untexted -> Map.fetch!(@fallback_questions, field)
    end
  end

  defp field_label(field), do: Map.fetch!(@field_labels, field)

  # ---- worker discovery (mirrors the accountless local-worker stand-in) ----

  defp assign_worker_status(socket) do
    assign(socket, :worker_status, Devices.worker_status(socket.assigns.workspace.id))
  end

  defp worker_stub?, do: Application.get_env(:sdd_orchestrator, :device_worker_stub, false)

  defp stub_complete_pairing(workspace_id) do
    with {:ok, %{code: code}} <- Pairing.start_pairing(workspace_id),
         {:ok, %{worker: worker}} <- Pairing.complete_pairing(code, stub_worker_attrs()),
         {:ok, _seen} <- Pairing.mark_seen(worker) do
      :ok
    end
  end

  defp stub_worker_attrs do
    policy = Devices.WorkerDiscovery.compatibility_policy()

    %{
      os_family: policy.os_family,
      os_major: List.last(policy.os_majors),
      protocol_version: List.first(policy.protocol_versions),
      app_version: "0.0.0-stub"
    }
  end

  defp stub_folder,
    do: Application.get_env(:sdd_orchestrator, :device_worker_stub_folder) || File.cwd!()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell brand={false} max_width="max-w-xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/"}>
          <.lucide name="arrow-left" class="size-4" /> Back
        </.button>
      </:actions>

      <div data-screen="repository-initialization">
        <.discovery_step
          :if={@step == :discovery}
          worker_status={@worker_status}
          pairing_error={@pairing_error}
        />
        <.selecting_target_step :if={@step == :selecting_target} target_error={@target_error} />
        <.guided_questions_step
          :if={@step == :guided_questions}
          plan={@plan}
          question_text={@question_text}
          answer_error={@answer_error}
        />
      </div>
    </.app_shell>
    """
  end

  attr :worker_status, :atom, required: true
  attr :pairing_error, :string, default: nil

  defp discovery_step(assigns) do
    ~H"""
    <div data-step="discovery" data-worker-status={@worker_status}>
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="hard-drive" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">
            Start with an empty repository
          </h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            SDD Orchestrator reaches your local repository through the same worker app used for
            local onboarding. Nothing about your code or its location leaves your computer.
          </p>
        </div>
      </header>

      <div class="mt-6" data-state={@worker_status}>
        <div :if={@worker_status in [:missing, :incompatible]} data-state-detail="pair">
          <.notice variant="info" icon="download">
            No compatible worker is paired on this computer yet. Install or update it, then pair
            it with the code it shows — no Terminal needed.
          </.notice>

          <.button
            variant="secondary"
            size="sm"
            href="/downloads/worker"
            class="mt-4 w-full sm:w-auto"
          >
            <.lucide name="download" class="size-4" /> Download worker app
          </.button>

          <form id="pairing-form" phx-submit="pair" class="mt-5" data-pairing-form>
            <.text_field
              id="pairing-code"
              name="pairing[code]"
              label="Pairing code"
              error={@pairing_error}
              placeholder="For example, 4K7Q-2P9X"
              autocomplete="off"
            />
            <.button type="submit" data-pair class="mt-3 w-full sm:w-auto">
              <.lucide name="link" class="size-4" /> Pair worker
            </.button>
          </form>
        </div>

        <div :if={@worker_status == :unavailable} data-state-detail="unavailable">
          <.notice variant="warn" icon="unplug">
            Your worker is paired but not running right now. Open the worker app, then check
            again.
          </.notice>
          <.button phx-click="recheck" data-recheck class="mt-4 w-full sm:w-auto">
            <.lucide name="refresh-cw" class="size-4" /> Check again
          </.button>
        </div>

        <div :if={@worker_status == :detected} data-state-detail="detected">
          <.notice variant="info" icon="folder">
            You're ready to choose the empty folder you want to initialize.
          </.notice>
          <.button phx-click="continue_to_selection" data-continue class="mt-4 w-full sm:w-auto">
            Choose folder <.lucide name="arrow-right" class="size-4" />
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :target_error, :string, default: nil

  defp selecting_target_step(assigns) do
    ~H"""
    <div data-step="selecting-target">
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="folder-git-2" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">Choose an empty folder</h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            Pick an empty folder, or a folder with an uninitialized Git repository and no commits
            yet. A folder with existing files or commits isn't eligible here.
          </p>
        </div>
      </header>

      <div class="mt-6">
        <.button phx-click="select_folder" data-select-folder class="w-full sm:w-auto">
          <.lucide name="folder-open" class="size-4" /> Open folder picker
        </.button>
      </div>

      <div :if={@target_error} class="mt-5" data-target-error>
        <.notice variant="err" icon="triangle-alert">{@target_error}</.notice>
      </div>

      <div class="mt-6">
        <.button variant="secondary" size="sm" phx-click="back_to_discovery">
          <.lucide name="arrow-left" class="size-4" /> Back
        </.button>
      </div>
    </div>
    """
  end

  attr :plan, :map, required: true
  attr :question_text, :string, default: nil
  attr :answer_error, :string, default: nil

  defp guided_questions_step(assigns) do
    ~H"""
    <div data-step="guided-questions" data-current-field={@plan.current_field}>
      <div :if={@plan.current_field == "ready"} data-state="ready">
        <.notice variant="info" icon="circle-check">
          Plan questions complete. Reviewing and confirming the exact plan continues in a later
          step.
        </.notice>
      </div>

      <div :if={@plan.current_field != "ready"}>
        <header class="flex items-start gap-3">
          <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
            <.lucide name="info" class="size-5" />
          </span>
          <div class="min-w-0">
            <h1 class="text-xl font-bold tracking-tight text-ink">
              {field_label(@plan.current_field)}
            </h1>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty" data-question-text>
              {@question_text}
            </p>
          </div>
        </header>

        <form phx-submit="submit_answer" class="mt-6" data-answer-form>
          <input type="hidden" name="field" value={@plan.current_field} />
          <.text_field
            id="answer-value"
            name="value"
            label={field_label(@plan.current_field)}
            error={@answer_error}
            autocomplete="off"
          />
          <.button type="submit" data-submit-answer class="mt-3 w-full sm:w-auto">
            Continue <.lucide name="arrow-right" class="size-4" />
          </.button>
        </form>
      </div>
    </div>
    """
  end
end
