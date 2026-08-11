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
       decision gate a second time.
    4. `:reviewing_plan` (Task 3 — AC-04, AC-05, AC-06) — reached once the
       plan's `current_field` reaches `"ready"`. Renders the fixed skeleton
       (`RepositoryInitialization.Skeleton.content/0`), the default kit
       package and its include/decline toggle
       (`RepositoryInitialization.default_kit/1` /
       `set_kit_choice/2`), the worker/provider summary
       (`Devices.Pairing.active_workers/1` and
       `SupportDispatch.provider_preview/1`), and the processing-boundary
       disclosure (`RepositoryInitialization.disclose_processing_boundary/1`,
       called once on entry into this step, gating the confirm control).
       Confirming calls `RepositoryInitialization.confirm_plan/3` with the
       snapshot the page is currently showing
       (`RepositoryInitialization.confirmation_snapshot/1`); a changed-input
       refusal (`{:error, :plan_changed}`) reloads the plan and shows a clear
       message rather than silently retrying.
    5. `:building_result` / `:failed` (Task 6 — AC-13, AC-14) — "Start
       building" on the confirmed plan runs `StagingBuilder.start_run/4` ->
       `Publisher.publish/3` -> `RepositoryInitialization.Handoff.complete/4`
       in sequence, using a deterministic `"init:" <> plan.id` idempotency
       key so re-clicking after a page reload is safe. A missing paired
       worker shows an inline error without leaving `:reviewing_plan`; any
       later pipeline failure moves to `:failed` showing its reason. Full
       success moves to `:building_result`, showing the commit, and
       `RepositoryInitialization.Readiness.evaluate/2`'s four independent
       assistant/specification/agent-execution/release axes.

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
  alias SddOrchestrator.RepositoryInitialization.{Eligibility, Handoff, Publisher, Readiness}
  alias SddOrchestrator.RepositoryInitialization.{Skeleton, StagingBuilder, SupportDispatch}

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
     |> assign(:kit_default, nil)
     |> assign(:provider_preview, nil)
     |> assign(:worker_summary, nil)
     |> assign(:confirm_error, nil)
     |> assign(:confirmed, false)
     |> assign(:build_error, nil)
     |> assign(:build_result, nil)
     |> assign(:build_readiness, nil)
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

  def handle_event("set_kit_choice", %{"choice" => choice}, socket) do
    case RepositoryInitialization.set_kit_choice(socket.assigns.plan, choice) do
      {:ok, plan} ->
        {:noreply, socket |> assign(:plan, plan) |> assign(:confirm_error, nil)}

      {:error, :no_kit_available} ->
        {:noreply, assign(socket, :confirm_error, "No kit package is available to include.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :confirm_error, "Couldn't update the kit choice. Try again.")}
    end
  end

  def handle_event("confirm_plan", _params, socket) do
    case RepositoryInitialization.confirmation_snapshot(socket.assigns.plan) do
      {:ok, snapshot} ->
        confirm_with_snapshot(socket, snapshot)

      {:error, _reason} ->
        {:noreply, assign(socket, :confirm_error, "Couldn't confirm this plan. Try again.")}
    end
  end

  def handle_event("start_build", _params, socket) do
    case worker_summary(socket.assigns.workspace.id) do
      {:error, :no_worker} ->
        {:noreply, assign(socket, :build_error, %{stage: :worker, reason: :no_worker})}

      {:ok, worker} ->
        run_pipeline(socket, worker)
    end
  end

  # ---- build pipeline internals (Task 6) ----

  defp run_pipeline(socket, worker) do
    plan = socket.assigns.plan
    idempotency_key = "init:" <> plan.id

    case StagingBuilder.start_run(plan, worker.id, ["staging_write"], idempotency_key) do
      {:ok, run} -> continue_publish(socket, run, plan)
      error -> enter_failed(socket, error)
    end
  end

  defp continue_publish(socket, run, plan) do
    case Publisher.publish(run, plan, socket.assigns.target_path) do
      {:ok, result} -> continue_handoff(socket, result, plan)
      error -> enter_failed(socket, error)
    end
  end

  defp continue_handoff(socket, result, plan) do
    case Handoff.complete(result, plan, socket.assigns.workspace, socket.assigns.target_path) do
      {:ok, result} -> enter_building_result(socket, result)
      error -> enter_failed(socket, error)
    end
  end

  defp enter_building_result(socket, result) do
    readiness = Readiness.evaluate(socket.assigns.workspace, result)

    {:noreply,
     socket
     |> assign(:step, :building_result)
     |> assign(:build_result, result)
     |> assign(:build_readiness, readiness)
     |> assign(:build_error, nil)}
  end

  defp enter_failed(socket, error) do
    {:noreply,
     socket
     |> assign(:step, :failed)
     |> assign(:build_error, %{stage: :build, reason: failure_reason(error)})}
  end

  defp failure_reason({:error, reason}), do: reason
  defp failure_reason({:error, reason, _run_or_result}), do: reason

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
        enter_reviewing_plan(socket)

      field ->
        text = dispatched_or_fallback_question(plan, socket.assigns[:current_account], field)
        socket |> assign(:step, :guided_questions) |> assign(:question_text, text)
    end
  end

  defp dispatched_or_fallback_question(plan, account, field) do
    case SupportDispatch.dispatch_turn(plan, account) do
      {:ok, %{text: text}} when is_binary(text) -> text
      _skipped_or_untexted -> Map.fetch!(@fallback_questions, field)
    end
  end

  defp field_label(field), do: Map.fetch!(@field_labels, field)

  # ---- plan-review internals (Task 3) ----

  defp enter_reviewing_plan(socket) do
    plan =
      case RepositoryInitialization.disclose_processing_boundary(socket.assigns.plan) do
        {:ok, disclosed_plan} -> disclosed_plan
        {:error, _reason} -> socket.assigns.plan
      end

    socket
    |> assign(:step, :reviewing_plan)
    |> assign(:plan, plan)
    |> assign(:confirm_error, nil)
    |> assign(:confirmed, false)
    |> refresh_reviewing_assigns()
  end

  defp refresh_reviewing_assigns(socket) do
    socket
    |> assign(:kit_default, RepositoryInitialization.default_kit())
    |> assign(
      :provider_preview,
      SupportDispatch.provider_preview(socket.assigns[:current_account])
    )
    |> assign(:worker_summary, worker_summary(socket.assigns.workspace.id))
  end

  defp worker_summary(device_workspace_id) do
    case Pairing.active_workers(device_workspace_id) do
      [worker | _rest] -> {:ok, worker}
      [] -> {:error, :no_worker}
    end
  end

  defp confirm_with_snapshot(socket, snapshot) do
    case RepositoryInitialization.confirm_plan(
           socket.assigns.plan,
           socket.assigns.workspace.id,
           snapshot
         ) do
      {:ok, confirmed_plan} ->
        {:noreply,
         socket
         |> assign(:plan, confirmed_plan)
         |> assign(:confirmed, true)
         |> assign(:confirm_error, nil)}

      {:error, :plan_changed} ->
        {:noreply,
         socket
         |> reload_reviewing_plan()
         |> assign(
           :confirm_error,
           "This plan changed since you last reviewed it. Review it again before confirming."
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, :confirm_error, "Couldn't confirm this plan. Try again.")}
    end
  end

  defp reload_reviewing_plan(socket) do
    case RepositoryInitialization.get_plan(socket.assigns.workspace.id, socket.assigns.plan.id) do
      {:ok, plan} -> socket |> assign(:plan, plan) |> refresh_reviewing_assigns()
      {:error, _reason} -> socket
    end
  end

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
        <.reviewing_plan_step
          :if={@step == :reviewing_plan}
          plan={@plan}
          kit_default={@kit_default}
          provider_preview={@provider_preview}
          worker_summary={@worker_summary}
          confirm_error={@confirm_error}
          confirmed={@confirmed}
          build_error={@build_error}
        />
        <.building_result_step
          :if={@step == :building_result}
          result={@build_result}
          readiness={@build_readiness}
        />
        <.failed_step :if={@step == :failed} build_error={@build_error} />
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
    """
  end

  attr :plan, :map, required: true
  attr :kit_default, :any, required: true
  attr :provider_preview, :any, required: true
  attr :worker_summary, :any, required: true
  attr :confirm_error, :string, default: nil
  attr :confirmed, :boolean, default: false
  attr :build_error, :any, default: nil

  defp reviewing_plan_step(assigns) do
    ~H"""
    <div data-step="reviewing-plan" data-kit-choice={@plan.kit_choice}>
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="circle-check" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">Review the exact plan</h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            Nothing is created until you confirm. Review every generated file, command, check, and
            transfer below before authorizing the working agent.
          </p>
        </div>
      </header>

      <div :if={@confirmed} class="mt-6 flex flex-col gap-4" data-state="confirmed">
        <.notice variant="info" icon="circle-check">
          Plan confirmed. Start building to materialize, commit, and hand off the repository.
        </.notice>

        <div :if={@build_error} data-build-error>
          <.notice variant="err" icon="triangle-alert">
            No paired worker was found. Pair a worker, then try again.
          </.notice>
        </div>

        <.button phx-click="start_build" data-start-build class="w-full sm:w-auto">
          Start building <.lucide name="play" class="size-4" />
        </.button>
      </div>

      <div :if={!@confirmed} class="mt-6 flex flex-col gap-6">
        <section data-section="structure">
          <h2 class="text-sm font-bold text-ink">Files created</h2>
          <ul class="mt-2 text-sm text-ink-muted list-disc list-inside">
            <li :for={entry <- Skeleton.content()["structure"]} data-structure-entry>
              {entry["path"]} <span class="text-[12px]">({entry["category"]})</span>
            </li>
          </ul>
        </section>

        <section data-section="commands">
          <h2 class="text-sm font-bold text-ink">Commands</h2>
          <p :if={Skeleton.content()["commands"] == []} class="mt-2 text-sm text-ink-muted">
            None configured yet.
          </p>
        </section>

        <section data-section="checks">
          <h2 class="text-sm font-bold text-ink">Required checks</h2>
          <p :if={Skeleton.content()["checks"] == []} class="mt-2 text-sm text-ink-muted">
            None configured yet.
          </p>
        </section>

        <section data-section="git-behavior">
          <h2 class="text-sm font-bold text-ink">Git behavior</h2>
          <dl class="mt-2 text-sm text-ink-muted grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
            <dt class="font-semibold text-ink">Initial branch</dt>
            <dd data-git-initial-branch>{Skeleton.content()["git_behavior"]["initial_branch"]}</dd>
            <dt class="font-semibold text-ink">Hooks</dt>
            <dd data-git-hooks>{Skeleton.content()["git_behavior"]["hooks"]}</dd>
            <dt class="font-semibold text-ink">First commit message</dt>
            <dd data-git-first-commit-message>
              {Skeleton.content()["git_behavior"]["first_commit_message"]}
            </dd>
          </dl>
        </section>

        <section data-section="kit">
          <h2 class="text-sm font-bold text-ink">Permanent SDD kit</h2>

          <div :if={match?({:error, :no_kit_available}, @kit_default)} data-kit-state="unavailable">
            <p class="mt-2 text-sm text-ink-muted">No kit package is available yet.</p>
          </div>

          <div :if={match?({:ok, _package}, @kit_default)} data-kit-state="available">
            <% {:ok, package} = @kit_default %>
            <dl class="mt-2 text-sm text-ink-muted grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
              <dt class="font-semibold text-ink">Source</dt>
              <dd data-kit-source>{package.source}</dd>
              <dt class="font-semibold text-ink">Publisher</dt>
              <dd data-kit-publisher>{package.publisher}</dd>
              <dt class="font-semibold text-ink">Version</dt>
              <dd data-kit-version>{package.version}</dd>
              <dt class="font-semibold text-ink">Digest</dt>
              <dd data-kit-digest class="break-all">{package.digest}</dd>
              <dt class="font-semibold text-ink">License</dt>
              <dd data-kit-license>{package.license}</dd>
            </dl>

            <div class="mt-2">
              <p class="text-[13px] font-semibold text-ink">Required permissions</p>
              <p :if={package.required_permissions == []} class="text-sm text-ink-muted">None.</p>
              <ul
                :if={package.required_permissions != []}
                class="text-sm text-ink-muted list-disc list-inside"
                data-kit-permissions
              >
                <li :for={permission <- package.required_permissions}>{permission}</li>
              </ul>
            </div>

            <div class="mt-2">
              <p class="text-[13px] font-semibold text-ink">Scripts</p>
              <p :if={package.scripts == []} class="text-sm text-ink-muted">None.</p>
              <ul
                :if={package.scripts != []}
                class="text-sm text-ink-muted list-disc list-inside"
                data-kit-scripts
              >
                <li :for={script <- package.scripts}>{script}</li>
              </ul>
            </div>

            <div
              id="kit-choice"
              role="radiogroup"
              aria-label="Permanent SDD kit choice"
              class="mt-4 flex flex-col gap-2"
            >
              <.radio_option
                id="kit-included"
                selected={@plan.kit_choice == "included"}
                label="Include the permanent SDD kit"
                phx-click="set_kit_choice"
                phx-value-choice="included"
              >
                <span class="text-sm font-semibold text-ink">Include the permanent SDD kit</span>
              </.radio_option>
              <.radio_option
                id="kit-declined"
                selected={@plan.kit_choice == "declined"}
                label="Decline the permanent SDD kit"
                phx-click="set_kit_choice"
                phx-value-choice="declined"
              >
                <span class="text-sm font-semibold text-ink">Decline the permanent SDD kit</span>
              </.radio_option>
            </div>
          </div>

          <div :if={@plan.kit_choice == "declined"} class="mt-2" data-kit-decline-notice>
            <.notice variant="info" icon="info">
              Managed runtime SDD stays available through SDD Orchestrator either way. Repository
              agents you launch independently, outside Orchestrator, will not automatically receive
              Orchestrator's managed skills, profile, or authoritative project specifications.
            </.notice>
          </div>
        </section>

        <section data-section="worker-provider">
          <h2 class="text-sm font-bold text-ink">Worker and provider</h2>
          <dl class="mt-2 text-sm text-ink-muted grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
            <dt class="font-semibold text-ink">Worker</dt>
            <dd data-worker-summary>{worker_summary_text(@worker_summary)}</dd>
            <dt class="font-semibold text-ink">Provider</dt>
            <dd data-provider-summary>{provider_summary_text(@provider_preview)}</dd>
          </dl>
        </section>

        <section data-section="processing-disclosure">
          <h2 class="text-sm font-bold text-ink">Processing boundary</h2>
          <p
            class="mt-2 text-sm leading-relaxed text-ink-muted text-pretty"
            data-processing-disclosure
          >
            Your answers stay on this device and inside SDD Orchestrator's governed runtime. Only
            the minimized purpose, users, first outcome, constraints, and technical-foundation
            answers above are sent to the configured AI provider shown above for read-only planning
            support — never your source files or the target folder's contents. Kit package files
            are vendored and inert; nothing in them executes automatically. This plan is retained
            only for this initialization attempt and is deleted once the repository is created or
            the attempt is canceled.
          </p>
        </section>

        <div :if={@confirm_error} data-confirm-error>
          <.notice variant="err" icon="triangle-alert">{@confirm_error}</.notice>
        </div>

        <div>
          <.button
            phx-click="confirm_plan"
            disabled={is_nil(@plan.disclosure_version)}
            data-confirm-plan
            class="w-full sm:w-auto"
          >
            Confirm plan <.lucide name="check" class="size-4" />
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :result, :any, required: true
  attr :readiness, :any, required: true

  defp building_result_step(assigns) do
    ~H"""
    <div data-step="building-result">
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="building-2" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">Repository initialized</h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            The repository was built, committed, and handed off to normal local onboarding.
          </p>
        </div>
      </header>

      <div class="mt-6 flex flex-col gap-6">
        <section data-section="commit">
          <h2 class="text-sm font-bold text-ink">First commit</h2>
          <dl class="mt-2 text-sm text-ink-muted grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
            <dt class="font-semibold text-ink">Commit</dt>
            <dd data-commit-sha class="break-all">{@result.commit_sha}</dd>
            <dt class="font-semibold text-ink">Tree</dt>
            <dd data-tree-digest class="break-all">{@result.tree_digest}</dd>
          </dl>
        </section>

        <section
          data-section="readiness"
          data-earliest-blocked-stage={@readiness.earliest_blocked_stage || "none"}
        >
          <h2 class="text-sm font-bold text-ink">Readiness</h2>
          <dl class="mt-2 text-sm text-ink-muted grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
            <dt class="font-semibold text-ink">Assistant</dt>
            <dd data-readiness-assistant={readiness_state(@readiness.assistant)}>
              {readiness_text(@readiness.assistant)}
            </dd>
            <dt class="font-semibold text-ink">Specification</dt>
            <dd data-readiness-specification={readiness_state(@readiness.specification)}>
              {readiness_text(@readiness.specification)}
            </dd>
            <dt class="font-semibold text-ink">Agent execution</dt>
            <dd data-readiness-agent-execution={readiness_state(@readiness.agent_execution)}>
              {readiness_text(@readiness.agent_execution)}
            </dd>
            <dt class="font-semibold text-ink">Release</dt>
            <dd data-readiness-release={readiness_state(@readiness.release)}>
              {readiness_text(@readiness.release)}
            </dd>
          </dl>
        </section>
      </div>
    </div>
    """
  end

  attr :build_error, :any, required: true

  defp failed_step(assigns) do
    ~H"""
    <div data-step="failed">
      <header class="flex items-start gap-3">
        <span class="flex-none w-11 h-11 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="triangle-alert" class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-bold tracking-tight text-ink">Couldn't build the repository</h1>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted text-pretty">
            Nothing else was created. Review the reason below, then try again.
          </p>
        </div>
      </header>

      <div class="mt-6" data-failure-reason={@build_error && @build_error.reason}>
        <.notice variant="err" icon="triangle-alert">
          Building the repository failed: {@build_error && @build_error.reason}.
        </.notice>
      </div>
    </div>
    """
  end

  defp readiness_state(:ready), do: "ready"
  defp readiness_state({:blocked, _reason}), do: "blocked"

  defp readiness_text(:ready), do: "Ready"
  defp readiness_text({:blocked, reason}), do: "Blocked — #{reason}"

  defp worker_summary_text({:ok, worker}),
    do: "#{worker.os_family} #{worker.os_major} (worker app #{worker.app_version})"

  defp worker_summary_text({:error, :no_worker}), do: "No paired worker detected yet."

  defp provider_summary_text({:ok, %{provider: provider, model: model}}),
    do: "#{provider} (#{model})"

  defp provider_summary_text({:skip, _reason}),
    do: "Provider will be shown once you're signed in with a connected AI provider."
end
