defmodule SddOrchestrator.Devices.DeviceStore.Local do
  @moduledoc """
  Development and verification `DeviceStore` adapter.

  Persists the accountless device workspace and its projects on the local host
  with DETS, standing in for the release-gated native worker. Durability makes
  "stable access under the same operating-system boundary" and "data loss"
  distinct events: a lost store (a deleted file) yields a fresh workspace with no
  projects, so reconnecting a repository starts new history rather than restoring
  it.

  All writes are serialized through this GenServer, so registration is atomic.
  Nothing here writes device-authoritative data to the hosted database.
  """

  @behaviour SddOrchestrator.Devices.DeviceStore

  use GenServer

  alias SddOrchestrator.Accounts.{DeviceWorkspace, Workspace}
  alias SddOrchestrator.Devices.DeviceProject
  alias SddOrchestrator.Projects.Project

  @workspace_key :device_workspace

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def establish_workspace, do: GenServer.call(__MODULE__, :establish_workspace)

  @impl SddOrchestrator.Devices.DeviceStore
  def get_workspace, do: GenServer.call(__MODULE__, :get_workspace)

  @impl SddOrchestrator.Devices.DeviceStore
  def register_project(attrs, opts),
    do: GenServer.call(__MODULE__, {:register_project, attrs, opts})

  @impl SddOrchestrator.Devices.DeviceStore
  def list_projects, do: GenServer.call(__MODULE__, :list_projects)

  @impl SddOrchestrator.Devices.DeviceStore
  def get_project(id), do: GenServer.call(__MODULE__, {:get_project, id})

  @impl SddOrchestrator.Devices.DeviceStore
  def find_by_fingerprint(fingerprint),
    do: GenServer.call(__MODULE__, {:find_by_fingerprint, fingerprint})

  @impl GenServer
  # The store path is trusted application configuration — a fixed dev/config value
  # or a test-supplied temporary path — never web or user input, so `File.mkdir_p!`
  # here is not a directory-traversal vector. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    table = Keyword.get(opts, :table, __MODULE__)
    File.mkdir_p!(Path.dirname(path))
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(:get_workspace, _from, state) do
    {:reply, fetch_workspace(state.table), state}
  end

  def handle_call(:establish_workspace, _from, state) do
    reply =
      case fetch_workspace(state.table) do
        {:ok, workspace} -> {:ok, workspace}
        {:error, :not_found} -> create_workspace(state.table)
      end

    {:reply, reply, state}
  end

  def handle_call(:list_projects, _from, state) do
    {:reply, all_projects(state.table), state}
  end

  def handle_call({:get_project, id}, _from, state) do
    reply =
      case :dets.lookup(state.table, {:project, id}) do
        [{{:project, ^id}, project}] -> {:ok, project}
        [] -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:find_by_fingerprint, fingerprint}, _from, state) do
    reply =
      case Enum.find(all_projects(state.table), &(&1.repository_fingerprint == fingerprint)) do
        nil -> {:error, :not_found}
        project -> {:ok, project}
      end

    {:reply, reply, state}
  end

  def handle_call({:register_project, attrs, opts}, _from, state) do
    {:reply, do_register(state.table, attrs, opts), state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = :dets.close(state.table)
    :ok
  end

  # ---- workspace ----

  defp fetch_workspace(table) do
    case :dets.lookup(table, @workspace_key) do
      [{@workspace_key, id}] -> {:ok, %DeviceWorkspace{id: id}}
      [] -> {:error, :not_found}
    end
  end

  defp create_workspace(table) do
    with {:ok, root} <- Workspace.device_root(),
         {:ok, workspace} <- DeviceWorkspace.from_workspace(root) do
      :ok = :dets.insert(table, {@workspace_key, workspace.id})
      :ok = :dets.sync(table)
      {:ok, workspace}
    end
  end

  # ---- projects ----

  defp all_projects(table) do
    fun = fn
      {{:project, _id}, %DeviceProject{} = project}, acc -> [project | acc]
      _other, acc -> acc
    end

    :dets.foldl(fun, [], table) |> Enum.sort_by(& &1.name)
  end

  defp do_register(table, attrs, opts) do
    name = get(attrs, :name)
    fingerprint = get(attrs, :repository_fingerprint)
    status = get(attrs, :status) || "connected"
    idempotency_key = get(attrs, :idempotency_key)
    projects = all_projects(table)

    # Idempotent commit and lost-acknowledgement reconciliation: a registration
    # carrying an already-committed attempt key resolves to the same project
    # rather than creating a duplicate. Checked before repository uniqueness so a
    # retry of the same registration is never mistaken for a duplicate link.
    case find_by_key(projects, idempotency_key) do
      {:ok, existing} ->
        {:ok, existing}

      :error ->
        with {:ok, valid_name} <- validate_name(name),
             :ok <- validate_fingerprint(fingerprint),
             :ok <- check_repository_unique(projects, fingerprint),
             {:ok, final_name} <-
               resolve_name(projects, valid_name, Keyword.get(opts, :allocate_suffix?, false)) do
          project = %DeviceProject{
            id: Ecto.UUID.generate(),
            name: final_name,
            name_key: Project.name_key(final_name),
            repository_fingerprint: fingerprint,
            status: status,
            storage_mode: "device",
            idempotency_key: idempotency_key,
            inserted_at: now()
          }

          :ok = :dets.insert(table, {{:project, project.id}, project})
          :ok = :dets.sync(table)
          {:ok, project}
        end
    end
  end

  defp find_by_key(_projects, nil), do: :error

  defp find_by_key(projects, key) do
    case Enum.find(projects, &(&1.idempotency_key == key)) do
      nil -> :error
      project -> {:ok, project}
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :invalid_name}
      Regex.match?(~r/\p{Cc}/u, trimmed) -> {:error, :invalid_name}
      true -> {:ok, trimmed}
    end
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  defp validate_fingerprint(fingerprint) when is_binary(fingerprint) and fingerprint != "",
    do: :ok

  defp validate_fingerprint(_fingerprint), do: {:error, :fingerprint_required}

  defp check_repository_unique(projects, fingerprint) do
    case Enum.find(projects, &(&1.repository_fingerprint == fingerprint)) do
      nil -> :ok
      existing -> {:error, {:repository_already_linked, existing}}
    end
  end

  defp resolve_name(projects, name, allocate?) do
    keys = MapSet.new(projects, & &1.name_key)
    key = Project.name_key(name)

    cond do
      key not in keys -> {:ok, name}
      allocate? -> {:ok, next_suffixed(name, keys, 1)}
      true -> {:error, :name_taken}
    end
  end

  defp next_suffixed(base, keys, n) do
    candidate = "#{base}-#{n}"

    if Project.name_key(candidate) in keys,
      do: next_suffixed(base, keys, n + 1),
      else: candidate
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
