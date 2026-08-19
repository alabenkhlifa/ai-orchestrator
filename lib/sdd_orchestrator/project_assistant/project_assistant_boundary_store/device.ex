defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantBoundaryStore.Device do
  @moduledoc """
  The worker-owned adapter for a device-authoritative project's boundary
  confirmation.

  Mirrors `SddOrchestrator.ProjectAssistant.ProjectAssistantStore.Device`
  exactly: nothing here reaches the hosted database, the acting identity is
  the device workspace that owns the local store (reverified fresh on every
  call), and the record is stored through the same generic device-delivery
  seam every other device-authoritative record uses, keyed by
  `:assistant_boundary_confirmation`.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.ProjectAssistant.{DeviceAssistantBoundaryConfirmation, Guard}

  @spec get_confirmation(DeviceWorkspace.t(), String.t(), Guard.actor()) ::
          {:ok, DeviceAssistantBoundaryConfirmation.t() | nil} | {:error, :unauthorized}
  def get_confirmation(%DeviceWorkspace{} = authority, project_id, _actor) do
    with {:ok, member} <- authorize(authority, project_id, :open_panel) do
      {:ok, fetch(project_id, member.workspace_id)}
    end
  end

  @spec confirm(
          DeviceWorkspace.t(),
          String.t(),
          Guard.actor(),
          String.t(),
          pos_integer(),
          DateTime.t()
        ) ::
          {:ok, DeviceAssistantBoundaryConfirmation.t()} | {:error, :unauthorized | term()}
  def confirm(
        %DeviceWorkspace{} = authority,
        project_id,
        _actor,
        boundary_digest,
        boundary_version,
        confirmed_at
      ) do
    with {:ok, member} <- authorize(authority, project_id, :confirm_boundary) do
      do_confirm(project_id, member.workspace_id, boundary_digest, boundary_version, confirmed_at)
    end
  end

  @doc """
  Immediately deletes the acting participant's own boundary confirmation, if
  any (specs/12 Task 9). Idempotent: deleting an absent confirmation still
  succeeds. Tombstones rather than removes a key, the same treatment every
  other device-authoritative project-assistant record gets.
  """
  @spec delete_confirmation(DeviceWorkspace.t(), String.t(), Guard.actor()) ::
          :ok | {:error, :unauthorized}
  def delete_confirmation(%DeviceWorkspace{} = authority, project_id, _actor) do
    with {:ok, member} <- authorize(authority, project_id, :delete) do
      do_delete(project_id, member.workspace_id)
    end
  end

  defp do_delete(project_id, workspace_id) do
    case Devices.get_delivery(project_id, :assistant_boundary_confirmation, workspace_id) do
      {:ok, value} ->
        Devices.commit_delivery(project_id, [
          {:put, :assistant_boundary_confirmation, workspace_id, %{"deleted" => true},
           value["state_version"]}
        ])

        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp authorize(%DeviceWorkspace{id: authority_id}, project_id, action) do
    with true <- action in Guard.protected_actions(),
         {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"}} <- Devices.get_project(project_id) do
      {:ok, %{workspace_id: authority_id}}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  defp fetch(project_id, workspace_id) do
    case Devices.get_delivery(project_id, :assistant_boundary_confirmation, workspace_id) do
      {:ok, value} ->
        case DeviceAssistantBoundaryConfirmation.from_value(value) do
          {:ok, confirmation} -> confirmation
          {:error, _reason} -> nil
        end

      {:error, :not_found} ->
        nil
    end
  end

  defp do_confirm(project_id, workspace_id, boundary_digest, boundary_version, confirmed_at) do
    {expected_version, new_version, inserted_at_iso} =
      case Devices.get_delivery(project_id, :assistant_boundary_confirmation, workspace_id) do
        {:ok, %{"state_version" => version, "inserted_at" => existing_inserted_at}}
        when is_integer(version) ->
          {version, version + 1, existing_inserted_at}

        _absent ->
          {nil, 1, DateTime.to_iso8601(confirmed_at)}
      end

    confirmation = %DeviceAssistantBoundaryConfirmation{
      id: workspace_id,
      project_id: project_id,
      workspace_id: workspace_id,
      boundary_digest: boundary_digest,
      boundary_version: boundary_version,
      confirmed_at: confirmed_at,
      state_version: new_version,
      inserted_at: parse_or(inserted_at_iso, confirmed_at),
      updated_at: confirmed_at
    }

    value = DeviceAssistantBoundaryConfirmation.to_value(confirmation)

    case Devices.commit_delivery(project_id, [
           {:put, :assistant_boundary_confirmation, workspace_id, value, expected_version}
         ]) do
      {:ok, _applied} -> {:ok, confirmation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_or(iso8601, fallback) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> fallback
    end
  end
end
