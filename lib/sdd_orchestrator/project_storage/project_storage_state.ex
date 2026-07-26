defmodule SddOrchestrator.ProjectStorage.ProjectStorageState do
  @moduledoc """
  The logical authoritative storage state for one project.

  No second mode-bearing row is persisted. The state is derived from
  `Project.storage_mode`, its owning `Workspace.kind`, and the destination-specific
  detail: one `HostedProjectStorage` row for hosted projects or the
  `:device_authoritative` marker supplied by device persistence.
  """

  alias SddOrchestrator.Accounts.Workspace
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage
  alias SddOrchestrator.ProjectStorage.StorageMode

  @enforce_keys [:workspace_id, :workspace_kind, :storage_mode, :adapter_state]
  defstruct [:workspace_id, :workspace_kind, :storage_mode, :adapter_state]

  @type adapter_state :: HostedProjectStorage.t() | :device_authoritative
  @type t :: %__MODULE__{
          workspace_id: Ecto.UUID.t(),
          workspace_kind: StorageMode.t(),
          storage_mode: StorageMode.t(),
          adapter_state: adapter_state()
        }

  @doc "Derives and validates the authoritative state from destination records."
  @spec from_project(map(), Workspace.t(), adapter_state()) ::
          {:ok, t()}
          | {:error,
             :workspace_mismatch
             | :storage_mode_mismatch
             | :hosted_storage_required
             | :device_state_required}
  def from_project(
        %{id: project_id, workspace_id: workspace_id, storage_mode: mode},
        %Workspace{id: workspace_id, kind: kind},
        adapter_state
      ) do
    with true <- StorageMode.compatible?(mode, kind),
         {:ok, normalized_mode} <- StorageMode.cast(mode),
         :ok <- validate_adapter(normalized_mode, project_id, adapter_state) do
      {:ok,
       %__MODULE__{
         workspace_id: workspace_id,
         workspace_kind: kind,
         storage_mode: normalized_mode,
         adapter_state: adapter_state
       }}
    else
      false -> {:error, :storage_mode_mismatch}
      :error -> {:error, :storage_mode_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_project(_project, %Workspace{}, _adapter_state), do: {:error, :workspace_mismatch}

  defp validate_adapter(
         "hosted",
         project_id,
         %HostedProjectStorage{project_id: project_id}
       ),
       do: :ok

  defp validate_adapter("hosted", _project_id, _adapter_state),
    do: {:error, :hosted_storage_required}

  defp validate_adapter("device", _project_id, :device_authoritative), do: :ok

  defp validate_adapter("device", _project_id, _adapter_state),
    do: {:error, :device_state_required}
end
