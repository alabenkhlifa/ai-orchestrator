defmodule SddOrchestratorWeb.ProjectLandingController do
  @moduledoc """
  Decides which project screen one person actually lands on.

  `/projects/:id` is not a screen. It is the address a catalog row, a finished
  registration, a restore, and an accepted invitation all point at, and each of
  those arrives in a different state, so the destination has to be decided per
  request rather than baked into one route.

  The decision is about the project, never about the person. A project whose
  repository connection and hosted storage are both established is set up, so it
  opens on its board, where the work is; one still missing either of them opens
  on its overview, which is the screen that shows what setup is left. The first
  implementation asked whether the acting person was a current participant
  instead, which quietly turned a presentation label into a precondition for the
  board and sent the owner of every freshly registered project to a setup screen
  that had nothing left to tell them.

  Authorization is not skipped, it is simply not this decision. Nothing is
  rendered here and nothing is disclosed: both outcomes are a redirect, so an
  unauthorized visitor learns neither whether the project exists nor why they
  were sent where they were sent, and each destination re-checks access on its
  own mount. The board fails closed for anyone who is not a current member of
  that project, and the overview sits behind the application session and its
  workspace scope, so a visitor without one is sent to sign in and a foreign
  workspace never resolves the project at all.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Projects

  @doc "Redirects to the project's board when it is configured, else its overview."
  def show(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, project_id} -> redirect(conn, to: landing_path(project_id))
      :error -> redirect(conn, to: ~p"/projects")
    end
  end

  defp landing_path(project_id) do
    if Projects.configured?(project_id),
      do: ~p"/projects/#{project_id}/features",
      else: ~p"/projects/#{project_id}/overview"
  end
end
