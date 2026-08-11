defmodule SddOrchestrator.RepositoryKits.InstallationStore.Device do
  @moduledoc "Device-local installation-store adapter."

  @behaviour SddOrchestrator.RepositoryKits.InstallationStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.RepositoryKits.RepositoryKitInstallation

  @impl true
  def create({:device, %DeviceWorkspace{} = authority}, %{project_id: project_id} = attrs) do
    with {:ok, _project} <- authorize(authority, project_id),
         {:ok, installation} <- RepositoryKitInstallation.build(stamp_created_at(attrs)),
         {:ok, stored_value} <-
           Devices.put_repository_kit_installation(
             project_id,
             RepositoryKitInstallation.to_value(installation)
           ) do
      RepositoryKitInstallation.from_value(stored_value)
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def create(_authority, _attrs), do: {:error, :unsupported_authority}

  @impl true
  def transition({:device, %DeviceWorkspace{} = authority}, project_id, attrs) do
    with {:ok, _project} <- authorize(authority, project_id),
         {:ok, current} <- read_raw(project_id),
         {:ok, installation} <- RepositoryKitInstallation.build(merge_transition(current, attrs)),
         {:ok, stored_value} <-
           Devices.put_repository_kit_installation(
             project_id,
             RepositoryKitInstallation.to_value(installation)
           ) do
      RepositoryKitInstallation.from_value(stored_value)
    else
      {:error, :not_found} -> {:error, :not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  def transition(_authority, _project_id, _attrs), do: {:error, :unsupported_authority}

  @impl true
  def current({:device, %DeviceWorkspace{} = authority}, project_id) do
    case authorize(authority, project_id) do
      {:ok, _project} -> read_raw(project_id)
      _missing -> {:error, :not_found}
    end
  end

  def current(_viewer, _project_id), do: {:error, :not_found}

  @impl true
  def raw({:device, %DeviceWorkspace{}}, project_id), do: read_raw(project_id)
  def raw(_authority, _project_id), do: {:error, :not_found}

  defp read_raw(project_id) do
    case Devices.get_repository_kit_installation(project_id) do
      {:ok, value} -> installation_or_not_found(RepositoryKitInstallation.from_value(value))
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp installation_or_not_found({:ok, installation}), do: {:ok, installation}
  defp installation_or_not_found({:error, :invalid_installation}), do: {:error, :not_found}

  # `attrs` never carries `inserted_at`/`updated_at` (`RepositoryKits.persist_install_installation/5`
  # never sets them) — the hosted path gets both for free from Ecto's own
  # `timestamps()` exclusively at `Repo.insert` time, which this device path
  # never reaches. Both are stamped here instead, exactly once, before the
  # value is ever built or serialized, mirroring
  # `ChangePlanStore.Device.create/2`'s own `stamp_inserted_at/1`.
  defp stamp_created_at(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Map.merge(attrs, %{inserted_at: now, updated_at: now})
  end

  # `attrs` (built by `RepositoryKits.persist_transition_installation/6`) is
  # the same partial "current state" field map the hosted path casts through
  # `RepositoryKitInstallation.update_changeset/2` — it never carries `:id`,
  # `:project_id`, or `:inserted_at`, since none of those change across a
  # transition. `build/1` needs the complete `@value_fields` shape, so this
  # restores the three unchanged identity/creation fields from the current
  # stored value and stamps a fresh `updated_at` — a transition changes
  # `updated_at`, never `inserted_at`, exactly like a hosted row's
  # `inserted_at` never changes across an `UPDATE`.
  defp merge_transition(%RepositoryKitInstallation{} = current, attrs) do
    attrs
    |> Map.merge(%{
      id: current.id,
      project_id: current.project_id,
      inserted_at: current.inserted_at,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end

  # The same three checks `ChangePlanStore.Device`'s own `authorize/2` makes:
  # the device workspace exists and matches, the project is a connected
  # device project, and the project belongs to that workspace.
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
