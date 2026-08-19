defmodule SddOrchestratorWeb.FeatureBoardLive do
  @moduledoc """
  The project's feature board.

  The five lifecycle columns are fixed and always rendered, so the board's shape
  communicates the workflow even when a column is empty. Cards are not
  draggable and carry no move affordance: a feature changes column only through
  the gated workflow action shown on its detail screen, which the lifecycle
  domain validates.

  People are shown by project display name, resolved from the participation
  boundary at render time. No participant email reaches this screen.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Delivery.{Feature, Features, ParticipantGuard}

  @column_labels %{
    "draft" => "Draft",
    "ready_for_development" => "Ready for development",
    "in_development" => "In development",
    "ready_for_review" => "Ready for review",
    "done" => "Done"
  }

  @status_labels %{"blocked" => "Blocked", "failed" => "Failed"}

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    actor = actor(socket)

    case Features.board(project_id, actor) do
      {:ok, board} ->
        {:ok, assign_board(socket, project_id, board, actor)}

      {:error, :unauthorized} ->
        {:ok, push_navigate(socket, to: ~p"/projects")}
    end
  end

  @impl true
  def handle_event("create_feature", %{"feature" => %{"title" => title}}, socket) do
    socket.assigns.project_id
    |> Features.create(socket.assigns.actor, %{title: title})
    |> case do
      {:ok, _feature} -> {:noreply, refresh(assign(socket, :title, ""))}
      {:error, :unauthorized} -> {:noreply, push_navigate(socket, to: ~p"/projects")}
      {:error, _changeset} -> {:noreply, assign(socket, :title, title)}
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

  defp assign_board(socket, project_id, board, actor) do
    socket
    |> assign(:page_title, "Features")
    |> assign(:project_id, project_id)
    |> assign(:actor, actor)
    |> assign(:board, board)
    |> assign(:columns, Feature.columns())
    |> assign(:names, member_names(project_id, actor))
    |> assign(:owner?, owner?(project_id, actor))
    |> assign(:title, "")
  end

  # The same fail-closed check the board already passed, re-asked for its role
  # so the owner-only navigation destination is offered to the owner alone. It
  # adds no second authorization concept.
  defp owner?(project_id, actor) do
    case ParticipantGuard.authorize(project_id, actor) do
      {:ok, %{role: :owner}} -> true
      _other -> false
    end
  end

  defp refresh(socket) do
    {:ok, board} = Features.board(socket.assigns.project_id, socket.assigns.actor)
    assign(socket, :board, board)
  end

  defp member_names(project_id, actor) do
    project_id
    |> ParticipantGuard.current_members(actor)
    |> Map.new(&{&1.account_id, &1.display_name})
  end

  defp name(_names, nil), do: nil
  defp name(names, account_id), do: Map.get(names, account_id)

  defp column_label(column), do: Map.fetch!(@column_labels, column)
  defp status_label(status), do: Map.get(@status_labels, status)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-6xl">
      <div data-screen="feature-board">
        <.project_nav
          project_id={@project_id}
          current={:features}
          owner?={@owner?}
          class="mb-6"
        />

        <.live_component
          module={SddOrchestratorWeb.ProjectAssistantPanel}
          id={"project-assistant-" <> @project_id}
          project_id={@project_id}
          actor={@actor}
          account={@current_account}
        />

        <h1 class="text-xl font-bold text-ink">Features</h1>
        <p class="mt-1 text-sm text-ink-muted">
          A feature moves between columns through the workflow actions on its own screen, not by
          dragging.
        </p>

        <form id="new-feature-form" phx-submit="create_feature" class="mt-6">
          <.text_field
            id="feature-title"
            name="feature[title]"
            label="Add a feature"
            value={@title}
            hint="Describe the outcome you want, in your own words."
            autocomplete="off"
          />
          <.button type="submit" class="mt-3 w-full sm:w-auto" data-add-feature>
            <.lucide name="plus" class="size-4" /> Add feature
          </.button>
        </form>

        <div
          class="mt-8 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-5"
          data-board
          data-drag-enabled="false"
        >
          <section
            :for={column <- @columns}
            class="rounded-lg border border-line bg-surface p-3.5"
            data-column={column}
          >
            <h2 class="text-[13px] font-semibold text-ink" data-column-label>
              {column_label(column)}
            </h2>

            <p
              :if={@board[column] == []}
              class="mt-3 text-xs text-ink-muted"
              data-column-empty
            >
              Nothing here yet.
            </p>

            <ul class="mt-3 flex flex-col gap-2">
              <li
                :for={feature <- @board[column]}
                class="rounded-lg border border-line-strong bg-bg p-3"
                data-feature
                data-feature-id={feature.id}
                data-feature-status={feature.status}
              >
                <.link
                  navigate={~p"/projects/#{@project_id}/features/#{feature.id}"}
                  class="text-sm font-semibold text-ink underline-offset-2 hover:underline focus:outline focus:outline-2 focus:outline-focus"
                  data-feature-title
                >
                  {feature.title}
                </.link>

                <p
                  :if={status_label(feature.status)}
                  class="mt-1.5 inline-flex items-center gap-1.5 text-xs text-err-fg"
                  data-feature-status-label
                >
                  <.lucide name="circle-alert" class="size-3.5" />
                  {status_label(feature.status)}
                </p>

                <dl class="mt-2 flex flex-col gap-0.5 text-xs text-ink-muted">
                  <div class="flex gap-1">
                    <dt>Created by</dt>
                    <dd data-feature-creator>
                      {name(@names, feature.creator_account_id) || "A former member"}
                    </dd>
                  </div>
                  <div :if={feature.assigned_account_id} class="flex gap-1">
                    <dt>Assigned to</dt>
                    <dd data-feature-assignee>
                      {name(@names, feature.assigned_account_id) || "A former member"}
                    </dd>
                  </div>
                </dl>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </.app_shell>
    """
  end
end
