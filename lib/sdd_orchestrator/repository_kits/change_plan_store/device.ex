defmodule SddOrchestrator.RepositoryKits.ChangePlanStore.Device do
  @moduledoc "Device-local change-plan-store adapter."

  @behaviour SddOrchestrator.RepositoryKits.ChangePlanStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.RepositoryKits.RepositoryKitChangePlan

  @impl true
  def create({:device, %DeviceWorkspace{} = authority}, %{project_id: project_id} = attrs) do
    with {:ok, _project} <- authorize(authority, project_id),
         {:ok, plan} <- RepositoryKitChangePlan.build(stamp_inserted_at(attrs)),
         {:ok, stored_value} <-
           Devices.append_repository_kit_change_plan(
             project_id,
             RepositoryKitChangePlan.to_value(plan)
           ) do
      RepositoryKitChangePlan.from_value(stored_value)
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def create(_authority, _attrs), do: {:error, :unsupported_authority}

  @impl true
  def current({:device, %DeviceWorkspace{} = authority}, project_id, now) do
    case authorize(authority, project_id) do
      {:ok, _project} ->
        project_id
        |> Devices.list_repository_kit_change_plans()
        |> Enum.reduce_while([], &collect_plan/2)
        |> most_recent_unexpired(now)

      _missing ->
        {:error, :not_found}
    end
  end

  def current(_viewer, _project_id, _now), do: {:error, :not_found}

  @impl true
  def get({:device, %DeviceWorkspace{} = authority}, project_id, plan_id) do
    case authorize(authority, project_id) do
      {:ok, _project} ->
        project_id
        |> Devices.list_repository_kit_change_plans()
        |> Enum.reduce_while([], &collect_plan/2)
        |> find_by_id(plan_id)

      _missing ->
        {:error, :not_found}
    end
  end

  def get(_authority, _project_id, _plan_id), do: {:error, :not_found}

  defp find_by_id(plans, plan_id) do
    case Enum.find(plans, &(&1.id == plan_id)) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end

  # `attrs` never carries `inserted_at` (`RepositoryKits.persist_plan/7`
  # never sets it) — the hosted path gets it for free from Ecto's own
  # `timestamps()` exclusively at `Repo.insert` time, which this device path
  # never reaches. It is stamped here instead, exactly once, before the
  # value is ever built or serialized, mirroring how
  # `RepositoryExecutionProfile.approved/4` stamps its own `inserted_at` for
  # its in-memory-only construction path.
  defp stamp_inserted_at(attrs) do
    Map.put(attrs, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
  end

  # One unreadable stored plan discards the whole listing, mirroring
  # `ProfileStore.Device`'s own fail-closed `collect_profile/2` reducer, so a
  # tampered or truncated device record can never surface a partial history.
  defp collect_plan(value, plans) do
    case RepositoryKitChangePlan.from_value(value) do
      {:ok, plan} -> {:cont, [plan | plans]}
      {:error, :invalid_plan} -> {:halt, []}
    end
  end

  # "Current" is the most recent non-expired plan — the same rule
  # `ChangePlanStore.Hosted`'s SQL query encodes, computed here in Elixir
  # since a device store has no query engine to push the filter into.
  defp most_recent_unexpired(plans, now) do
    plans
    |> Enum.filter(&(DateTime.compare(&1.expires_at, now) == :gt))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> case do
      [current | _rest] -> {:ok, current}
      [] -> {:error, :not_found}
    end
  end

  defp authorize(%DeviceWorkspace{id: authority_id} = authority, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device", status: "connected"} = project} <-
           Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(authority, project) do
      {:ok, project}
    else
      _missing -> {:error, :not_found}
    end
  end
end
