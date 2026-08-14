defmodule SddOrchestrator.Privacy.ParticipationBackupLifecycle do
  @moduledoc """
  Enforces the participation-specific encrypted-backup lifecycle and
  tombstone-first recovery ordering (specs/28 Task 1, AC-01).

  ## The 35-day/encrypted/recovery-only contract is not duplicated here

  `SddOrchestrator.Privacy.DeploymentPrivacyProfile` already owns one
  deployment-wide encrypted-backup lifecycle contract
  (`backup_lifecycle_contract/0`, `backup_handoff/1`): encrypted, a 35-day
  maximum expiry, recovery-only restore scope, and required deletion
  propagation. `contract/0` and `recovery_handoff/0` below simply read that
  contract, so participation can never assert a second, drifting version of
  it. Real encrypted-backup storage, encryption, and expiry enforcement are
  deployment infrastructure's job and remain release-gate evidence — see
  `DeploymentPrivacyProfile`'s `enforcement: :deployment_infrastructure,
  evidence_stage: :release`. This module does not, and cannot, prove that
  live infrastructure locally.

  ## What this module does prove locally: tombstones before restored data

  Design's "Tombstones Before Restored Data" decision is the one part of
  AC-01 that *is* deterministically provable without live backup
  infrastructure: a permitted recovery read inside the 35-day window must
  never resurrect a participation identity link that the primary store has
  already removed or anonymized, even when the recovered content still
  carries the old, stale value.

  `recover/5` always resolves the *current* row for the requested entity —
  `SddOrchestrator.Participation.ProjectParticipant`, `ProjectMemberProfile`,
  or `ParticipationRevocation`, all authoritative and read-only, owned by
  specs/08, specs/25, and specs/26 — before it ever considers the supplied
  `backup_snapshot`. A currently tombstoned row always wins: recovery is
  refused outright and the identity fields returned never come from
  `backup_snapshot`, only from the current primary-store row. This adds no
  new authoritative participation entity and no persisted tombstone log —
  the tombstone check is a read-time query against rows that already exist,
  never a second copy of participation identity data.

  ## Recovery-only, and closed to product and ordinary support reads

  Recovery is reachable only through the same exceptional participation
  support-access boundary specs/26 Task 3 established
  (`SddOrchestrator.Privacy.ParticipationSupportAccess`), and only when that
  grant is currently valid, bound to the requested project, and explicitly
  `:content`-scoped. There is no second access-control mechanism here:
  ordinary product reads never call this module at all, and an ordinary
  (default `:metadata`-scope) support grant is refused by the same
  non-disclosing `{:error, :unauthorized}` any other unauthorized content
  read receives.
  """

  alias SddOrchestrator.Participation.{
    ParticipationRevocation,
    ProjectMemberProfile,
    ProjectParticipant
  }

  alias SddOrchestrator.Privacy.{DeploymentPrivacyProfile, ParticipationSupportAccess}
  alias SddOrchestrator.Repo

  @type entity :: :project_participant | :project_member_profile | :participation_revocation

  @entities [:project_participant, :project_member_profile, :participation_revocation]

  @doc """
  The participation backup lifecycle contract, read straight from
  `DeploymentPrivacyProfile.backup_lifecycle_contract/0` so the two can never
  drift.
  """
  @spec contract() :: %{
          encrypted: true,
          maximum_expiry_days: pos_integer(),
          restore_scope: :approved_recovery_only,
          deletion_propagation: :required,
          enforcement: :deployment_infrastructure,
          evidence_stage: :release
        }
  def contract, do: DeploymentPrivacyProfile.backup_lifecycle_contract()

  @doc "The lifecycle handoff attached to a participation recovery read."
  @spec recovery_handoff() :: %{
          action: :access,
          maximum_expiry_days: pos_integer(),
          restore_scope: :approved_recovery_only,
          deletion_propagation: :required
        }
  def recovery_handoff, do: DeploymentPrivacyProfile.backup_handoff(:access)

  @doc "The maximum encrypted-backup lifetime, in days, participation data may age within."
  @spec maximum_expiry_days() :: pos_integer()
  def maximum_expiry_days, do: contract().maximum_expiry_days

  @doc """
  Recovers one participation identity link, applying tombstone-first
  ordering.

  `entity` names which primary-store schema `entity_id` refers to, and
  `entity_id` is scoped to `project_id`. `backup_snapshot` stands in for the
  content a real encrypted rolling backup would return for that row before
  restore-time filtering: there is no backup storage in this codebase to
  read from, so a caller-supplied map is the deterministic local stand-in.
  It is required to have the shape of backup content (a map), but its
  fields are never trusted for the identity data this function returns —
  see the moduledoc; that refusal to read from it is the ordering proof
  itself.

  Requires a currently valid, `:content`-scoped `ParticipationSupportAccess`
  elevation bound to `project_id`. An absent, malformed, wrong-project,
  `:metadata`-scope, expired, or revoked elevation is refused with the
  identical `{:error, :unauthorized}` the underlying boundary already
  returns, without disclosing which reason applied.

  Returns `{:ok, map}` describing the current, live identity link when the
  primary store still shows it active. Returns `{:error, :tombstoned}` when
  the primary store already shows the link removed or anonymized —
  regardless of what `backup_snapshot` contains. Returns
  `{:error, :not_found}` when `entity_id` does not resolve inside
  `project_id`.
  """
  @spec recover(entity(), Ecto.UUID.t(), Ecto.UUID.t(), map(), term()) ::
          {:ok, map()} | {:error, :tombstoned | :not_found | :unauthorized}
  def recover(entity, project_id, entity_id, backup_snapshot, elevation_id)
      when entity in @entities and is_map(backup_snapshot) do
    with {:ok, _elevation} <-
           ParticipationSupportAccess.authorize_content_read(project_id, elevation_id),
         {:ok, current} <- fetch_current(entity, project_id, entity_id) do
      resolve(entity, current)
    end
  end

  defp resolve(entity, current) do
    if tombstoned?(entity, current) do
      {:error, :tombstoned}
    else
      {:ok, live_identity_link(entity, current)}
    end
  end

  defp tombstoned?(:project_participant, %ProjectParticipant{hosted_identity_id: nil}), do: true
  defp tombstoned?(:project_participant, %ProjectParticipant{}), do: false

  defp tombstoned?(:project_member_profile, %ProjectMemberProfile{state: "anonymized"}),
    do: true

  defp tombstoned?(:project_member_profile, %ProjectMemberProfile{}), do: false

  defp tombstoned?(:participation_revocation, %ParticipationRevocation{} = revocation),
    do: ParticipationRevocation.acknowledged?(revocation)

  defp live_identity_link(:project_participant, %ProjectParticipant{} = current) do
    %{
      entity: :project_participant,
      id: current.id,
      state: current.state,
      hosted_identity_id: current.hosted_identity_id,
      source: :current_primary_store
    }
  end

  defp live_identity_link(:project_member_profile, %ProjectMemberProfile{} = current) do
    %{
      entity: :project_member_profile,
      id: current.id,
      state: current.state,
      account_id: current.account_id,
      source: :current_primary_store
    }
  end

  defp live_identity_link(:participation_revocation, %ParticipationRevocation{} = current) do
    %{
      entity: :participation_revocation,
      id: current.id,
      former_hosted_identity_id: current.former_hosted_identity_id,
      former_account_id: current.former_account_id,
      source: :current_primary_store
    }
  end

  defp fetch_current(:project_participant, project_id, id),
    do: fetch(ProjectParticipant, project_id, id)

  defp fetch_current(:project_member_profile, project_id, id),
    do: fetch(ProjectMemberProfile, project_id, id)

  defp fetch_current(:participation_revocation, project_id, id),
    do: fetch(ParticipationRevocation, project_id, id)

  defp fetch(schema, project_id, id) do
    with {:ok, project_uuid} <- Ecto.UUID.cast(project_id),
         {:ok, entity_uuid} <- Ecto.UUID.cast(id) do
      case Repo.get_by(schema, id: entity_uuid, project_id: project_uuid) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    else
      :error -> {:error, :not_found}
    end
  end
end
