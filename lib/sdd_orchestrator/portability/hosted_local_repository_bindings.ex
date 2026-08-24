defmodule SddOrchestrator.Portability.HostedLocalRepositoryBindings do
  @moduledoc """
  Authorization and lifecycle boundary for hosted local-repository bindings.

  Persistence is allowed only for an owning personal workspace, an explicitly
  selected device workspace and active reachable worker, and an exact validated
  copy of the local portable identity already held by the project. The worker
  performs the repository proof before this boundary is called; this module
  rechecks every hosted authority and persists only the minimized routing result.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}

  alias SddOrchestrator.Devices.{
    LocalWorker,
    PortableRepositoryIdentity,
    WorkerDiscovery
  }

  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type outcome :: :created | :retained | :replaced
  @type state :: :connected | :temporarily_unavailable | :disconnected

  @doc """
  Persists a worker validation result after rechecking both authority boundaries.

  The supplied repository identifier is the exact successful result from the
  worker validation boundary. A mismatch or any failed authority or availability
  check rolls back before an existing binding can be changed.
  """
  @spec put_validated_binding(
          PersonalWorkspace.t(),
          String.t(),
          DeviceWorkspace.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, %{binding: HostedLocalRepositoryBinding.t(), outcome: outcome()}}
          | {:error,
             :not_found
             | :invalid_project_provider
             | :invalid_repository_identity
             | :repository_mismatch
             | :unauthorized_worker
             | :worker_unavailable
             | Ecto.Changeset.t()}
  def put_validated_binding(
        personal_workspace,
        project_id,
        device_workspace,
        worker_id,
        validated_repository_id,
        opts \\ []
      )

  def put_validated_binding(
        %PersonalWorkspace{id: personal_workspace_id},
        project_id,
        %DeviceWorkspace{id: device_workspace_id},
        worker_id,
        validated_repository_id,
        opts
      )
      when is_binary(project_id) and is_binary(worker_id) and
             is_binary(validated_repository_id) do
    validated_at =
      opts
      |> Keyword.get(:validated_at, DateTime.utc_now())
      |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      with {:ok, project_id} <- cast_id(project_id),
           %Project{} = project <-
             authorized_project(personal_workspace_id, project_id),
           :ok <- validate_project(project, validated_repository_id),
           {:ok, worker_id} <- cast_id(worker_id),
           %LocalWorker{} = worker <-
             authorized_worker(device_workspace_id, worker_id),
           :ok <- validate_availability(worker, validated_at) do
        persist(project.id, worker.id, validated_at)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def put_validated_binding(
        %PersonalWorkspace{},
        _project_id,
        %DeviceWorkspace{},
        _worker_id,
        _validated_repository_id,
        _opts
      ),
      do: {:error, :not_found}

  @doc """
  Returns the scoped binding and its derived presentation state.

  Worker heartbeat or compatibility changes never mutate the binding. A missing
  binding is reported as disconnected; any bound worker that is not currently
  active, compatible, and reachable is temporarily unavailable.

  A hosted local-repository project whose stored identity does not parse — a
  legacy workspace-scoped value, or a malformed one — is reported as
  `:invalid_repository_identity` rather than as a state, because no binding can
  exist for an identity no worker can prove.
  """
  @spec connection_state(PersonalWorkspace.t(), String.t(), keyword()) ::
          {:ok, %{binding: HostedLocalRepositoryBinding.t() | nil, state: state()}}
          | {:error, :not_found | :invalid_project_provider | :invalid_repository_identity}
  def connection_state(personal_workspace, project_id, opts \\ [])

  def connection_state(
        %PersonalWorkspace{id: personal_workspace_id},
        project_id,
        opts
      )
      when is_binary(project_id) do
    now =
      opts
      |> Keyword.get(:now, DateTime.utc_now())
      |> DateTime.truncate(:second)

    with {:ok, project_id} <- cast_id(project_id),
         %Project{} = project <- scoped_project(personal_workspace_id, project_id),
         :ok <- validate_local_project(project) do
      case Repo.get(HostedLocalRepositoryBinding, project.id) do
        nil ->
          {:ok, %{binding: nil, state: :disconnected}}

        %HostedLocalRepositoryBinding{} = binding ->
          binding = Repo.preload(binding, :worker)
          {:ok, %{binding: binding, state: worker_state(binding.worker, now)}}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def connection_state(%PersonalWorkspace{}, _project_id, _opts), do: {:error, :not_found}

  @doc "Deletes the scoped project's binding. Repeating disconnect is idempotent."
  @spec disconnect(PersonalWorkspace.t(), String.t()) ::
          {:ok, :disconnected} | {:error, :not_found}
  def disconnect(%PersonalWorkspace{id: personal_workspace_id}, project_id)
      when is_binary(project_id) do
    with {:ok, project_id} <- cast_id(project_id),
         %Project{} = project <- scoped_project(personal_workspace_id, project_id) do
      Repo.delete_all(
        from binding in HostedLocalRepositoryBinding,
          where: binding.project_id == ^project.id
      )

      {:ok, :disconnected}
    else
      _ -> {:error, :not_found}
    end
  end

  def disconnect(%PersonalWorkspace{}, _project_id), do: {:error, :not_found}

  @doc "Deletes every binding when the hosted service terminates."
  @spec disconnect_all_for_service_termination() :: {:ok, non_neg_integer()}
  def disconnect_all_for_service_termination do
    {count, _} = Repo.delete_all(HostedLocalRepositoryBinding)
    {:ok, count}
  end

  defp authorized_project(personal_workspace_id, project_id) do
    Repo.one(
      from project in Project,
        where:
          project.id == ^project_id and
            project.workspace_id == ^personal_workspace_id,
        lock: "FOR UPDATE"
    )
  end

  defp scoped_project(personal_workspace_id, project_id) do
    Repo.one(
      from project in Project,
        where:
          project.id == ^project_id and
            project.workspace_id == ^personal_workspace_id
    )
  end

  defp authorized_worker(device_workspace_id, worker_id) do
    Repo.one(
      from worker in LocalWorker,
        where:
          worker.id == ^worker_id and
            worker.device_workspace_id == ^device_workspace_id and
            worker.state == "active",
        lock: "FOR UPDATE"
    )
    |> case do
      nil -> {:error, :unauthorized_worker}
      worker -> worker
    end
  end

  defp validate_project(project, validated_repository_id) do
    with :ok <- validate_local_project(project),
         true <- project.canonical_repository_id == validated_repository_id do
      :ok
    else
      false -> {:error, :repository_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_local_project(%Project{
         storage_mode: "hosted",
         repository_provider: "local",
         canonical_repository_id: repository_id
       }) do
    case PortableRepositoryIdentity.parse(repository_id) do
      {:ok, _identity} -> :ok
      {:error, _reason} -> {:error, :invalid_repository_identity}
    end
  end

  defp validate_local_project(%Project{}), do: {:error, :invalid_project_provider}

  defp validate_availability(worker, now) do
    if WorkerDiscovery.status([worker], now: now) == :detected,
      do: :ok,
      else: {:error, :worker_unavailable}
  end

  defp persist(project_id, worker_id, validated_at) do
    case Repo.get(HostedLocalRepositoryBinding, project_id) do
      nil ->
        binding =
          %HostedLocalRepositoryBinding{}
          |> HostedLocalRepositoryBinding.changeset(%{
            project_id: project_id,
            worker_id: worker_id,
            last_validated_at: validated_at
          })
          |> Repo.insert!()

        %{binding: binding, outcome: :created}

      %HostedLocalRepositoryBinding{} = binding ->
        outcome = if binding.worker_id == worker_id, do: :retained, else: :replaced

        binding =
          binding
          |> HostedLocalRepositoryBinding.changeset(%{
            worker_id: worker_id,
            last_validated_at: validated_at
          })
          |> Repo.update!()

        %{binding: binding, outcome: outcome}
    end
  end

  defp worker_state(%LocalWorker{state: "active"} = worker, now) do
    if WorkerDiscovery.status([worker], now: now) == :detected,
      do: :connected,
      else: :temporarily_unavailable
  end

  defp worker_state(_worker, _now), do: :temporarily_unavailable

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
