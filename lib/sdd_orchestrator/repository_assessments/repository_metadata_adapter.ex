defmodule SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter do
  @moduledoc """
  Metadata-only worker boundary for preparing and revalidating a repository.

  Requests contain opaque worker and selection references, never a filesystem
  path or credential. Implementations resolve those references inside the
  worker boundary and may return only canonical identity, normalized root, and
  a full commit.
  """

  @type request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:repository_provider) => String.t(),
          required(:repository_id) => String.t(),
          required(:device_workspace_id) => Ecto.UUID.t(),
          required(:worker_ref) => Ecto.UUID.t(),
          required(:selection_ref) => String.t(),
          required(:selected_root) => String.t(),
          required(:scanner_contract_digest) => String.t(),
          required(:disclosure_digest) => String.t()
        }

  @type result :: %{
          required(:repository_provider) => String.t(),
          required(:repository_id) => String.t(),
          required(:root) => String.t(),
          required(:commit) => String.t()
        }

  @callback prepare(request()) :: {:ok, result()} | {:error, atom()}
  @callback revalidate(request()) :: {:ok, result()} | {:error, atom()}

  @spec configured() :: module()
  def configured do
    Application.get_env(
      :sdd_orchestrator,
      :repository_metadata_adapter,
      __MODULE__.Unavailable
    )
  end
end

defmodule SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter.Unavailable do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  @impl true
  def prepare(_request), do: {:error, :worker_unavailable}

  @impl true
  def revalidate(_request), do: {:error, :worker_unavailable}
end
