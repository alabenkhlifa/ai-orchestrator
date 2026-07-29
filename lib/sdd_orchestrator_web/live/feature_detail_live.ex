defmodule SddOrchestratorWeb.FeatureDetailLive do
  @moduledoc """
  One feature's detail screen.

  This screen is where a feature's lifecycle actually changes. It shows the
  current column, any visible status, who created the feature and who is
  assigned, and the gated action available from the current column — never a
  free choice of destination.

  Later tasks fill this frame in with guided requirements, readiness, the start
  action, run activity, evidence, and review. What is fixed here is the shape:
  the current state, one authorized action at a time, and no way to set a column
  directly.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Delivery.{
    Answers,
    Assignment,
    Blocking,
    Comments,
    Features,
    ParticipantGuard,
    ProcessingDisclosure,
    QuestionRouting,
    Retry
  }

  @column_labels %{
    "draft" => "Draft",
    "ready_for_development" => "Ready for development",
    "in_development" => "In development",
    "ready_for_review" => "Ready for review",
    "done" => "Done"
  }

  @status_labels %{"blocked" => "Blocked", "failed" => "Failed"}

  # The gated action offered from each column. A column with no entry offers
  # nothing until the task that owns its action delivers it.
  @gated_actions %{
    "draft" => "Resolve the remaining blockers to make this ready for development.",
    "ready_for_development" => "Start development when you're ready.",
    "in_development" => "Development is running. Progress appears here.",
    "ready_for_review" => "Review the result and approve or send it back.",
    "done" => "This feature is done."
  }

  @comment_messages %{
    empty_comment: "Write something before posting.",
    comment_too_long: "That comment is too long. Shorten it and try again.",
    redacted_content: "Remove the address or credential from that comment before posting.",
    duplicate_comment: "That comment was already posted.",
    not_found: "This feature is no longer available."
  }

  @answer_messages %{
    empty_answer: "Write your decision before continuing.",
    answer_too_long: "That answer is too long. Shorten it and try again.",
    question_mismatch: "This question changed while you were reading it.",
    no_open_question: "This question has already been answered.",
    revision_conflict: "The specification changed while you were answering. Try again.",
    no_specification: "This project has no specification to write the answer into."
  }

  @retry_messages %{
    no_failed_run: "This run is going again already.",
    no_attempt: "There is nothing recorded to continue from.",
    stale_state: "This changed while you were looking at it. Try again."
  }

  # A failure reason is a worker's code. It is shown as a sentence a person can
  # act on, and an unrecognised code is reported rather than hidden.
  @failure_messages %{
    "agent_exit_recoverable" => "The coding agent stopped before it finished.",
    "incompatible_protocol" => "This worker speaks a version this project cannot use.",
    "invalid_authorization" => "The worker was not allowed to do this work.",
    "limits_exhausted" => "This run reached a configured limit.",
    "malformed_manifest" => "The instructions sent to the worker were not usable.",
    "missing_configuration" => "Something this run needs is not configured.",
    "provider_unavailable" => "The model provider was unavailable.",
    "rate_limited" => "The provider is rate limiting this project.",
    "transport_lost" => "The connection to the worker was lost.",
    "unsafe_workspace" => "The workspace was not in a safe state to work in.",
    "worker_unavailable" => "The configured worker was unavailable."
  }

  @impl true
  def handle_event("answer", %{"answer" => %{"body" => body}}, socket) do
    socket
    |> storage_authority()
    |> Answers.accept(
      socket.assigns.actor,
      %{project: socket.assigns.project, feature: socket.assigns.feature},
      socket.assigns.question && socket.assigns.question.id,
      body
    )
    |> case do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:answer_body, "")
         |> assign(:answer_error, nil)
         |> assign_feature(socket.assigns.project_id, socket.assigns.actor, results.feature)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:answer_body, body)
         |> assign(
           :answer_error,
           Map.get(@answer_messages, reason, "That answer was not accepted.")
         )}
    end
  end

  def handle_event("retry", _params, socket) do
    socket
    |> storage_authority()
    |> Retry.retry_now(socket.assigns.actor, %{
      project: socket.assigns.project,
      feature: socket.assigns.feature
    })
    |> case do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:retry_error, nil)
         |> assign_feature(socket.assigns.project_id, socket.assigns.actor, results.feature)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :retry_error,
           Map.get(@retry_messages, reason, "That retry was not accepted.")
         )}
    end
  end

  def handle_event("confirm_boundary", %{"digest" => digest}, socket) do
    # Deliberately not the mounted assign: the agreement must be checked against
    # the boundary in force right now, or a configuration change during the
    # dialog would be confirmed anyway.
    socket.assigns.project_id
    |> ProcessingDisclosure.confirm(socket.assigns.actor, digest)
    |> case do
      {:ok, _confirmation} ->
        {:noreply, assign_disclosure(socket)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      # The configuration moved while the dialog was open, so the person is
      # shown the boundary that is actually in force rather than agreeing to
      # one that no longer exists.
      {:error, _reason} ->
        {:noreply, socket |> assign_disclosure() |> assign(:boundary_changed?, true)}
    end
  end

  def handle_event("comment", %{"comment" => %{"body" => body}}, socket) do
    socket.assigns.project_id
    |> Comments.add(socket.assigns.actor, socket.assigns.feature.id, body)
    |> case do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:comment_body, "")
         |> assign(:comment_error, nil)
         |> refresh_activity()}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:comment_body, body)
         |> assign(:comment_error, Map.fetch!(@comment_messages, reason))}
    end
  end

  def handle_event("validate_comment", %{"comment" => %{"body" => body}}, socket) do
    {:noreply, socket |> assign(:comment_body, body) |> assign(:comment_error, nil)}
  end

  def handle_event("assign", %{"assignment" => %{"account_id" => account_id}}, socket) do
    socket.assigns.project_id
    |> Assignment.assign(socket.assigns.actor, socket.assigns.feature, blank_to_nil(account_id))
    |> apply_assignment(socket)
  end

  def handle_event("assign_to_me", _params, socket) do
    socket.assigns.project_id
    |> Assignment.assign_to_me(socket.assigns.actor, socket.assigns.feature)
    |> apply_assignment(socket)
  end

  # A rejected assignment says what went wrong without revealing whether the
  # chosen person exists elsewhere in the product.
  defp apply_assignment({:ok, feature}, socket) do
    {:noreply,
     socket
     |> assign_feature(socket.assigns.project_id, socket.assigns.actor, feature)
     |> assign(:assignment_error, nil)}
  end

  defp apply_assignment({:error, :unauthorized}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/projects")}

  defp apply_assignment({:error, reason}, socket),
    do: {:noreply, assign(socket, :assignment_error, assignment_message(reason))}

  defp assignment_message(:invalid_target),
    do: "That person is not on this project anymore. Pick someone from the list."

  defp assignment_message(_reason),
    do: "This feature changed while you were looking at it. It has been refreshed."

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(account_id), do: account_id

  @impl true
  def mount(%{"id" => project_id, "feature_id" => feature_id}, _session, socket) do
    actor = actor(socket)

    case Features.fetch(project_id, actor, feature_id) do
      {:ok, feature} ->
        {:ok, assign_feature(socket, project_id, actor, feature)}

      {:error, :unauthorized} ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/projects/#{project_id}/features")}
    end
  end

  defp actor(socket) do
    identity = socket.assigns[:current_hosted_identity]
    account = socket.assigns[:current_account]

    %{
      account_id: (account && account.id) || (identity && identity.account_id),
      hosted_identity_id: identity && identity.id
    }
  end

  defp assign_feature(socket, project_id, actor, feature) do
    members = ParticipantGuard.current_members(project_id, actor)

    socket
    |> assign(:page_title, feature.title)
    |> assign(:project_id, project_id)
    |> assign(:actor, actor)
    |> assign(:feature, feature)
    |> assign(:names, Map.new(members, &{&1.account_id, &1.display_name}))
    |> assign(:members, members)
    |> assign(:responsible, QuestionRouting.responder_label(project_id, feature))
    |> assign(:question_for_me?, QuestionRouting.tagged?(project_id, feature, actor))
    |> assign(:question, open_question(project_id, actor, feature))
    |> assign(:project, SddOrchestrator.Repo.get(SddOrchestrator.Projects.Project, project_id))
    |> assign_failed_run(actor, feature)
    |> assign(:answer_body, socket.assigns[:answer_body] || "")
    |> assign(:answer_error, socket.assigns[:answer_error])
    |> assign(:assignment_error, socket.assigns[:assignment_error])
    |> assign(:comment_body, socket.assigns[:comment_body] || "")
    |> assign(:comment_error, socket.assigns[:comment_error])
    |> load_activity(project_id, actor, feature)
    |> assign_disclosure()
  end

  # The stopped run this reader may restart, if any. Resolved after the project
  # is assigned, because the storage authority is derived from it.
  defp assign_failed_run(socket, actor, feature) do
    failed_run =
      case Retry.pending(storage_authority(socket), actor, %{
             project: socket.assigns.project,
             feature: feature
           }) do
        {:ok, run} -> run
        {:error, :unauthorized} -> nil
      end

    socket
    |> assign(:failed_run, failed_run)
    |> assign(:retry_error, socket.assigns[:retry_error])
  end

  defp assign_disclosure(socket) do
    disclosure = ProcessingDisclosure.describe()

    socket
    |> assign(:disclosure, disclosure)
    |> assign(
      :disclosure_confirmed?,
      ProcessingDisclosure.confirmed?(socket.assigns.project_id, socket.assigns.actor, disclosure)
    )
    |> assign(:boundary_changed?, socket.assigns[:boundary_changed?] || false)
  end

  defp load_activity(socket, project_id, actor, feature) do
    case Comments.list(project_id, actor, feature.id) do
      {:ok, comments} -> assign(socket, :comments, comments)
      {:error, :unauthorized} -> assign(socket, :comments, [])
    end
  end

  defp refresh_activity(socket) do
    load_activity(
      socket,
      socket.assigns.project_id,
      socket.assigns.actor,
      socket.assigns.feature
    )
  end

  # The question the run is waiting on, if any. A blocked feature keeps its
  # place in `In development`, so the question is what tells a reader why the
  # column stopped moving.
  defp open_question(project_id, actor, feature) do
    case Blocking.for_feature(project_id, actor, feature.id) do
      {:ok, question} -> question
      {:error, :unauthorized} -> nil
    end
  end

  # A question that is not this reader's to answer says so, rather than telling
  # everyone who opens the feature that it is waiting on them.
  defp question_heading(true), do: "Waiting on your decision"
  defp question_heading(false), do: "Waiting on a decision"

  # The delivery store dispatches on the project's owning authority, so the
  # screen has to hand it the same value the domain would. A project whose
  # workspace cannot be resolved yields `nil`, which every store call refuses
  # rather than guessing a store.
  defp storage_authority(%{assigns: %{project: %{workspace_id: workspace_id}}}),
    do: SddOrchestrator.Repo.get(SddOrchestrator.Accounts.PersonalWorkspace, workspace_id)

  defp storage_authority(_socket), do: nil

  defp name(_names, nil), do: nil
  defp name(names, account_id), do: Map.get(names, account_id)

  defp failure_message(nil), do: "The run stopped without recording a reason."

  defp failure_message(reason),
    do: Map.get(@failure_messages, reason, "The run stopped: #{reason}")

  defp column_label(column), do: Map.fetch!(@column_labels, column)
  defp status_label(status), do: Map.get(@status_labels, status)
  defp gated_action(column), do: Map.fetch!(@gated_actions, column)

  defp transfer_summary(%{leaves_authoritative_store: false}),
    do: "Stays in this project's own store"

  defp transfer_summary(%{transfers: transfers}),
    do: "Leaves this project's store: " <> Enum.join(transfers, ", ")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={~p"/projects/#{@project_id}/features"}>
          <.lucide name="arrow-left" class="size-4" /> Features
        </.button>
      </:actions>

      <div data-screen="feature-detail" data-feature-id={@feature.id}>
        <h1 class="text-xl font-bold text-ink" data-feature-title>{@feature.title}</h1>

        <div class="mt-3 flex flex-wrap items-center gap-2">
          <span
            class="rounded-full border border-line-strong px-2.5 py-1 text-xs text-ink-muted"
            data-feature-column
          >
            {column_label(@feature.lifecycle_column)}
          </span>
          <span
            :if={status_label(@feature.status)}
            class="inline-flex items-center gap-1.5 rounded-full border border-err-fg/40 bg-err-bg px-2.5 py-1 text-xs text-err-fg"
            data-feature-status
          >
            <.lucide name="circle-alert" class="size-3.5" />
            {status_label(@feature.status)}
          </span>
        </div>

        <section
          :if={@failed_run}
          class="mt-6 rounded-lg border border-err-fg/40 bg-err-bg p-4"
          aria-labelledby="failed-run-heading"
          data-failed-run
        >
          <h2
            id="failed-run-heading"
            class="flex items-center gap-1.5 text-[13px] font-semibold text-err-fg"
          >
            <.lucide name="circle-alert" class="size-4 flex-none" /> Development stopped
          </h2>
          <p class="mt-2 text-sm text-ink" data-failed-reason>
            {failure_message(@failed_run.failure_reason)}
          </p>
          <p class="mt-2 text-xs text-ink-muted" data-failed-branch>
            The work so far is kept on {@failed_run.branch}. Retrying continues it.
          </p>

          <p
            :if={@retry_error}
            class="mt-2 flex items-center gap-1.5 text-xs text-err-fg"
            data-retry-error
          >
            <.lucide name="circle-alert" class="size-3.5 flex-none" />
            {@retry_error}
          </p>

          <.button type="button" phx-click="retry" class="mt-4 w-full sm:w-auto" data-retry-run>
            <.lucide name="refresh-cw" class="size-4" /> Retry
          </.button>
        </section>

        <section
          :if={@question}
          class="mt-6 rounded-lg border border-err-fg/40 bg-err-bg p-4"
          aria-labelledby="blocking-question-heading"
          data-blocking-question
        >
          <h2
            id="blocking-question-heading"
            class="flex items-center gap-1.5 text-[13px] font-semibold text-err-fg"
          >
            <.lucide name="circle-alert" class="size-4 flex-none" />
            {question_heading(@question_for_me?)}
          </h2>
          <p class="mt-2 text-sm text-ink" data-question-text>{@question.question}</p>
          <p
            :if={@question.context}
            class="mt-2 text-[13px] leading-relaxed text-ink-muted"
            data-question-context
          >
            {@question.context}
          </p>
          <p class="mt-2 text-xs text-ink-muted" data-question-responder>
            Answered by {@responsible || "the project owner"}.
          </p>
          <p class="mt-2 text-xs text-ink-muted" data-question-branch>
            The work so far is kept on {@question.branch}.
          </p>

          <form
            :if={@question_for_me?}
            id="answer-form"
            phx-submit="answer"
            class="mt-4"
            data-answer-form
          >
            <.text_field
              id="answer-body"
              name="answer[body]"
              label="Your decision"
              value={@answer_body}
              error={@answer_error}
              hint="This is written into the specification before the run continues."
              autocomplete="off"
            />
            <.button type="submit" class="mt-3 w-full sm:w-auto" data-submit-answer>
              <.lucide name="check" class="size-4" /> Answer and continue
            </.button>
          </form>
        </section>

        <dl class="mt-6 flex flex-col gap-3">
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="text-[13px] font-semibold text-ink-muted">Created by</dt>
            <dd class="mt-1 text-sm text-ink" data-feature-creator>
              {name(@names, @feature.creator_account_id) || "A former member"}
            </dd>
          </div>
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="text-[13px] font-semibold text-ink-muted">Assigned to</dt>
            <dd class="mt-1 text-sm text-ink" data-feature-assignee>
              {name(@names, @feature.assigned_account_id) || "Nobody yet"}
            </dd>
          </div>
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="text-[13px] font-semibold text-ink-muted">Answers questions</dt>
            <dd class="mt-1 text-sm text-ink" data-feature-responsible>
              {@responsible || "The project owner"}
            </dd>
          </div>
        </dl>

        <section class="mt-6 rounded-lg border border-line bg-surface p-4" data-assignment>
          <h2 class="text-[13px] font-semibold text-ink">Who is working on this</h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Anyone on this project can pick who it is assigned to. Questions during development
            go to that person, or to whoever created the feature when nobody is assigned.
          </p>

          <form id="assignment-form" phx-change="assign" class="mt-4">
            <label for="assignment-account" class="block text-[13px] font-semibold text-ink">
              Assigned to
            </label>
            <select
              id="assignment-account"
              name="assignment[account_id]"
              class={[
                "mt-1.5 w-full h-10 rounded-lg border bg-surface px-3 text-sm text-ink outline-none",
                "focus:outline focus:outline-2 focus:outline-offset-0 focus:outline-focus",
                (@assignment_error && "border-err-fg") || "border-line-strong focus:border-focus"
              ]}
              aria-invalid={(@assignment_error && "true") || nil}
              aria-describedby={(@assignment_error && "assignment-error") || nil}
              data-assignment-select
            >
              <option value="" selected={is_nil(@feature.assigned_account_id)}>Nobody yet</option>
              <option
                :for={member <- @members}
                value={member.account_id}
                selected={member.account_id == @feature.assigned_account_id}
              >
                {member.display_name}
              </option>
            </select>
            <p
              :if={@assignment_error}
              id="assignment-error"
              class="mt-2 flex items-center gap-1.5 text-xs text-err-fg"
              data-assignment-error
            >
              <.lucide name="circle-alert" class="size-3.5 flex-none" />
              {@assignment_error}
            </p>
          </form>

          <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center">
            <.button
              type="button"
              variant="secondary"
              phx-click="assign_to_me"
              class="w-full sm:w-auto"
              data-assign-to-me
            >
              <.lucide name="user-round-pen" class="size-4" /> Assign to me
            </.button>
          </div>
        </section>

        <div class="mt-6 rounded-lg border border-line bg-surface p-4" data-gated-action>
          <p class="text-[13px] font-semibold text-ink">What happens next</p>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            {gated_action(@feature.lifecycle_column)}
          </p>
        </div>

        <section
          :if={@feature.lifecycle_column == "ready_for_development"}
          class="mt-6 rounded-lg border border-line bg-surface p-4"
          aria-labelledby="start-disclosure-heading"
          data-start-disclosure
          data-disclosure-confirmed={to_string(@disclosure_confirmed?)}
        >
          <h2 id="start-disclosure-heading" class="text-[13px] font-semibold text-ink">
            Before development starts
          </h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Starting development runs a coding agent against this project. Here is where that
            happens and what it can see.
          </p>

          <dl class="mt-3 flex flex-col gap-2 text-[13px]">
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Runs on</dt>
              <dd class="text-ink" data-disclosure-location>{@disclosure.execution_location}</dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Coding agent</dt>
              <dd class="text-ink" data-disclosure-agent>{@disclosure.agent_provider}</dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Model provider</dt>
              <dd class="text-ink" data-disclosure-model>{@disclosure.model_provider}</dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Preview</dt>
              <dd class="text-ink" data-disclosure-preview>
                {@disclosure.preview_provider || "No preview is configured"}
              </dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Project content</dt>
              <dd class="text-ink" data-disclosure-transfer>
                {transfer_summary(@disclosure)}
              </dd>
            </div>
          </dl>

          <div :if={@boundary_changed?} class="mt-3" data-disclosure-changed>
            <.notice variant="warn" icon="triangle-alert">
              This changed while you were reading it. Check it again before confirming.
            </.notice>
          </div>

          <p
            :if={@disclosure_confirmed?}
            class="mt-3 inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
            data-disclosure-acknowledged
          >
            <.lucide name="circle-check" class="size-4" /> You confirmed this boundary.
          </p>

          <.button
            :if={not @disclosure_confirmed?}
            type="button"
            phx-click="confirm_boundary"
            phx-value-digest={@disclosure.digest}
            class="mt-3 w-full sm:w-auto"
            data-confirm-boundary
          >
            <.lucide name="check" class="size-4" /> I understand, continue
          </.button>
        </section>

        <section class="mt-6" data-comments>
          <h2 class="text-[13px] font-semibold text-ink">Comments</h2>

          <ul :if={@comments != []} class="mt-3 flex flex-col gap-2">
            <li
              :for={comment <- @comments}
              class="rounded-lg border border-line bg-surface p-3.5"
              data-comment
            >
              <p class="text-[13px] font-semibold text-ink" data-comment-author>
                {name(@names, comment.actor_account_id) || "A former member"}
              </p>
              <p class="mt-1 text-sm text-ink" data-comment-body>{comment.payload["body"]}</p>
            </li>
          </ul>

          <p :if={@comments == []} class="mt-3 text-xs text-ink-muted" data-comments-empty>
            Nothing said about this feature yet.
          </p>

          <form
            id="comment-form"
            phx-change="validate_comment"
            phx-submit="comment"
            class="mt-4"
          >
            <.text_field
              id="comment-body"
              name="comment[body]"
              label="Add a comment"
              value={@comment_body}
              error={@comment_error}
              hint="Comments explain the work. They never stand in for a required check."
              autocomplete="off"
              phx-debounce="200"
            />
            <.button type="submit" class="mt-3 w-full sm:w-auto" data-post-comment>
              <.lucide name="pencil" class="size-4" /> Post comment
            </.button>
          </form>
        </section>
      </div>
    </.app_shell>
    """
  end
end
