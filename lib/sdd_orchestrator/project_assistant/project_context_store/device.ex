defmodule SddOrchestrator.ProjectAssistant.ProjectContextStore.Device do
  @moduledoc """
  The worker-owned adapter for a device-authoritative project's stored
  context projection.

  Goes through the same generic device-delivery seam every other
  device-authoritative record uses (`SddOrchestrator.Devices.commit_delivery/2`
  and friends), keyed by the project id itself — there is exactly one
  projection per device-authoritative project, the device equivalent of the
  hosted table's `unique_index` on `project_id`.

  Deletion replaces the stored projection with a tombstone rather than
  deleting a key, the same treatment `ProjectAssistantStore.Device` gives a
  deleted conversation: a tombstone carries no content, so every read treats
  it as absent and a later refresh starts a fresh version count rather than
  restoring stale content.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.ProjectAssistant.DeviceProjectContextProjection
  alias SddOrchestrator.ProjectAssistant.ProjectContextAssembler

  @tombstone %{"deleted" => true}

  @spec refresh(DeviceWorkspace.t(), String.t(), map()) ::
          {:ok, DeviceProjectContextProjection.t()} | {:error, :unauthorized | term()}
  def refresh(%DeviceWorkspace{} = authority, project_id, actor) do
    with {:ok, assembled} <- ProjectContextAssembler.assemble(authority, project_id, actor) do
      upsert(project_id, assembled)
    end
  end

  @spec get(DeviceWorkspace.t(), String.t(), map()) ::
          {:ok, DeviceProjectContextProjection.t() | nil} | {:error, :unauthorized}
  def get(%DeviceWorkspace{} = authority, project_id, actor) do
    with {:ok, _project} <-
           ProjectContextAssembler.Device.authorize(authority, project_id, actor) do
      {:ok, current(project_id)}
    end
  end

  @spec delete(DeviceWorkspace.t(), String.t(), map()) :: :ok | {:error, :unauthorized}
  def delete(%DeviceWorkspace{} = authority, project_id, actor) do
    with {:ok, _project} <-
           ProjectContextAssembler.Device.authorize(authority, project_id, actor) do
      do_delete(project_id)
    end
  end

  defp do_delete(project_id) do
    case Devices.get_delivery(project_id, :project_context_projection, project_id) do
      {:ok, value} ->
        Devices.commit_delivery(project_id, [
          {:put, :project_context_projection, project_id, @tombstone, value["state_version"]}
        ])

        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  # One project, one record: re-assembling replaces the single current
  # projection instead of accumulating stale history, the same idempotent
  # replace-in-place shape the hosted adapter's upsert uses.
  defp upsert(project_id, %{content: content, context_version: version}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    existing = current(project_id)

    projection = %DeviceProjectContextProjection{
      id: project_id,
      project_id: project_id,
      context_version: version,
      content: content,
      refreshed_at: now,
      state_version: next_version(existing),
      inserted_at: (existing && existing.inserted_at) || now,
      updated_at: now
    }

    value = DeviceProjectContextProjection.to_value(projection)
    expected = existing && existing.state_version

    case Devices.commit_delivery(project_id, [
           {:put, :project_context_projection, project_id, value, expected}
         ]) do
      {:ok, _applied} -> {:ok, projection}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_version(nil), do: 1
  defp next_version(%DeviceProjectContextProjection{state_version: version}), do: version + 1

  defp current(project_id) do
    case Devices.get_delivery(project_id, :project_context_projection, project_id) do
      {:ok, value} ->
        case DeviceProjectContextProjection.from_value(value) do
          {:ok, projection} -> projection
          {:error, _reason} -> nil
        end

      {:error, :not_found} ->
        nil
    end
  end
end
