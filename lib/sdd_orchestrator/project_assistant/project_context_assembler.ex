defmodule SddOrchestrator.ProjectAssistant.ProjectContextAssembler do
  @moduledoc """
  Assembles the minimum current authoritative project context a project-
  assistant turn grounds ordinary questions in (AC-07), before any
  repository observation is considered.

  Hosted and device authorities read their own raw sources and revalidate
  the acting participant's current authorization on every call — nothing
  here caches an authorization result across calls, matching every other
  project-assistant surface. Both authorities minimize through the same
  `ProjectContextAssembler.Shared` rules, so `content` is shaped identically
  regardless of storage mode.

  This module owns no write path: it composes only already-published
  read capabilities (`capability:project-specification-store`'s
  `SpecificationStore.current_snapshot/2` and
  `capability:guided-delivery-data-surfaces`'s `DeliveryStore` reads) and
  never a delivery command, a specification revision append, or a
  conversation write.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.ParticipantGuard

  alias SddOrchestrator.ProjectAssistant.ProjectContextAssembler.{Device, Hosted}

  @type actor :: ParticipantGuard.actor()
  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type assembled :: %{content: map(), context_version: String.t()}

  @doc """
  Assembles one project's current context for the acting participant.

  Returns `{:error, :unauthorized}` for a stale, absent, removed, or
  cross-project identity, or for a project the given authority does not
  itself own — the same fail-closed, no-existence-disclosure contract every
  other project-assistant read uses.
  """
  @spec assemble(authority(), String.t(), actor()) :: {:ok, assembled()} | {:error, :unauthorized}
  def assemble(%PersonalWorkspace{} = authority, project_id, actor),
    do: Hosted.assemble(authority, project_id, actor)

  def assemble(%DeviceWorkspace{} = authority, project_id, actor),
    do: Device.assemble(authority, project_id, actor)

  def assemble(_authority, _project_id, _actor), do: {:error, :unauthorized}
end
