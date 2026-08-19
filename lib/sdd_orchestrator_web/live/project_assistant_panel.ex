defmodule SddOrchestratorWeb.ProjectAssistantPanel do
  @moduledoc """
  The project-scoped assistant panel, rendered identically on every project
  screen (specs/12 Task 8, AC-01, AC-22).

  Mirrors `SddOrchestratorWeb.ProjectNav`'s "rendered identically on every
  project screen" precedent, but as a `Phoenix.LiveComponent` rather than a
  stateless function component: unlike navigation, this surface owns real
  per-mount state (open/closed, the acting participant's one private
  conversation, a pending question, an opened citation, a delete
  confirmation) that six different LiveViews would otherwise have to
  duplicate in their own `handle_event/3`. A concrete, discovered reason
  rules out the alternative of plain top-level `handle_event` delegation:
  `FeatureDetailLive` already defines its own unrelated `"confirm_boundary"`
  event (the delivery/agent execution processing boundary, a different
  agreement from this panel's `SddOrchestrator.ProjectAssistant.BoundaryGate`)
  and generic names such as `"cancel"` and `"ask"`-shaped events recur across
  this codebase's LiveViews. A `Phoenix.LiveComponent`'s `phx-target={@myself}`
  isolates every event this panel defines from its host LiveView's own event
  names without renaming either side — the safer, idiomatic tool for exactly
  this "one shared, stateful widget mounted verbatim in several screens"
  shape. This is the first `Phoenix.LiveComponent` in this codebase; every
  other stateful surface so far fit inside its own single LiveView.

  Mounted only where `SddOrchestratorWeb.ProjectNav` itself renders — the six
  hosted project screens (project overview, feature board, feature detail
  (which also hosts the run and evidence views), participation, repository
  assessment, and project backup) — and, matching `project_nav`'s own
  precedent exactly, only for the hosted-authority render of a screen that
  also serves a device-authoritative path (`ProjectDashboardLive`,
  `ProjectBackupLive`, `RepositoryAssessmentLive`). The domain this panel
  calls (`SddOrchestrator.ProjectAssistantStore`,
  `SddOrchestrator.ProjectAssistant.{BoundaryGate, TurnOrchestrator}`) already
  supports a device-authoritative project equally; the device-authoritative
  screens simply have no established cross-screen navigation surface of their
  own yet for this panel to mirror (their own `project_nav` calls are
  identically guarded to hosted-only), so wiring the panel there is deferred
  to whenever that device navigation surface itself is built.

  Every action this panel exposes — open, ask, cancel, citation-open, confirm
  boundary, and delete — revalidates current authorization on its own call
  into `SddOrchestrator.ProjectAssistant.Guard` (through the domain modules
  it calls), never caching a prior result. No comment, assignment, readiness,
  run, or specification mutation exists anywhere in this module.
  """
  use SddOrchestratorWeb, :live_component

  require Logger

  alias Phoenix.LiveView.{AsyncResult, JS}
  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.ProjectAssistant.{BoundaryGate, Guard, RepositorySourceAuthorization}
  alias SddOrchestrator.ProjectAssistant.TurnOrchestrator
  alias SddOrchestrator.{ProjectAssistantStore, Repo}
  alias SddOrchestrator.Projects.Project

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:open?, fn -> false end)
      |> assign_new(:authority, fn -> resolve_authority(assigns.project_id) end)
      |> assign_new(:boundary, fn -> nil end)
      |> assign_new(:conversation, fn -> nil end)
      |> assign_new(:turns, fn -> [] end)
      |> assign_new(:question_text, fn -> "" end)
      |> assign_new(:pending_question, fn -> nil end)
      |> assign_new(:ask, fn -> AsyncResult.ok(nil) end)
      |> assign_new(:open_citation_id, fn -> nil end)
      |> assign_new(:delete_confirm?, fn -> false end)
      |> assign_new(:notice, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    if socket.assigns.open? do
      {:noreply, assign(socket, :open?, false)}
    else
      {:noreply, socket |> assign(:open?, true) |> load_panel()}
    end
  end

  def handle_event("confirm_boundary", _params, socket) do
    %{authority: authority, project_id: project_id, actor: actor, account: account} =
      socket.assigns

    case BoundaryGate.confirm(authority, project_id, actor, account) do
      {:ok, _confirmation} ->
        {:noreply, refresh_boundary(socket)}

      {:error, :unauthorized} ->
        {:noreply, close_unauthorized(socket)}

      {:error, _reason} ->
        {:noreply, refresh_boundary(socket)}
    end
  end

  def handle_event("validate_question", %{"question" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :question_text, text)}
  end

  def handle_event("ask", %{"question" => %{"text" => text}}, socket) do
    text = String.trim(text)

    if text == "" or not askable?(socket.assigns) do
      {:noreply, socket}
    else
      %{authority: authority, project_id: project_id, actor: actor, account: account} =
        socket.assigns

      {:noreply,
       socket
       |> assign(:question_text, "")
       |> assign(:pending_question, text)
       |> assign(:notice, nil)
       |> assign(:ask, AsyncResult.loading())
       |> start_async(:ask, fn ->
         safe_answer(authority, project_id, actor, account, text)
       end)}
    end
  end

  def handle_event("cancel_ask", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:ask)
     |> assign(:pending_question, nil)
     |> assign(:ask, AsyncResult.ok(nil))}
  end

  def handle_event("retry_question", %{"text" => text}, socket) do
    {:noreply, assign(socket, :question_text, text)}
  end

  def handle_event("open_citation", %{"citation-id" => citation_id}, socket) do
    %{authority: authority, project_id: project_id, actor: actor, turns: turns} =
      socket.assigns

    citation = find_citation(turns, citation_id)

    with {:ok, _member} <- authorize_citation_access(authority, project_id, actor),
         :ok <- authorize_citation_source(authority, project_id, actor, citation) do
      {:noreply, assign(socket, :open_citation_id, citation_id)}
    else
      {:error, :unauthorized} ->
        {:noreply, close_unauthorized(socket)}

      _denied ->
        {:noreply, assign(socket, :notice, :citation_unavailable)}
    end
  end

  def handle_event("close_citation", _params, socket) do
    {:noreply, assign(socket, :open_citation_id, nil)}
  end

  def handle_event("delete_confirm", _params, socket) do
    {:noreply, assign(socket, :delete_confirm?, true)}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, :delete_confirm?, false)}
  end

  def handle_event("delete", _params, socket) do
    %{authority: authority, project_id: project_id, actor: actor} = socket.assigns

    case ProjectAssistantStore.delete_conversation(authority, project_id, actor) do
      :ok ->
        {:noreply,
         socket
         |> assign(:conversation, nil)
         |> assign(:turns, [])
         |> assign(:open_citation_id, nil)
         |> assign(:delete_confirm?, false)
         |> assign(:notice, :deleted)}

      {:error, :unauthorized} ->
        {:noreply, close_unauthorized(socket)}
    end
  end

  @impl true
  def handle_async(:ask, {:ok, {:ok, {conversation, turn, citations}}}, socket) do
    turn_with_citations = Map.put(turn, :citations, citations)

    {:noreply,
     socket
     |> assign(:conversation, conversation)
     |> assign(:turns, socket.assigns.turns ++ [turn_with_citations])
     |> assign(:pending_question, nil)
     |> assign(:ask, AsyncResult.ok(nil))}
  end

  def handle_async(:ask, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:question_text, socket.assigns.pending_question || "")
     |> assign(:pending_question, nil)
     |> assign(:ask, AsyncResult.failed(AsyncResult.loading(), reason))}
  end

  def handle_async(:ask, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:question_text, socket.assigns.pending_question || "")
     |> assign(:pending_question, nil)
     |> assign(:ask, AsyncResult.failed(AsyncResult.loading(), :canceled))}
  end

  # A raised exception anywhere in the answer pipeline (an adapter defect, a
  # timeout, or any other unnormalized failure) must never crash the
  # LiveView the panel is mounted in — "the panel must remain visible...
  # never disappear" applies to a genuine internal error exactly as much as
  # to a normalized one. `TurnOrchestrator.answer/6` already normalizes every
  # failure it can predict into `{:error, atom()}`; this is the last, generic
  # backstop for one it cannot.
  defp safe_answer(authority, project_id, actor, account, text) do
    TurnOrchestrator.answer(authority, project_id, actor, account, text)
  rescue
    # Content-free by the same rule `SddOrchestrator.ProjectAssistant.SecurityLog`
    # documents for this feature: the exception's own kind, never its message
    # or stacktrace, which could echo a participant's question, an answer, or
    # other project content back into an operational log. Mirrors
    # `SddOrchestrator.Delivery.Dispatcher.safe_cycle/1`'s identical
    # "log only `error.__struct__`" backstop for the same reason.
    exception ->
      Logger.error(
        "[project_assistant_panel] answer pipeline raised: #{inspect(exception.__struct__)}"
      )

      {:error, :answer_failed}
  catch
    kind, _reason ->
      Logger.error("[project_assistant_panel] answer pipeline #{kind}")
      {:error, :answer_failed}
  end

  # --- authority and loading ------------------------------------------

  # This panel is mounted only on hosted-authority screens (mirroring
  # `project_nav`'s own hosted-only guard on the screens that serve both
  # authorities), so only the hosted branch ever resolves a real authority
  # here. A device or unknown project resolves to `nil`, which every domain
  # call below already refuses closed on (`ProjectAssistantStore`,
  # `BoundaryGate`, and `TurnOrchestrator` each fall through to
  # `{:error, :unauthorized}` for an authority they do not recognize) —
  # exactly the fail-closed contract AC-02 requires, not a special case this
  # module has to implement itself.
  defp resolve_authority(project_id) do
    case Repo.get(Project, project_id) do
      %Project{storage_mode: "hosted", workspace_id: workspace_id} ->
        Repo.get(PersonalWorkspace, workspace_id)

      _other ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  defp load_panel(socket) do
    %{authority: authority, project_id: project_id, actor: actor, account: account} =
      socket.assigns

    case ProjectAssistantStore.list_history(authority, project_id, actor) do
      {:ok, conversation, turns} ->
        socket
        |> assign(:conversation, conversation)
        |> assign(:turns, decorate_citations(authority, turns))
        |> assign(:boundary, boundary_status(authority, project_id, actor, account))
        |> assign(:notice, nil)

      {:error, :unauthorized} ->
        close_unauthorized(socket)
    end
  end

  defp refresh_boundary(socket) do
    %{authority: authority, project_id: project_id, actor: actor, account: account} =
      socket.assigns

    assign(socket, :boundary, boundary_status(authority, project_id, actor, account))
  end

  defp boundary_status(authority, project_id, actor, account) do
    case BoundaryGate.status(authority, project_id, actor, account) do
      {:ok, status} -> status
      {:error, :unauthorized} -> nil
    end
  end

  # Task 1's own `list_history/3` returns bare turns (Task 7's citations live
  # in their own table, joined only where a caller needs them — see
  # `SddOrchestrator.ProjectAssistant.TurnAnswerStore`'s own moduledoc). This
  # panel is the first private-history *reader* Task 7's citations need to
  # reach, so it decorates each turn with its citations itself, through a
  # plain `Repo.preload/2` — general Ecto infrastructure, not a rewrite of
  # any Task 1-7 domain function.
  defp decorate_citations(%PersonalWorkspace{}, turns), do: Repo.preload(turns, :citations)
  defp decorate_citations(_authority, turns), do: turns

  defp close_unauthorized(socket) do
    socket
    |> assign(:open?, false)
    |> assign(:notice, :unauthorized)
    |> assign(:conversation, nil)
    |> assign(:turns, [])
  end

  defp askable?(%{boundary: %{availability: %{state: :available}, confirmation_required: false}}),
    do: true

  defp askable?(_assigns), do: false

  defp find_citation(turns, citation_id) do
    Enum.find_value(turns, fn turn ->
      turn |> Map.get(:citations, []) |> Enum.find(&(&1.id == citation_id))
    end)
  end

  defp authorize_citation_access(%PersonalWorkspace{}, project_id, actor) do
    Guard.authorize_action(project_id, actor, :open_citation)
  end

  defp authorize_citation_access(_authority, _project_id, _actor), do: {:error, :unauthorized}

  defp authorize_citation_source(authority, project_id, actor, %{source_type: "repository"}),
    do:
      with(
        {:ok, _target} <- RepositorySourceAuthorization.authorize(authority, project_id, actor),
        do: :ok
      )

  defp authorize_citation_source(_authority, _project_id, _actor, _citation), do: :ok

  # --- presentation helpers --------------------------------------------

  defp availability_title(:setup_needed), do: "Set up your personal AI connection"
  defp availability_title(:unavailable), do: "Assistant unavailable right now"
  defp availability_title(:temporarily_limited), do: "Temporarily limited"

  defp availability_detail(:setup_needed),
    do:
      "Connect a personal AI provider to use the assistant. Nothing is sent to a model until you do."

  defp availability_detail(:unavailable),
    do:
      "Your personal AI connection can't be reached right now. Check its status, then try again."

  defp availability_detail(:temporarily_limited),
    do: "Your personal AI connection is temporarily limited. Try again in a little while."

  defp citation_label(%{source_type: "specification"}), do: "Specification"
  defp citation_label(%{source_type: "repository"}), do: "Repository"
  defp citation_label(%{source_type: "board"}), do: "Board item"
  defp citation_label(%{source_type: "run"}), do: "Run"
  defp citation_label(%{source_type: "evidence"}), do: "Evidence"
  defp citation_label(_citation), do: "Source"

  defp citation_summary(%{source_type: "specification", reference: r}),
    do: r["title"] || "current revision"

  defp citation_summary(%{source_type: "repository", reference: r}),
    do: "#{r["path"]}:#{r["start_line"]}-#{r["end_line"]}"

  defp citation_summary(%{source_type: "board", reference: r}), do: r["title"] || "board item"
  defp citation_summary(%{source_type: "run", reference: r}), do: "attempt #{r["attempt_number"]}"
  defp citation_summary(%{source_type: "evidence", reference: r}), do: r["kind"] || "evidence"
  defp citation_summary(_citation), do: nil

  defp citation_detail_lines(%{source_type: "specification", reference: r}) do
    [{"Title", r["title"]}, {"Revision", short_id(r["revision_id"])}]
  end

  defp citation_detail_lines(%{source_type: "repository", reference: r}) do
    [
      {"Path", "#{r["path"]}:#{r["start_line"]}-#{r["end_line"]}"},
      {"Branch", r["branch"]},
      {"Commit", if(r["commit"], do: short_id(r["commit"]), else: "uncommitted")},
      {"Working tree", if(r["dirty"], do: "has uncommitted changes", else: "clean")}
    ]
  end

  defp citation_detail_lines(%{source_type: "board", reference: r}) do
    [{"Title", r["title"]}, {"Column", r["lifecycle_column"]}]
  end

  defp citation_detail_lines(%{source_type: "run", reference: r}) do
    [{"Attempt", r["attempt_number"]}, {"State", r["state"]}]
  end

  defp citation_detail_lines(%{source_type: "evidence", reference: r}) do
    [{"Kind", r["kind"]}, {"Outcome", r["outcome"]}]
  end

  defp citation_detail_lines(_citation), do: []

  defp short_id(nil), do: nil
  defp short_id(id) when byte_size(id) <= 8, do: id
  defp short_id(id), do: binary_part(id, 0, 8)

  defp marker_variant(type) when type in ["unavailable", "unstable", "stale", "conflicting"],
    do: "warn"

  defp marker_variant("partial"), do: "info"
  defp marker_variant(_type), do: "neutral"

  defp marker_label("partial"), do: "Partial"
  defp marker_label("stale"), do: "Stale"
  defp marker_label("excluded"), do: "Excluded"
  defp marker_label("unavailable"), do: "Source unavailable"
  defp marker_label("conflicting"), do: "Conflicting"
  defp marker_label("unstable"), do: "Unstable"
  defp marker_label(type), do: type

  defp failure_copy("model_unavailable"),
    do: "The assistant couldn't reach your personal AI connection for this question."

  defp failure_copy(_reason), do: "The assistant couldn't answer this question."

  defp ask_error_copy(:unauthorized), do: "You no longer have access to this project."
  defp ask_error_copy(:setup_needed), do: "Set up a personal AI connection to ask a question."
  defp ask_error_copy(:unavailable), do: "The assistant is unavailable right now."
  defp ask_error_copy(:temporarily_limited), do: "The assistant is temporarily limited right now."

  defp ask_error_copy(:confirmation_required),
    do: "Review and confirm the processing summary before asking."

  defp ask_error_copy(:canceled), do: "The question was canceled."
  defp ask_error_copy(_reason), do: "The question couldn't be submitted. Try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-project-assistant>
      <button
        type="button"
        id={"project-assistant-toggle-#{@id}"}
        phx-click="toggle"
        phx-target={@myself}
        aria-expanded={to_string(@open?)}
        aria-controls={"project-assistant-body-#{@id}"}
        data-project-assistant-toggle
        class={[
          "fixed z-40 bottom-4 right-4 inline-flex items-center gap-2 rounded-full",
          "bg-primary text-on-primary shadow-lg px-4 h-11 text-sm font-semibold",
          "hover:brightness-110 transition",
          "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        ]}
      >
        <.lucide name="message-circle" class="size-[18px]" />
        <span>{if @open?, do: "Close assistant", else: "Ask the assistant"}</span>
      </button>

      <div
        :if={@open?}
        id={"project-assistant-body-#{@id}"}
        role="dialog"
        aria-label="Project assistant"
        phx-window-keydown={
          JS.push("toggle", target: @myself) |> JS.focus(to: "#project-assistant-toggle-#{@id}")
        }
        phx-key="escape"
        data-project-assistant-panel
        class={[
          "fixed z-50 inset-0 sm:inset-auto sm:bottom-20 sm:right-4",
          "sm:w-96 sm:max-h-[34rem] sm:rounded-xl sm:border sm:border-line",
          "flex flex-col bg-surface text-ink shadow-xl overflow-hidden"
        ]}
      >
        <header class="flex-none flex items-center justify-between gap-2 border-b border-line px-4 h-14">
          <h2 class="text-sm font-bold">Project assistant</h2>
          <button
            type="button"
            id={"project-assistant-close-#{@id}"}
            phx-hook="FocusOnMount"
            phx-click={
              JS.push("toggle", target: @myself)
              |> JS.focus(to: "#project-assistant-toggle-#{@id}")
            }
            aria-label="Close assistant"
            data-project-assistant-close
            class="flex-none w-9 h-9 rounded-lg flex items-center justify-center text-ink-muted hover:bg-raised hover:text-ink focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            <.lucide name="x" class="size-[18px]" />
          </button>
        </header>

        <p class="flex-none px-4 py-2 text-xs text-ink-muted border-b border-line">
          Private to you. Not shared with other project participants.
        </p>

        <.notice :if={@notice == :unauthorized} variant="err" class="m-3">
          You no longer have access to this project's assistant.
        </.notice>
        <.notice :if={@notice == :citation_unavailable} variant="warn" class="m-3">
          That citation is no longer accessible.
        </.notice>
        <.notice :if={@notice == :deleted} variant="info" class="m-3">
          Your conversation was deleted.
        </.notice>

        <div
          class="flex-1 min-h-0 overflow-y-auto px-4 py-3 space-y-3"
          tabindex="0"
          aria-label="Conversation history"
          data-project-assistant-history
        >
          <div :if={@turns == []} class="py-8">
            <.empty_state icon="message-circle" title="Ask about this project">
              <:description>
                Ask about specifications, board state, recent runs, or repository source when it's
                available. Answers cite their sources.
              </:description>
            </.empty_state>
          </div>

          <div :for={turn <- @turns} data-project-assistant-turn data-turn-outcome={turn.outcome}>
            <div class="rounded-lg bg-raised px-3 py-2 text-sm text-ink">
              <p class="font-semibold text-xs text-ink-muted mb-0.5">You asked</p>
              <p data-turn-question>{turn.question_text}</p>
            </div>

            <div
              :if={turn.outcome == "answered"}
              class="mt-2 rounded-lg border border-line px-3 py-2 text-sm"
            >
              <p :if={turn.answer_text} data-turn-answer>{turn.answer_text}</p>
              <p :if={!turn.answer_text} class="text-ink-muted italic">
                No claim could be answered from current, authorized project data.
              </p>

              <div
                :if={turn.uncertainty_markers != []}
                class="mt-2 flex flex-wrap gap-1.5"
                data-turn-markers
              >
                <span
                  :for={marker <- turn.uncertainty_markers}
                  data-marker-type={marker["type"]}
                  title={marker["detail"]}
                >
                  <.badge variant={marker_variant(marker["type"])}>
                    {marker_label(marker["type"])}
                  </.badge>
                </span>
              </div>

              <div
                :if={Map.get(turn, :citations, []) != []}
                class="mt-2 flex flex-wrap gap-1.5"
                data-turn-citations
              >
                <button
                  :for={citation <- turn.citations}
                  type="button"
                  phx-click="open_citation"
                  phx-value-citation-id={citation.id}
                  phx-target={@myself}
                  data-project-assistant-citation
                  data-citation-source-type={citation.source_type}
                  class="inline-flex items-center gap-1.5 rounded-full border border-line-strong bg-surface px-2.5 py-1 text-xs font-medium text-ink-muted hover:text-ink hover:bg-raised focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  <.lucide name="link" class="size-3.5" />
                  {citation_label(citation)}
                  <span :if={citation_summary(citation)} class="text-ink-muted">
                    · {citation_summary(citation)}
                  </span>
                </button>
              </div>
            </div>

            <div
              :if={turn.outcome == "failed"}
              class="mt-2 rounded-lg border border-err-fg/40 bg-err-bg px-3 py-2 text-sm text-err-fg"
              data-turn-failure
            >
              <p class="flex items-center gap-1.5">
                <.lucide name="triangle-alert" class="size-4 flex-none" />
                {failure_copy(turn.failure_reason)}
              </p>
              <button
                type="button"
                phx-click="retry_question"
                phx-value-text={turn.question_text}
                phx-target={@myself}
                data-project-assistant-retry
                class="mt-2 inline-flex items-center gap-1.5 text-xs font-semibold underline underline-offset-2 hover:no-underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                <.lucide name="refresh-cw" class="size-3.5" /> Retry this question
              </button>
            </div>
          </div>

          <div
            :if={@pending_question}
            class="rounded-lg bg-raised px-3 py-2 text-sm text-ink"
            data-project-assistant-pending
          >
            <p class="font-semibold text-xs text-ink-muted mb-0.5">You asked</p>
            <p>{@pending_question}</p>
            <div class="mt-2 flex items-center justify-between gap-2">
              <.spinner label="Waiting for an answer" class="size-4" />
              <button
                type="button"
                phx-click="cancel_ask"
                phx-target={@myself}
                data-project-assistant-cancel-ask
                class="text-xs font-semibold text-ink-muted hover:text-ink underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                Cancel
              </button>
            </div>
          </div>

          <div :if={@ask.failed} data-project-assistant-ask-error>
            <.notice variant="err">{ask_error_copy(@ask.failed)}</.notice>
          </div>
        </div>

        <div
          :if={@open_citation_id}
          data-project-assistant-citation-detail
          class="flex-none border-t border-line bg-raised px-4 py-3 text-sm"
        >
          <% citation = find_citation(@turns, @open_citation_id) %>
          <div :if={citation} class="flex items-start justify-between gap-2">
            <div class="min-w-0">
              <p class="font-semibold text-ink">{citation_label(citation)}</p>
              <dl class="mt-1 space-y-0.5">
                <div
                  :for={{label, value} <- citation_detail_lines(citation)}
                  :if={value}
                  class="flex gap-1.5 text-xs"
                >
                  <dt class="text-ink-muted flex-none">{label}:</dt>
                  <dd class="text-ink truncate">{value}</dd>
                </div>
              </dl>
              <p
                :if={citation.excerpt}
                data-citation-excerpt
                class="mt-1.5 rounded bg-surface border border-line px-2 py-1.5 text-xs font-mono text-ink-muted whitespace-pre-wrap break-words"
              >
                {citation.excerpt}
              </p>
            </div>
            <button
              type="button"
              phx-click="close_citation"
              phx-target={@myself}
              aria-label="Close citation"
              class="flex-none text-ink-muted hover:text-ink focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
            >
              <.lucide name="x" class="size-4" />
            </button>
          </div>
        </div>

        <div class="flex-none border-t border-line p-3 space-y-2">
          <div
            :if={@boundary && @boundary.availability.state != :available}
            data-project-assistant-availability
            data-availability-state={@boundary.availability.state}
          >
            <.notice variant={
              if @boundary.availability.state == :setup_needed, do: "info", else: "warn"
            }>
              <p class="font-semibold">{availability_title(@boundary.availability.state)}</p>
              <p class="mt-0.5">{availability_detail(@boundary.availability.state)}</p>
            </.notice>
          </div>

          <div
            :if={
              @boundary && @boundary.availability.state == :available &&
                @boundary.confirmation_required
            }
            data-project-assistant-disclosure
          >
            <.notice variant="info">
              <p class="font-semibold">Review before your first question</p>
              <p class="mt-0.5">
                Questions run through {execution_summary(@boundary.processing_summary)}.
                <span :if={@boundary.processing_summary.repository_worker_available}>
                  A repository worker may read your current working tree on demand.
                </span>
                <span :if={!@boundary.processing_summary.repository_worker_available}>
                  No repository worker is currently available.
                </span>
                Conversation history is stored at this project's {@boundary.processing_summary.storage.conversation} destination
                for up to {@boundary.processing_summary.retention.max_days} days after your last activity.
              </p>
            </.notice>
            <.button
              type="button"
              phx-click="confirm_boundary"
              phx-target={@myself}
              data-project-assistant-confirm-boundary
              variant="primary"
              size="sm"
              class="mt-2 w-full sm:w-auto"
            >
              Confirm and continue
            </.button>
          </div>

          <form
            id={"project-assistant-ask-form-#{@id}"}
            phx-submit="ask"
            phx-change="validate_question"
            phx-target={@myself}
            class="flex items-end gap-2"
          >
            <div class="flex-1">
              <label for={"project-assistant-question-#{@id}"} class="sr-only">Ask a question</label>
              <textarea
                id={"project-assistant-question-#{@id}"}
                name="question[text]"
                rows="2"
                maxlength="4000"
                placeholder="Ask about this project…"
                disabled={!askable?(assigns)}
                data-project-assistant-question
                class="w-full resize-none rounded-lg border border-line-strong bg-surface px-3 py-2 text-sm text-ink outline-none focus:outline-solid focus:outline-2 focus:outline-offset-0 focus:outline-focus disabled:opacity-50"
              >{@question_text}</textarea>
            </div>
            <.button
              type="submit"
              size="sm"
              disabled={!askable?(assigns) || @question_text == "" || @ask.loading}
              data-project-assistant-ask
              class="flex-none"
            >
              <.lucide name="send" class="size-4" />
              <span class="sr-only">Ask</span>
            </.button>
          </form>

          <div class="flex items-center justify-between pt-1">
            <button
              :if={@conversation && !@delete_confirm?}
              type="button"
              phx-click="delete_confirm"
              phx-target={@myself}
              data-project-assistant-delete
              class="inline-flex items-center gap-1.5 text-xs font-semibold text-err-fg hover:underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
            >
              <.lucide name="trash-2" class="size-3.5" /> Delete conversation
            </button>

            <div
              :if={@delete_confirm?}
              class="flex items-center gap-2 text-xs"
              data-project-assistant-delete-confirm
            >
              <span class="text-ink-muted">Delete this conversation?</span>
              <button
                type="button"
                phx-click="delete"
                phx-target={@myself}
                data-project-assistant-delete-confirm-yes
                class="font-semibold text-err-fg hover:underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                Delete
              </button>
              <button
                type="button"
                phx-click="delete_cancel"
                phx-target={@myself}
                data-project-assistant-delete-cancel
                class="font-semibold text-ink-muted hover:underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp execution_summary(%{execution: %{provider: nil}}), do: "your personal AI connection"

  defp execution_summary(%{execution: %{provider: provider}}),
    do: "your personal " <> provider <> " connection"
end
