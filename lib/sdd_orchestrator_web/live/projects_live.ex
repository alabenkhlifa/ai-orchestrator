defmodule SddOrchestratorWeb.ProjectsLive do
  @moduledoc """
  Protected landing after sign-in.

  Task 3 establishes this route to prove protected-session routing and the
  sign-out control. The personal-workspace restoration, project catalog, empty
  state, and `Add project` handoff are owned by the project-catalog task, which
  replaces this placeholder body.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts

  @impl true
  def mount(_params, _session, socket) do
    identity = Accounts.get_github_identity(socket.assigns.current_account.id)

    {:ok,
     socket
     |> assign(:page_title, "Projects")
     |> assign(:identity, identity)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell>
      <:actions>
        <span class="hidden sm:flex items-center gap-2 text-[13px] text-ink-muted">
          <span class="w-7 h-7 rounded-full bg-raised text-ink-muted flex items-center justify-center text-xs font-bold">
            {initials(@identity)}
          </span>
          {@identity.login}
        </span>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div>
        <h1 class="text-xl font-bold text-ink">Projects</h1>
        <p class="mt-1 text-sm text-ink-muted">
          You're signed in. Your personal workspace and project catalog arrive with the next task.
        </p>
      </div>
    </.app_shell>
    """
  end

  defp initials(%{login: login}) when is_binary(login) do
    login |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(0, 2) |> String.upcase()
  end

  defp initials(_), do: "?"
end
