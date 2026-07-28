defmodule SddOrchestrator.Portability.RestoreConflicts do
  @moduledoc """
  Non-mutating restore conflict evaluation for one selected destination.

  Conflict precedence is stable identity, canonical repository identity, then
  display name. Repository and project identities are never replaced. A display
  name can change only when the packaged name is the sole conflict and the user
  explicitly supplies a valid name that is available in the destination.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices

  alias SddOrchestrator.Portability.{
    PackageSection,
    ProjectPackage,
    RestoreDecision,
    RestorePreflight
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type conflict ::
          %{type: :same_identity, project_id: Ecto.UUID.t(), boundaries: [atom()]}
          | %{type: :repository, provider: String.t(), repository_id: String.t()}
          | %{type: :name, packaged_name: String.t(), requested_name: String.t() | nil}

  @doc """
  Evaluates identity, repository, and name conflicts without creating or changing
  a project.

  `session_authorities` must contain only catalogs already authorized in the
  current restore session. `replacement_name` is accepted only after the
  packaged display name is found to conflict.
  """
  @spec evaluate(ProjectPackage.t(), PersonalWorkspace.t() | DeviceWorkspace.t(), keyword()) ::
          {:ok, RestoreDecision.t()}
          | {:conflict, conflict()}
          | {:error,
             :destination_unavailable
             | :invalid_package
             | :replacement_not_allowed
             | {:invalid_name, Ecto.Changeset.t()}}
  def evaluate(package, selected_authority, opts \\ []) do
    session_authorities = Keyword.get(opts, :session_authorities, [])
    replacement = Keyword.get(opts, :replacement_name)

    with {:ok, preflight} <-
           RestorePreflight.check_identity(package, selected_authority, session_authorities),
         {:ok, package_values} <- package_values(package),
         :ok <- repository_available(selected_authority, package_values.repository),
         {:ok, display_name} <-
           resolve_name(selected_authority, package_values.name, replacement) do
      {:ok,
       %RestoreDecision{
         project_id: preflight.project_id,
         display_name: display_name,
         repository_provider: package_values.repository.provider,
         repository_id: package_values.repository.id,
         checked_boundaries: preflight.checked_boundaries
       }}
    else
      {:error, {:same_identity, conflict}} ->
        {:conflict,
         %{
           type: :same_identity,
           project_id: conflict.project_id,
           boundaries: conflict.boundaries
         }}

      {:error, {:repository, repository}} ->
        {:conflict,
         %{
           type: :repository,
           provider: repository.provider,
           repository_id: repository.id
         }}

      {:error, {:name, packaged_name, requested_name}} ->
        {:conflict,
         %{
           type: :name,
           packaged_name: packaged_name,
           requested_name: requested_name
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp package_values(%ProjectPackage{
         project: %PackageSection{
           name: :project,
           content: %{"name" => name}
         },
         repository: %PackageSection{
           name: :repository,
           content: %{"provider" => provider, "repository_id" => repository_id}
         }
       })
       when is_binary(name) and is_binary(provider) and is_binary(repository_id) do
    {:ok, %{name: name, repository: %{provider: provider, id: repository_id}}}
  end

  defp package_values(_package), do: {:error, :invalid_package}

  defp repository_available(authority, repository) do
    if repository_taken?(authority, repository),
      do: {:error, {:repository, repository}},
      else: :ok
  end

  defp repository_taken?(
         %PersonalWorkspace{id: workspace_id},
         %{provider: provider, id: repository_id}
       ) do
    Repo.exists?(
      from project in Project,
        where:
          project.workspace_id == ^workspace_id and
            project.repository_provider == ^provider and
            project.canonical_repository_id == ^repository_id
    )
  end

  defp repository_taken?(%DeviceWorkspace{}, repository) do
    Devices.list_projects()
    |> Enum.any?(&(device_repository_identity(&1) == repository))
  end

  defp repository_taken?(_authority, _repository), do: false

  defp device_repository_identity(project) do
    %{
      provider: Map.get(project, :repository_provider) || "local",
      id: Map.get(project, :repository_id) || Map.get(project, :repository_fingerprint)
    }
  end

  defp resolve_name(authority, packaged_name, nil) do
    with {:ok, validated} <- validate_name(packaged_name) do
      if name_taken?(authority, validated.key),
        do: {:error, {:name, packaged_name, nil}},
        else: {:ok, validated.name}
    end
  end

  defp resolve_name(authority, packaged_name, replacement) when is_binary(replacement) do
    with {:ok, packaged} <- validate_name(packaged_name) do
      if name_taken?(authority, packaged.key) do
        resolve_replacement(authority, packaged_name, replacement)
      else
        {:error, :replacement_not_allowed}
      end
    end
  end

  defp resolve_name(_authority, _packaged_name, _replacement),
    do: {:error, {:invalid_name, Project.rename_changeset(%Project{}, %{name: nil})}}

  defp resolve_replacement(authority, packaged_name, replacement) do
    with {:ok, validated} <- validate_name(replacement) do
      if name_taken?(authority, validated.key),
        do: {:error, {:name, packaged_name, validated.name}},
        else: {:ok, validated.name}
    end
  end

  defp validate_name(name) do
    changeset = Project.rename_changeset(%Project{}, %{name: name})

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, project} -> {:ok, %{name: project.name, key: project.name_key}}
      {:error, invalid_changeset} -> {:error, {:invalid_name, invalid_changeset}}
    end
  end

  defp name_taken?(%PersonalWorkspace{id: workspace_id}, name_key) do
    Repo.exists?(
      from project in Project,
        where: project.workspace_id == ^workspace_id and project.name_key == ^name_key
    )
  end

  defp name_taken?(%DeviceWorkspace{}, name_key) do
    Enum.any?(Devices.list_projects(), &(&1.name_key == name_key))
  end

  defp name_taken?(_authority, _name_key), do: false
end
