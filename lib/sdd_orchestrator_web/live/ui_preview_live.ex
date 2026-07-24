defmodule SddOrchestratorWeb.UIPreviewLive do
  @moduledoc """
  A non-product design-system preview that renders every shared presentation
  primitive in one place. It exists only in dev and test (see the router guard)
  and is the render surface for Task 2's LiveView, accessibility, and browser
  proofs. It is not part of the onboarding product flow and owns no workflow
  behavior.
  """
  use SddOrchestratorWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Design system")
     |> assign(:selected_repo, "1")}
  end

  @impl true
  def handle_event("select_repo", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_repo, id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-4xl">
      <div class="space-y-10">
        <div>
          <h1 class="text-xl font-bold text-ink">Design system</h1>
          <p class="mt-1 text-sm text-ink-muted">
            Shared presentation primitives in the active theme. Use the toggle in
            the top bar to switch light and dark.
          </p>
        </div>

        <section aria-labelledby="s-buttons" class="space-y-3">
          <h2 id="s-buttons" class="text-sm font-bold text-ink">Buttons</h2>
          <div class="flex flex-wrap items-center gap-3">
            <.button variant="primary">Primary</.button>
            <.button variant="secondary">Secondary</.button>
            <.button variant="ghost">Ghost</.button>
            <.button variant="primary" disabled>Disabled</.button>
            <.button variant="primary" size="sm">Small</.button>
            <.button variant="primary" size="lg">
              Continue <.lucide name="arrow-right" class="size-4" />
            </.button>
          </div>
        </section>

        <section aria-labelledby="s-status" class="space-y-3">
          <h2 id="s-status" class="text-sm font-bold text-ink">Status badges</h2>
          <div class="flex flex-wrap items-center gap-3">
            <.badge variant="ok">Connected</.badge>
            <.badge variant="info">Information</.badge>
            <.badge variant="warn">Waiting for approval</.badge>
            <.badge variant="err" icon="unplug">Disconnected</.badge>
            <.badge variant="neutral">Neutral</.badge>
          </div>
        </section>

        <section aria-labelledby="s-notices" class="space-y-3">
          <h2 id="s-notices" class="text-sm font-bold text-ink">Notices</h2>
          <.notice variant="info">
            Creating the project won't change the repository or start an AI agent.
          </.notice>
          <.notice variant="warn">
            Some organizations require an administrator to approve access first.
          </.notice>
          <.notice variant="err">Something went wrong while completing the request.</.notice>
        </section>

        <section aria-labelledby="s-loading" class="space-y-3">
          <h2 id="s-loading" class="text-sm font-bold text-ink">Loading</h2>
          <div class="flex items-center gap-4">
            <.spinner label="Connecting to GitHub" />
            <span class="text-sm text-ink-muted">Connecting to GitHub…</span>
          </div>
          <div class="space-y-2" aria-hidden="true">
            <div class="flex items-center gap-3 rounded-lg border border-line bg-surface p-3">
              <.skeleton class="size-8 rounded-full" />
              <div class="flex-1 space-y-2">
                <.skeleton class="h-3 w-2/5" />
                <.skeleton class="h-2.5 w-1/4" />
              </div>
            </div>
          </div>
        </section>

        <section aria-labelledby="s-selection" class="space-y-3">
          <h2 id="s-selection" class="text-sm font-bold text-ink">Selection</h2>
          <div id="preview-repos" role="radiogroup" aria-label="Sample repositories" class="space-y-2">
            <.radio_option
              :for={{id, owner, name} <- [{"1", "jordan-lee", "roadmap"}, {"2", "acme", "platform"}]}
              id={"repo-#{id}"}
              label={"#{owner}/#{name}"}
              selected={@selected_repo == id}
              phx-click="select_repo"
              phx-value-id={id}
            >
              <div class="text-sm truncate">
                <span class="text-ink-muted">{owner}/</span><span class="font-semibold text-ink">{name}</span>
              </div>
            </.radio_option>
          </div>
        </section>

        <section aria-labelledby="s-fields" class="space-y-3">
          <h2 id="s-fields" class="text-sm font-bold text-ink">Fields</h2>
          <div class="grid gap-4 sm:grid-cols-2">
            <.text_field
              id="f-ok"
              label="Project name"
              value="Café Roadmap"
              hint="Names are unique within your workspace."
            />
            <.text_field
              id="f-err"
              label="Project name"
              value="roadmap"
              error="That name already exists in your workspace."
            />
          </div>
        </section>

        <section aria-labelledby="s-empty" class="space-y-3">
          <h2 id="s-empty" class="text-sm font-bold text-ink">Empty & failure states</h2>
          <div class="grid gap-3 sm:grid-cols-2">
            <div class="rounded-lg border border-line bg-surface">
              <.empty_state title="No repositories available">
                <:description>We couldn't find any repositories you can access.</:description>
                <:actions>
                  <.button variant="secondary" size="sm">Retry</.button>
                </:actions>
              </.empty_state>
            </div>
            <div class="rounded-lg border border-line bg-surface">
              <.failure_state title="Couldn't load repositories">
                <:description>Check your connection and try again.</:description>
                <:actions>
                  <.button variant="primary" size="sm">
                    <.lucide name="refresh-cw" class="size-4" /> Retry
                  </.button>
                </:actions>
              </.failure_state>
            </div>
          </div>
        </section>
      </div>
    </.app_shell>
    """
  end
end
