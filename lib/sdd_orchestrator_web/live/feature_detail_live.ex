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

  alias SddOrchestrator.Delivery.{Features, ParticipantGuard}

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
    names =
      project_id
      |> ParticipantGuard.current_members(actor)
      |> Map.new(&{&1.account_id, &1.display_name})

    socket
    |> assign(:page_title, feature.title)
    |> assign(:project_id, project_id)
    |> assign(:actor, actor)
    |> assign(:feature, feature)
    |> assign(:names, names)
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
        </dl>

        <div class="mt-6 rounded-lg border border-line bg-surface p-4" data-gated-action>
          <p class="text-[13px] font-semibold text-ink">What happens next</p>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            {gated_action(@feature.lifecycle_column)}
          </p>
        </div>
      </div>
    </.app_shell>
    """
  end
end
