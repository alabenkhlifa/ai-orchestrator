defmodule SddOrchestrator.Portability.RepositoryReconnection do
  @moduledoc """
  Read-only handoff from a restored canonical repository identity to its normal
  authorization flow.

  Package control never authorizes repository access. This boundary returns only
  the explicit next action and never contacts GitHub, wakes a worker, reads a
  path, accepts a credential, or changes project or repository state.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Portability.PackageProvenance
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Repo

  defmodule Request do
    @moduledoc false

    @enforce_keys [:project_id, :repository_provider, :repository_id, :method]
    defstruct [:project_id, :repository_provider, :repository_id, :method]

    @type method :: :github_authorization | :local_worker_validation

    @type t :: %__MODULE__{
            project_id: Ecto.UUID.t(),
            repository_provider: String.t(),
            repository_id: String.t(),
            method: method()
          }
  end

  @spec required(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, Request.t()} | {:error, :not_found | :already_connected}
  def required(%PersonalWorkspace{} = authority, project_id) do
    with project when not is_nil(project) <- Projects.get_project(authority, project_id),
         %PackageProvenance{} <- Repo.get(PackageProvenance, project.id),
         true <- is_nil(project.repository_connection),
         {:ok, request} <- request(project) do
      {:ok, request}
    else
      false -> {:error, :already_connected}
      _reason -> {:error, :not_found}
    end
  end

  def required(%DeviceWorkspace{id: authority_id}, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{workspace_id: ^authority_id, status: "disconnected"} = project} <-
           Devices.get_project(project_id),
         {:ok, %PackageProvenance{project_id: ^project_id}} <-
           Devices.get_package_provenance(project_id),
         {:ok, request} <- request(project) do
      {:ok, request}
    else
      {:ok, %{status: _connected}} -> {:error, :already_connected}
      _reason -> {:error, :not_found}
    end
  end

  def required(_authority, _project_id), do: {:error, :not_found}

  defp request(%{
         id: project_id,
         repository_provider: "github",
         canonical_repository_id: repository_id
       })
       when is_binary(repository_id) do
    request(project_id, "github", repository_id, :github_authorization)
  end

  defp request(%{
         id: project_id,
         repository_provider: "local",
         canonical_repository_id: repository_id
       })
       when is_binary(repository_id) do
    request(project_id, "local", repository_id, :local_worker_validation)
  end

  defp request(%{
         id: project_id,
         repository_provider: "github",
         repository_id: repository_id
       })
       when is_binary(repository_id) do
    request(project_id, "github", repository_id, :github_authorization)
  end

  defp request(%{
         id: project_id,
         repository_provider: "local",
         repository_id: repository_id
       })
       when is_binary(repository_id) do
    request(project_id, "local", repository_id, :local_worker_validation)
  end

  defp request(_project), do: {:error, :not_found}

  defp request(project_id, provider, repository_id, method) do
    {:ok,
     %Request{
       project_id: project_id,
       repository_provider: provider,
       repository_id: repository_id,
       method: method
     }}
  end
end
