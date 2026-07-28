defmodule SddOrchestratorWeb.EntryLive do
  @moduledoc """
  The unauthenticated entry surface. Presents exactly two distinct primary
  actions — `Login with GitHub` and `Work without GitHub` — and, on return from
  a cancelled or failed GitHub authorization, an actionable recovery state with
  retry. A valid session never reaches here (see `:redirect_if_authenticated`).
  """
  use SddOrchestratorWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:auth_state, auth_state(params["auth"]))
     |> assign(:hosted_notice, hosted_notice(params["hosted_access"]))}
  end

  defp auth_state("cancelled"), do: :cancelled
  defp auth_state("failed"), do: :failed
  defp auth_state(_), do: :idle

  defp hosted_notice("required"),
    do: {:warn, "Verify your email before opening hosted project data."}

  defp hosted_notice("signed_out"), do: {:info, "This device has been signed out."}
  defp hosted_notice("signed_out_all"), do: {:info, "All hosted device sessions were signed out."}

  defp hosted_notice("session_revoked"),
    do: {:info, "The selected device session was signed out."}

  defp hosted_notice(_state), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell brand={false} max_width="max-w-2xl">
      <div :if={@auth_state == :idle} class="flex flex-col items-center text-center py-6 sm:py-10">
        <span class="w-14 h-14 rounded-xl bg-primary text-on-primary flex items-center justify-center">
          <.lucide name="logo" class="size-7" />
        </span>
        <h1 class="mt-4 text-3xl font-bold tracking-tight text-ink">SDD Orchestrator</h1>
        <p class="mt-2.5 max-w-md text-[15px] leading-relaxed text-ink-muted text-pretty">
          Spec-driven, AI-assisted development. Connect a repository to create your first project.
        </p>

        <div class="mt-7 flex flex-col sm:flex-row gap-3 w-full sm:max-w-lg">
          <.button size="lg" href={~p"/auth/github"} class="flex-1">
            <.lucide name="github" class="size-5" /> Login with GitHub
          </.button>
          <.button variant="secondary" size="lg" href={~p"/onboarding/local"} class="flex-1">
            <.lucide name="truck" class="size-5" /> Work without GitHub
          </.button>
        </div>

        <p class="mt-4 max-w-md text-[13px] leading-relaxed text-ink-muted text-pretty">
          “Work without GitHub” connects a repository stored on your computer. It doesn’t decide
          where AI agents run.
        </p>

        <.notice
          :if={@hosted_notice}
          variant={elem(@hosted_notice, 0) |> Atom.to_string()}
          class="mt-5 w-full max-w-lg text-left"
        >
          {elem(@hosted_notice, 1)}
        </.notice>

        <p class="mt-5 max-w-md text-[13px] leading-relaxed text-ink-muted">
          Want hosted project-data storage without GitHub?
          <.link
            navigate={~p"/hosted/access?#{[return_to: "/onboarding/local"]}"}
            class="font-semibold text-primary underline underline-offset-2 rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            Use verified email
          </.link>
        </p>

        <.link
          navigate={~p"/restore"}
          class="mt-4 inline-flex items-center gap-1.5 rounded text-[13px] font-semibold text-primary underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          data-restore-backup
        >
          <.lucide name="folder-open" class="size-4" /> Restore a project backup
        </.link>
      </div>

      <div :if={@auth_state != :idle} class="flex justify-center py-6 sm:py-10">
        <div class="w-full max-w-md rounded-xl border border-line bg-surface p-7 text-center">
          <span class="w-13 h-13 mx-auto rounded-xl bg-err-bg text-err-fg flex items-center justify-center p-3">
            <.lucide name={(@auth_state == :failed && "triangle-alert") || "x"} class="size-6" />
          </span>

          <h2 class="mt-4 text-lg font-bold text-ink">
            {(@auth_state == :failed && "Couldn’t connect to GitHub") || "Authentication cancelled"}
          </h2>
          <p class="mt-2 text-sm leading-relaxed text-ink-muted">
            {(@auth_state == :failed &&
                "Something went wrong while completing authentication. Please try again.") ||
              "You cancelled GitHub sign-in. You can try again or continue without GitHub."}
          </p>

          <div class="mt-5 flex items-center justify-center gap-2.5">
            <.button href={~p"/auth/github"}>
              <.lucide name="refresh-cw" class="size-4" /> Try again
            </.button>
            <.button variant="secondary" navigate={~p"/"}>Back</.button>
          </div>
          <.link
            navigate={~p"/onboarding/local"}
            class="mt-4 inline-block text-[13px] font-semibold text-primary underline underline-offset-2"
          >
            Work without GitHub instead
          </.link>
        </div>
      </div>

      <p class="flex items-center justify-center gap-1.5 text-xs text-ink-muted pb-4">
        <.lucide name="lock" class="size-3.5" /> This connects your GitHub account only.
      </p>
    </.app_shell>
    """
  end
end
