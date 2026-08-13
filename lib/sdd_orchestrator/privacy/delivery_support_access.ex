defmodule SddOrchestrator.Privacy.DeliverySupportAccess do
  @moduledoc """
  Issues, authorizes, and revokes exceptional guided-delivery support access
  (specs/18 Task 2, AC-03).

  This is the whole exceptional-support boundary. It is separate from
  participant authorization (`SddOrchestrator.Delivery.ParticipantGuard` is the
  ordinary, unrelated path every content read otherwise uses) and never
  substitutes for it. A grant that exists is not itself a content
  authorization: only an elevation that is bound to the requested project,
  explicitly `:content`-scoped (never the `:metadata` default), not revoked,
  and not expired authorizes a content read.

  `authorize_content_read/2` fails closed and does not disclose *why* a caller
  was denied. An absent elevation id, a malformed elevation id, an elevation
  bound to a different project, a metadata-only elevation, a revoked
  elevation, and an expired elevation all return the identical
  `{:error, :unauthorized}` — mirroring `ParticipantGuard.authorize/2`'s own
  non-disclosure guarantee. The audit trail still records the real internal
  reason (for operational diagnosis), but that reason never reaches the denied
  caller's return value.
  """

  alias Ecto.Changeset
  alias SddOrchestrator.Privacy.{DeliverySupportAudit, DeliverySupportElevation}
  alias SddOrchestrator.Repo

  @type id :: Ecto.UUID.t() | term()

  @doc "The closed purpose vocabulary a grant may be issued for."
  @spec purposes() :: [atom()]
  def purposes, do: DeliverySupportElevation.purposes()

  @doc "The closed scope vocabulary. `:metadata` is the disabled-by-default level."
  @spec scopes() :: [atom()]
  def scopes, do: DeliverySupportElevation.scopes()

  @doc """
  Issues one verified support-elevation grant.

  Refuses an unapproved purpose or scope and a missing or unbounded expiry
  (enforced by `DeliverySupportElevation.issue_changeset/2`). `scope` defaults
  to `:metadata` when omitted, so a caller can never accidentally issue a
  content-authorizing grant by leaving a field out.
  """
  @spec issue(map()) :: {:ok, DeliverySupportElevation.t()} | {:error, Changeset.t()}
  def issue(attrs) do
    changeset = DeliverySupportElevation.issue_changeset(%DeliverySupportElevation{}, attrs)

    case Repo.insert(changeset) do
      {:ok, elevation} ->
        audit(:issue, :granted, elevation)
        {:ok, elevation}

      {:error, invalid_changeset} ->
        DeliverySupportAudit.event(:issue, %{
          outcome: :rejected,
          reason: :invalid_grant,
          project_id: safe_id(Changeset.get_field(invalid_changeset, :project_id)),
          operations_account_id:
            safe_id(Changeset.get_field(invalid_changeset, :operations_account_id)),
          purpose: Changeset.get_field(invalid_changeset, :purpose),
          scope: Changeset.get_field(invalid_changeset, :scope)
        })

        {:error, invalid_changeset}
    end
  end

  @doc """
  Authorizes one content read against one currently valid, content-scoped,
  non-revoked, non-expired elevation bound to `project_id`.

  See the moduledoc for the full non-disclosure guarantee this makes.
  """
  @spec authorize_content_read(id(), id()) ::
          {:ok, DeliverySupportElevation.t()} | {:error, :unauthorized}
  def authorize_content_read(project_id, elevation_id) do
    case fetch(elevation_id) do
      {:ok, %DeliverySupportElevation{project_id: ^project_id} = elevation} ->
        decide_content_read(elevation)

      {:ok, %DeliverySupportElevation{} = elevation} ->
        deny(:authorize, elevation, :wrong_project)

      :error ->
        DeliverySupportAudit.event(:authorize, %{
          outcome: :denied,
          reason: :not_found,
          elevation_id: safe_id(elevation_id),
          project_id: safe_id(project_id)
        })

        {:error, :unauthorized}
    end
  end

  @doc """
  Revokes one elevation immediately. `{:error, :not_found}` for an absent or
  malformed id; `{:error, changeset}` when the grant is already revoked.
  """
  @spec revoke(id(), id()) ::
          {:ok, DeliverySupportElevation.t()} | {:error, :not_found | Changeset.t()}
  def revoke(elevation_id, revoked_by_account_id) do
    case fetch(elevation_id) do
      {:ok, elevation} ->
        elevation
        |> DeliverySupportElevation.revoke_changeset(%{
          revoked_at: DateTime.utc_now(),
          revoked_by_account_id: revoked_by_account_id
        })
        |> Repo.update()
        |> finish_revoke(elevation, revoked_by_account_id)

      :error ->
        DeliverySupportAudit.event(:revoke, %{
          outcome: :denied,
          reason: :not_found,
          elevation_id: safe_id(elevation_id)
        })

        {:error, :not_found}
    end
  end

  defp decide_content_read(%DeliverySupportElevation{} = elevation) do
    cond do
      not DeliverySupportElevation.content_scope?(elevation) ->
        deny(:authorize, elevation, :metadata_only)

      not is_nil(elevation.revoked_at) ->
        deny(:authorize, elevation, :revoked)

      not DeliverySupportElevation.valid_at?(elevation, DateTime.utc_now()) ->
        deny(:authorize, elevation, :expired)

      true ->
        audit(:authorize, :granted, elevation)
        {:ok, elevation}
    end
  end

  defp finish_revoke({:ok, revoked}, _elevation, _revoked_by_account_id) do
    audit(:revoke, :granted, revoked)
    {:ok, revoked}
  end

  defp finish_revoke({:error, changeset}, elevation, revoked_by_account_id) do
    DeliverySupportAudit.event(:revoke, %{
      outcome: :rejected,
      reason: :invalid_revocation,
      elevation_id: elevation.id,
      project_id: elevation.project_id,
      revoked_by_account_id: safe_id(revoked_by_account_id)
    })

    {:error, changeset}
  end

  defp deny(:authorize, elevation, reason) do
    audit(:authorize, :denied, elevation, reason)
    {:error, :unauthorized}
  end

  defp audit(event, outcome, elevation, reason \\ nil) do
    DeliverySupportAudit.event(event, %{
      outcome: outcome,
      reason: reason,
      elevation_id: elevation && elevation.id,
      project_id: elevation && elevation.project_id,
      operations_account_id: elevation && elevation.operations_account_id,
      purpose: elevation && elevation.purpose,
      scope: elevation && elevation.scope
    })
  end

  defp fetch(id) do
    with true <- is_binary(id),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %DeliverySupportElevation{} = elevation <- Repo.get(DeliverySupportElevation, uuid) do
      {:ok, elevation}
    else
      _absent_or_malformed -> :error
    end
  end

  defp safe_id(id) when is_binary(id), do: id
  defp safe_id(_id), do: nil
end
