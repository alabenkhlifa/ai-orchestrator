defmodule SddOrchestrator.Portability.HostedLocalRepositoryConnection do
  @moduledoc """
  First-connection authority gate for a normal hosted local-repository project.

  `HostedLocalRepositoryReconnection` is reachable only for a project restored
  from a backup package, because it gates on `RepositoryReconnection.required/2`
  and that function requires a `PackageProvenance` row. A hosted project created
  normally has none, so nothing could ever create its binding. This module is the
  missing entry: it authorizes the owning personal workspace, requires a hosted
  local-repository project that already holds a portable identity, takes an
  explicitly selected worker from the owner's device workspace, asks that worker
  for an exact repository proof, and hands the result to
  `HostedLocalRepositoryBindings.put_validated_binding/6`.

  The proof is control-plane-initiated. `LocalRepositoryValidation.validate/5` is
  deliberately not used: it authenticates a raw worker credential the control
  plane never holds, because only a salted digest is stored and the secret lives
  in the worker's keychain. The matcher supplied here executes inside the worker
  boundary, receives only the project-held portable identity, and returns only
  whether it matched — never a path, remote URL, filename, or Git object.

  Every durable rule stays in the shared binding transaction, which rechecks
  project ownership, selected-worker authorization, worker availability, and the
  exact repository match again before it writes. The restore gate is untouched.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}

  alias SddOrchestrator.Devices.{
    LocalWorker,
    PortableRepositoryIdentity,
    WorkerDiscovery
  }

  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @typedoc "Worker-boundary proof: receives the project-held identity, returns only a verdict."
  @type matcher :: (String.t() -> {:ok, boolean()} | {:error, term()})

  @type success :: %{
          project_id: Ecto.UUID.t(),
          state: :connected,
          outcome: HostedLocalRepositoryBindings.outcome(),
          last_validated_at: DateTime.t()
        }

  @type error ::
          :invalid_project_provider
          | :invalid_repository_identity
          | :legacy_repository_identity
          | :not_found
          | :repository_mismatch
          | :repository_unavailable
          | :unauthorized_worker
          | :worker_unavailable
          | :worker_validation_failed
          | Ecto.Changeset.t()

  @doc """
  Connects one hosted local-repository project to an explicitly selected worker.

  No package provenance is required or consulted. Authority is checked before the
  device is asked for anything, so an unauthorized caller never reaches the
  worker. Any refusal returns before a binding can be created, replaced, or
  refreshed, and the repository itself is never written to.
  """
  @spec connect(
          PersonalWorkspace.t(),
          String.t(),
          DeviceWorkspace.t(),
          String.t(),
          matcher(),
          keyword()
        ) :: {:ok, success()} | {:error, error()}
  def connect(
        personal_workspace,
        project_id,
        device_workspace,
        worker_id,
        worker_matcher,
        opts \\ []
      )

  def connect(
        %PersonalWorkspace{} = personal_workspace,
        project_id,
        %DeviceWorkspace{} = device_workspace,
        worker_id,
        worker_matcher,
        opts
      )
      when is_binary(project_id) and is_binary(worker_id) and
             is_function(worker_matcher, 1) do
    validated_at =
      opts
      |> Keyword.get(:validated_at, DateTime.utc_now())
      |> DateTime.truncate(:second)

    with {:ok, repository_id} <-
           connectable_repository_id(personal_workspace, project_id),
         :ok <- selectable_worker(device_workspace, worker_id, validated_at),
         :ok <- proved_repository(worker_matcher, repository_id),
         {:ok, %{binding: binding, outcome: outcome}} <-
           HostedLocalRepositoryBindings.put_validated_binding(
             personal_workspace,
             project_id,
             device_workspace,
             worker_id,
             repository_id,
             validated_at: validated_at
           ) do
      {:ok,
       %{
         project_id: binding.project_id,
         state: :connected,
         outcome: outcome,
         last_validated_at: binding.last_validated_at
       }}
    end
  end

  def connect(
        _personal_workspace,
        _project_id,
        _device_workspace,
        _worker_id,
        _worker_matcher,
        _opts
      ),
      do: {:error, :not_found}

  defp connectable_repository_id(%PersonalWorkspace{id: personal_workspace_id}, project_id) do
    with {:ok, project_id} <- cast_id(project_id),
         %Project{} = project <- scoped_project(personal_workspace_id, project_id),
         :ok <- local_repository_project(project),
         :ok <- portable_identity(project.canonical_repository_id) do
      {:ok, project.canonical_repository_id}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_project(personal_workspace_id, project_id) do
    Repo.one(
      from project in Project,
        where:
          project.id == ^project_id and
            project.workspace_id == ^personal_workspace_id
    )
  end

  defp local_repository_project(%Project{
         storage_mode: "hosted",
         repository_provider: "local"
       }),
       do: :ok

  defp local_repository_project(%Project{}), do: {:error, :invalid_project_provider}

  defp portable_identity(repository_id) do
    case PortableRepositoryIdentity.parse(repository_id) do
      {:ok, _identity} -> :ok
      {:error, :legacy_identifier} -> {:error, :legacy_repository_identity}
      {:error, :invalid_identifier} -> {:error, :invalid_repository_identity}
    end
  end

  defp selectable_worker(%DeviceWorkspace{id: device_workspace_id}, worker_id, now) do
    with {:ok, worker_id} <- cast_id(worker_id),
         %LocalWorker{} = worker <- authorized_worker(device_workspace_id, worker_id) do
      if WorkerDiscovery.status([worker], now: now) == :detected,
        do: :ok,
        else: {:error, :worker_unavailable}
    else
      _unauthorized -> {:error, :unauthorized_worker}
    end
  end

  defp authorized_worker(device_workspace_id, worker_id) do
    Repo.one(
      from worker in LocalWorker,
        where:
          worker.id == ^worker_id and
            worker.device_workspace_id == ^device_workspace_id and
            worker.state == "active"
    )
  end

  defp proved_repository(worker_matcher, repository_id) do
    case worker_matcher.(repository_id) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error, :repository_mismatch}

      {:error, reason}
      when reason in [:inaccessible, :not_a_git_repository, :empty_repository] ->
        {:error, :repository_unavailable}

      _other ->
        {:error, :worker_validation_failed}
    end
  rescue
    _error -> {:error, :worker_validation_failed}
  catch
    _kind, _reason -> {:error, :worker_validation_failed}
  end

  defp cast_id(value), do: Ecto.UUID.cast(value)
end
