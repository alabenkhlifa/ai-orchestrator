defmodule SddOrchestrator.RepositoryKits.InstallationStore.Hosted do
  @moduledoc "PostgreSQL installation-store adapter for hosted projects."

  @behaviour SddOrchestrator.RepositoryKits.InstallationStore

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryKits.RepositoryKitInstallation

  @impl true
  def create({:hosted, account_id}, %{project_id: project_id} = attrs) do
    case Participation.owned_project(account_id, project_id) do
      {:ok, _project} ->
        attrs
        |> RepositoryKitInstallation.create_changeset()
        |> Repo.insert()
        |> case do
          {:ok, installation} -> {:ok, installation}
          {:error, changeset} -> {:error, error_atom(changeset)}
        end

      _unauthorized ->
        {:error, :not_found}
    end
  end

  def create(_authority, _attrs), do: {:error, :unsupported_authority}

  @impl true
  def transition({:hosted, account_id}, project_id, attrs) do
    case Participation.owned_project(account_id, project_id) do
      {:ok, _project} -> transition_current(project_id, attrs)
      _unauthorized -> {:error, :not_found}
    end
  end

  def transition(_authority, _project_id, _attrs), do: {:error, :unsupported_authority}

  @impl true
  def current({:hosted, account_id}, project_id) do
    case Participation.owned_project(account_id, project_id) do
      {:ok, _project} -> read_current_installation(project_id)
      _unauthorized -> {:error, :not_found}
    end
  end

  def current({:participant, account_id, hosted_identity_id}, project_id) do
    case Participation.visible_project(project_id, account_id, hosted_identity_id) do
      {:ok, _project, _role} -> read_current_installation(project_id)
      _unauthorized -> {:error, :not_found}
    end
  end

  def current(_viewer, _project_id), do: {:error, :not_found}

  @impl true
  def raw({:hosted, _account_id}, project_id), do: read_current_installation(project_id)
  def raw(_authority, _project_id), do: {:error, :not_found}

  defp read_current_installation(project_id) do
    case Repo.get_by(RepositoryKitInstallation, project_id: project_id) do
      nil -> {:error, :not_found}
      installation -> {:ok, installation}
    end
  end

  defp transition_current(project_id, attrs) do
    case read_current_installation(project_id) do
      {:ok, current} -> persist_transition(current, attrs)
      {:error, :not_found} -> {:error, :not_installed}
    end
  end

  defp persist_transition(current, attrs) do
    current
    |> RepositoryKitInstallation.update_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, installation} -> {:ok, installation}
      {:error, changeset} -> {:error, error_atom(changeset)}
    end
  end

  defp error_atom(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {field, {_msg, opts}} ->
         field == :plan_id and opts[:constraint] == :unique
       end) do
      :already_installed
    else
      :invalid_installation
    end
  end
end
