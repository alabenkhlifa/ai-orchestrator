defmodule SddOrchestratorWeb.ProjectLandingController do
  @moduledoc """
  Decides which project screen one person actually lands on.

  `/projects/:id` is not a screen. It is the address a catalog row, a finished
  registration, a restore, and an accepted invitation all point at, and each of
  those arrives in a different state, so the destination has to be decided per
  request rather than baked into one route.

  The decision is the authorization check itself. The board is the destination
  exactly when `ParticipantGuard.authorize/2` resolves the acting person as a
  current member of the project; everyone else gets the overview, which asks
  for nothing and shows only what a non-member may see. A project display name
  is presentation and never a precondition for that check (specs/08 AC-40), so
  a freshly registered project sends its owner straight to their board.

  Nothing is rendered here and nothing is disclosed. Both outcomes are a
  redirect, so an unauthorized visitor learns neither whether the project exists
  nor why they were sent where they were sent, and the destination re-checks
  authorization on its own mount regardless.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Delivery.ParticipantGuard

  @doc "Redirects to the project's board when it is configured, else its overview."
  def show(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, project_id} -> redirect(conn, to: landing_path(conn, project_id))
      :error -> redirect(conn, to: ~p"/projects")
    end
  end

  defp landing_path(conn, project_id) do
    case ParticipantGuard.authorize(project_id, actor(conn)) do
      {:ok, _member} -> ~p"/projects/#{project_id}/features"
      {:error, :unauthorized} -> ~p"/projects/#{project_id}/overview"
    end
  end

  # The same actor shape the feature screens build: an application session and a
  # hosted session are two ways of being the same person to the participation
  # boundary.
  defp actor(conn) do
    identity = conn.assigns[:current_hosted_identity]
    account = conn.assigns[:current_account]

    %{
      account_id: (account && account.id) || (identity && identity.account_id),
      hosted_identity_id: identity && identity.id
    }
  end
end
