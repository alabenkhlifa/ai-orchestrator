defmodule SddOrchestrator.RepositoryKits.ChangePlanStore.Hosted do
  @moduledoc "PostgreSQL change-plan-store adapter for hosted projects."

  @behaviour SddOrchestrator.RepositoryKits.ChangePlanStore

  import Ecto.Query

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryKits.RepositoryKitChangePlan

  @impl true
  def create({:hosted, account_id}, %{project_id: project_id} = attrs) do
    case Participation.owned_project(account_id, project_id) do
      {:ok, _project} ->
        attrs
        |> RepositoryKitChangePlan.create_changeset()
        |> Repo.insert()
        |> case do
          {:ok, plan} -> {:ok, plan}
          {:error, _changeset} -> {:error, :invalid_plan}
        end

      _unauthorized ->
        {:error, :not_found}
    end
  end

  def create(_authority, _attrs), do: {:error, :unsupported_authority}

  @impl true
  def current({:hosted, account_id}, project_id, now) do
    case Participation.owned_project(account_id, project_id) do
      {:ok, _project} -> read_current_plan(project_id, now)
      _unauthorized -> {:error, :not_found}
    end
  end

  def current({:participant, account_id, hosted_identity_id}, project_id, now) do
    case Participation.visible_project(project_id, account_id, hosted_identity_id) do
      {:ok, _project, _role} -> read_current_plan(project_id, now)
      _unauthorized -> {:error, :not_found}
    end
  end

  def current(_viewer, _project_id, _now), do: {:error, :not_found}

  @impl true
  def get({:hosted, _account_id}, project_id, plan_id) do
    case Repo.get_by(RepositoryKitChangePlan, id: plan_id, project_id: project_id) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end

  def get(_authority, _project_id, _plan_id), do: {:error, :not_found}

  defp read_current_plan(project_id, now) do
    RepositoryKitChangePlan
    |> where([plan], plan.project_id == ^project_id and plan.expires_at > ^now)
    |> order_by([plan], desc: plan.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end
end
