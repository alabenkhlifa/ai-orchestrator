defmodule SddOrchestrator.Portability.BackupSnapshot do
  @moduledoc """
  Maps one authorized authoritative project into the exact package allowlist.

  The mapper reads current specifications through `SpecificationStore`; it never
  scans a repository, follows Ecto associations beyond the approved repository
  identity, or creates a second specification copy.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Portability.{PackageSection, ProjectPackage}
  alias SddOrchestrator.Projects
  alias SddOrchestrator.SpecificationStore

  @section_version 1

  @spec build(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, ProjectPackage.t()} | {:error, atom()}
  def build(%PersonalWorkspace{} = authority, project_id) do
    with %{repository_connection: connection} = project <-
           Projects.get_project(authority, project_id),
         {:ok, repository} <- hosted_repository(connection),
         {:ok, specifications} <- SpecificationStore.current_snapshot(authority, project.id) do
      package(project.id, project.name, repository, specifications.specifications)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def build(%DeviceWorkspace{id: authority_id} = authority, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"} = project} <- Devices.get_project(project_id),
         {:ok, specifications} <- SpecificationStore.current_snapshot(authority, project.id) do
      repository = %{
        "provider" => "local",
        "repository_id" => project.repository_fingerprint
      }

      package(project.id, project.name, repository, specifications.specifications)
    else
      _reason -> {:error, :not_found}
    end
  end

  def build(_authority, _project_id), do: {:error, :not_found}

  defp hosted_repository(%{
         provider: provider,
         provider_repository_id: repository_id
       })
       when is_binary(provider) and is_integer(repository_id) do
    {:ok,
     %{
       "provider" => provider,
       "repository_id" => Integer.to_string(repository_id)
     }}
  end

  defp hosted_repository(_connection), do: {:error, :repository_identity_missing}

  defp package(project_id, name, repository, specifications) do
    with {:ok, project_section} <-
           PackageSection.new(:project, @section_version, %{
             "id" => project_id,
             "name" => name
           }),
         {:ok, repository_section} <-
           PackageSection.new(:repository, @section_version, repository),
         {:ok, specification_section} <-
           PackageSection.new(
             :specifications,
             @section_version,
             Enum.map(specifications, &specification_value/1)
           ) do
      ProjectPackage.new(project_section, repository_section, specification_section)
    end
  end

  defp specification_value(specification) do
    %{
      "id" => specification.id,
      "title" => specification.title,
      "requirements" => specification.requirements,
      "design" => specification.design,
      "tasks" => specification.tasks
    }
  end
end
