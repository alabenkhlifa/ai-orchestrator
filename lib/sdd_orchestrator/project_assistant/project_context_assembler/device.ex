defmodule SddOrchestrator.ProjectAssistant.ProjectContextAssembler.Device do
  @moduledoc """
  Device-authority raw reads for `ProjectContextAssembler`.

  A device-authoritative project has no hosted owner or participant
  (`SddOrchestrator.Participation.owner/1`), so `Delivery.ParticipantGuard`
  always denies it, the same reason Task 1's `ProjectAssistantStore.Device`
  and `capability:project-specification-store`'s own `SpecificationStore.Device`
  authorize the acting device workspace directly instead of routing through
  a participation boundary. This module draws the identical split: there is
  only ever one possible participant, the device workspace that owns this
  local store, reverified fresh on every read.

  `SddOrchestrator.Delivery.Features.board/2` and `SddOrchestrator.Delivery.Activity`
  are hosted-only (a direct Postgres `Feature`/`ActivityEntry` query gated by
  the hosted-only participation boundary), so board and recent-run status are
  read here through the authority-dispatching `SddOrchestrator.Delivery.DeliveryStore`
  functions instead — the same published `capability:guided-delivery-data-surfaces`
  read surface `SddOrchestrator.Delivery.RevocationConsumer` already consumes
  directly for both authorities.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.{ActivityEntry, DeliveryStore}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.ProjectAssistant.ProjectContextAssembler.Shared
  alias SddOrchestrator.SpecificationStore

  @spec assemble(DeviceWorkspace.t(), String.t(), map()) ::
          {:ok, %{content: map(), context_version: String.t()}} | {:error, :unauthorized}
  def assemble(%DeviceWorkspace{} = authority, project_id, actor) do
    with {:ok, project} <- authorize(authority, project_id, actor),
         {:ok, snapshot} <- SpecificationStore.current_snapshot(authority, project_id) do
      features = DeliveryStore.list_features(authority, project_id, [])
      evidence = DeliveryStore.list_evidence(authority, project_id, current: true)

      {content, version} =
        Shared.build(
          project_metadata(project),
          Shared.specification_entries(snapshot),
          Shared.board_by_column(features),
          recent_runs(authority, project_id, features),
          Enum.map(Shared.current_evidence(evidence), &Shared.evidence_entry/1)
        )

      {:ok, %{content: content, context_version: version}}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  @doc """
  Revalidates that the given device workspace is the current device
  identity and that this project is device-authoritative.

  `ProjectContextStore` reuses this for `get/3` and `delete/3`, matching
  `Hosted.authorize/3`'s contract: a stored projection is never read past
  the exact authorization checked when it was built.
  """
  @spec authorize(DeviceWorkspace.t(), String.t(), map()) ::
          {:ok, term()} | {:error, :unauthorized}
  def authorize(%DeviceWorkspace{id: authority_id}, project_id, _actor) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"} = project} <- Devices.get_project(project_id) do
      {:ok, project}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  defp project_metadata(project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "storage_mode" => project.storage_mode,
      # A device project has no separate lifecycle state; its connection
      # status is the closest analogous "is this project current" signal, so
      # it is normalized into the same content key the hosted authority uses.
      "lifecycle_state" => project.status
    }
  end

  defp recent_runs(authority, project_id, features) do
    Enum.flat_map(features, fn feature ->
      case current_run(authority, project_id, feature.id) do
        {:ok, run} -> [Shared.run_entry(feature.id, run)]
        :none -> []
      end
    end)
  end

  defp current_run(authority, project_id, feature_id) do
    with run_id when is_binary(run_id) <-
           authority
           |> DeliveryStore.list_activity(project_id, feature_id, [])
           |> last_run_id(),
         {:ok, run} <- DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, run}
    else
      _absent -> :none
    end
  end

  defp last_run_id(entries) do
    entries
    |> Enum.filter(&(&1.type == "run_started"))
    |> List.last()
    |> case do
      nil -> nil
      %ActivityEntry{} = entry -> entry.run_id
    end
  end
end
