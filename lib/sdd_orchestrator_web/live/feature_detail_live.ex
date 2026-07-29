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

  alias SddOrchestrator.Delivery.{Assignment, Comments, Features, ParticipantGuard}

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

  @impl true
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
    |> assign(:responsible, responsible_label(project_id, feature))
    |> assign(:assignment_error, socket.assigns[:assignment_error])
    |> assign(:comment_body, socket.assigns[:comment_body] || "")
    |> assign(:comment_error, socket.assigns[:comment_error])
    |> load_activity(project_id, actor, feature)
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

  # Responsibility is derived, not stored, so the screen shows who would
  # actually be asked right now rather than a possibly stale field.
  defp responsible_label(project_id, feature) do
    case Assignment.responsible(project_id, feature) do
      {:ok, member} -> member.display_name
      {:error, :unavailable} -> nil
    end
  end

  defp name(_names, nil), do: nil
  defp name(names, account_id), do: Map.get(names, account_id)

  defp column_label(column), do: Map.fetch!(@column_labels, column)
  defp status_label(status), do: Map.get(@status_labels, status)
  defp gated_action(column), do: Map.fetch!(@gated_actions, column)

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
