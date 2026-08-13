defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantBoundaryStore.Hosted do
  @moduledoc false

  import Ecto.Query

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.ProjectAssistant.AssistantBoundaryConfirmation
  alias SddOrchestrator.ProjectAssistant.Guard
  alias SddOrchestrator.Repo

  @spec get_confirmation(PersonalWorkspace.t(), String.t(), Guard.actor()) ::
          {:ok, AssistantBoundaryConfirmation.t() | nil} | {:error, :unauthorized}
  def get_confirmation(%PersonalWorkspace{}, project_id, actor) do
    with {:ok, member} <- Guard.authorize_action(project_id, actor, :open_panel) do
      {:ok, get_by_identity(project_id, member.account_id)}
    end
  end

  @spec confirm(
          PersonalWorkspace.t(),
          String.t(),
          Guard.actor(),
          String.t(),
          pos_integer(),
          DateTime.t()
        ) ::
          {:ok, AssistantBoundaryConfirmation.t()} | {:error, :unauthorized | term()}
  def confirm(
        %PersonalWorkspace{},
        project_id,
        actor,
        boundary_digest,
        boundary_version,
        confirmed_at
      ) do
    with {:ok, member} <- Guard.authorize_action(project_id, actor, :confirm_boundary) do
      upsert(project_id, member.account_id, boundary_digest, boundary_version, confirmed_at)
    end
  end

  defp get_by_identity(project_id, account_id) do
    AssistantBoundaryConfirmation
    |> where([c], c.project_id == ^project_id and c.account_id == ^account_id)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  defp upsert(project_id, account_id, boundary_digest, boundary_version, confirmed_at) do
    attrs = %{
      boundary_digest: boundary_digest,
      boundary_version: boundary_version,
      confirmed_at: confirmed_at
    }

    Repo.transaction(fn ->
      case locked_by_identity(project_id, account_id) do
        nil -> insert_confirmation(project_id, account_id, attrs)
        existing -> reconfirm(existing, attrs)
      end
    end)
  end

  defp insert_confirmation(project_id, account_id, attrs) do
    %AssistantBoundaryConfirmation{}
    |> AssistantBoundaryConfirmation.create_changeset(
      Map.merge(attrs, %{project_id: project_id, account_id: account_id})
    )
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  defp reconfirm(existing, attrs) do
    existing
    |> AssistantBoundaryConfirmation.reconfirm_changeset(attrs)
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  defp unwrap_or_rollback({:ok, confirmation}), do: confirmation
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp locked_by_identity(project_id, account_id) do
    AssistantBoundaryConfirmation
    |> where([c], c.project_id == ^project_id and c.account_id == ^account_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end
end
