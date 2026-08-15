defmodule SddOrchestrator.ProjectAssistant.DeviceConversationPurge do
  @moduledoc """
  Purges every device-authoritative project-assistant record for one project
  being deleted (specs/12 Task 9, AC-21's "project deletion" clause).

  ## The gap this closes

  Hosted project deletion already removes every project-assistant table
  through database cascade alone: `project_assistant_conversations`,
  `project_assistant_turns`, `project_assistant_citations`,
  `assistant_boundary_confirmations`, and `project_context_projections` all
  declare `on_delete: :delete_all` on their `project_id` foreign key (see
  each migration), and `SddOrchestrator.Specifications.SpecificationLifecycle.delete_project/2`'s
  hosted branch is exactly `Repo.delete(project)` — no code in this module
  is needed for the hosted path, and none is added.

  The device-authoritative path has no such cascade. Investigation of
  `SddOrchestrator.Devices.DeviceStore.Local`'s `do_delete_project/2` found
  that it sweeps a fixed, explicit list of DETS key tags
  (`:specification`, `:repository_assessment`,
  `:repository_assessment_proposal_envelope`, `:repository_execution_profile`,
  `:repository_kit_change_plan`, plus three singleton keys) and never
  touches the generic `{:delivery, project_id, kind, id}` key shape
  `SddOrchestrator.Devices.commit_delivery/2` writes through at all. Every
  project-assistant device record (`:project_assistant_conversation`,
  `:project_assistant_turn`, `:project_assistant_citation`,
  `:assistant_boundary_confirmation`, `:project_context_projection`) uses
  that generic delivery seam, so `Devices.delete_project/1` alone leaves
  every one of them orphaned in the DETS table after a device project is
  deleted.

  This is a genuine, pre-existing gap — but it is not specific to
  project-assistant. `SddOrchestrator.Delivery` (guided delivery, specs/07)
  writes features, comments, runs, and evidence through the exact same
  generic delivery seam and would be left orphaned by the identical defect.
  Fixing the sweep generically inside `device_store/local.ex` would
  silently also change specs/07's own already-verified, already-merged
  deletion behavior without that specification's own agreement or task
  tracking the change — squarely another specification's territory. This
  module therefore purges only the five project-assistant delivery kinds it
  owns, using only `SddOrchestrator.Devices`' already-public
  `list_delivery/2` and `commit_delivery/2` API — no change to
  `device_store/local.ex` or any other shared Devices internals. The
  underlying generic-sweep gap for every other device-delivery domain
  remains open and is recorded as a follow-up in
  `specs/12-project-assistant/progress.md`, owned by whichever
  specification governs `SddOrchestrator.Devices`' device-project-deletion
  contract (or `SddOrchestrator.Delivery`'s own device-deletion lifecycle),
  not by this task.

  ## Ordering

  Called before `SddOrchestrator.Specifications.SpecificationLifecycle.delete_project/2`
  removes the `{:project, project_id}` key: `Devices.commit_delivery/2`
  itself never checks whether the project row still exists (it only checks
  each delivery key's own expected version), so calling this before or
  after would both work mechanically, but running it first keeps every
  project-assistant device write inside the project's still-valid lifetime
  rather than issuing writes against an already-deleted project.
  """

  alias SddOrchestrator.Devices

  @kinds ~w(
    project_assistant_conversation
    project_assistant_turn
    project_assistant_citation
    assistant_boundary_confirmation
    project_context_projection
  )a

  @tombstone %{"deleted" => true}

  @doc """
  Tombstones every project-assistant device record for one project.
  Idempotent: a project with no project-assistant records purges nothing.
  Returns the count purged per kind.
  """
  @spec purge(String.t()) :: %{atom() => non_neg_integer()}
  def purge(project_id) when is_binary(project_id) do
    Map.new(@kinds, fn kind -> {kind, purge_kind(project_id, kind)} end)
  end

  defp purge_kind(project_id, kind) do
    project_id
    |> Devices.list_delivery(kind)
    |> Enum.reject(&(&1["deleted"] == true))
    |> Enum.map(&purge_one(project_id, kind, &1))
    |> Enum.count(&(&1 == :ok))
  end

  defp purge_one(project_id, kind, %{"id" => id} = value) do
    case Devices.commit_delivery(project_id, [
           {:put, kind, id, @tombstone, value["state_version"]}
         ]) do
      {:ok, _applied} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp purge_one(_project_id, _kind, _value), do: :error
end
