defmodule SddOrchestratorWeb.LocalOnboardingLive do
  @moduledoc """
  Handoff target for the entry surface's `Work without GitHub` action.

  The local-repository onboarding path is owned by the local-onboarding feature
  (`specs/02-local-project-onboarding/`) and is out of scope for this slice. This
  page is the non-dead handoff from the shared entry surface; the local flow
  itself is delivered by that feature.
  """
  use SddOrchestratorWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Work without GitHub")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell brand={false} max_width="max-w-xl">
      <div class="flex flex-col items-center text-center py-10">
        <span class="w-14 h-14 rounded-xl bg-raised text-ink-muted flex items-center justify-center">
          <.lucide name="truck" class="size-7" />
        </span>
        <h1 class="mt-4 text-2xl font-bold tracking-tight text-ink">Work without GitHub</h1>
        <p class="mt-2 max-w-md text-sm leading-relaxed text-ink-muted text-pretty">
          Connecting a repository stored on your computer is delivered by the local-onboarding
          feature and isn't part of this slice.
        </p>
        <.button variant="secondary" navigate={~p"/"} class="mt-6">
          <.lucide name="arrow-left" class="size-4" /> Back to sign in
        </.button>
      </div>
    </.app_shell>
    """
  end
end
