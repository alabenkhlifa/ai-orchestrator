defmodule SddOrchestrator.Privacy.DeliverySupportElevation do
  @moduledoc """
  One verified, purpose-bound, time-bounded, least-privilege support-elevation
  grant (specs/18 Task 2, AC-03).

  Exceptional support access is separate from participant authorization
  (`SddOrchestrator.Delivery.ParticipantGuard`) and disabled by default: a grant
  is scoped to exactly one project's incident, carries one purpose from a fixed,
  closed vocabulary, and defaults to `scope: :metadata`. A caller must
  explicitly elevate `scope` to `:content` for a grant to ever authorize a
  guided-delivery content read — see
  `SddOrchestrator.Privacy.DeliverySupportAccess.authorize_content_read/2`.

  A grant's expiry is required and bounded (at most 24 hours from issue),
  enforced by both the changeset and a database check constraint, so "time-
  bounded" is a property of the row rather than a promise a caller keeps.
  Revocation and expiry are recorded on the same row rather than by deleting
  it, so a denied caller and an auditor see the same history.

  Nothing here stores guided-delivery content: no feature title, comment body,
  evidence, project name, or participant email. It names only an operations
  account, a project, a purpose atom, a scope atom, and the grant's own
  lifecycle timestamps.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Projects.Project

  @purposes ~w(incident_diagnosis security_investigation)a
  @scopes ~w(metadata content)a
  @max_duration_seconds 86_400

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "delivery_support_elevations" do
    field :purpose, Ecto.Enum, values: @purposes
    field :scope, Ecto.Enum, values: @scopes, default: :metadata
    field :issued_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :operations_account, Account, foreign_key: :operations_account_id
    belongs_to :project, Project
    belongs_to :revoked_by_account, Account, foreign_key: :revoked_by_account_id

    timestamps()
  end

  @doc "The closed, mechanically checkable purpose vocabulary."
  @spec purposes() :: [atom()]
  def purposes, do: @purposes

  @doc "The closed access-level vocabulary. `:metadata` is the default, disabled-by-default level."
  @spec scopes() :: [atom()]
  def scopes, do: @scopes

  @doc "The longest duration a single grant may cover, in seconds."
  @spec max_duration_seconds() :: pos_integer()
  def max_duration_seconds, do: @max_duration_seconds

  @doc """
  Issues one elevation grant. `scope` defaults to `:metadata` when omitted, so
  omitting it can never accidentally authorize a content read. `expires_at` is
  required and must be strictly after `issued_at` (defaulted to now when
  omitted) and no more than #{@max_duration_seconds} seconds later.
  """
  @spec issue_changeset(t(), map()) :: Ecto.Changeset.t()
  def issue_changeset(%__MODULE__{} = elevation, attrs) do
    elevation
    |> cast(attrs, [
      :operations_account_id,
      :project_id,
      :purpose,
      :scope,
      :issued_at,
      :expires_at
    ])
    |> put_default_issued_at()
    |> put_default_scope()
    |> validate_required([
      :operations_account_id,
      :project_id,
      :purpose,
      :scope,
      :issued_at,
      :expires_at
    ])
    |> validate_inclusion(:purpose, @purposes)
    |> validate_inclusion(:scope, @scopes)
    |> validate_bounded_expiry()
    |> check_constraint(:purpose, name: :delivery_support_elevations_purpose_allowed)
    |> check_constraint(:scope, name: :delivery_support_elevations_scope_allowed)
    |> check_constraint(:expires_at, name: :delivery_support_elevations_bounded_expiry)
    |> check_constraint(:revoked_at, name: :delivery_support_elevations_revocation_pairing)
    |> foreign_key_constraint(:operations_account_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc "Revokes one elevation immediately, recording who revoked it."
  @spec revoke_changeset(t(), map()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = elevation, attrs) do
    elevation
    |> cast(attrs, [:revoked_at, :revoked_by_account_id])
    |> put_default_revoked_at()
    |> validate_required([:revoked_at, :revoked_by_account_id])
    |> validate_not_already_revoked()
    |> check_constraint(:revoked_at, name: :delivery_support_elevations_revocation_pairing)
    |> foreign_key_constraint(:revoked_by_account_id)
  end

  @doc """
  Reports whether the grant is currently valid at `at`: not revoked and not
  expired. Neither branch discloses which reason a caller should expect; that
  is the authorization boundary's job, not this predicate's.
  """
  @spec valid_at?(t(), DateTime.t()) :: boolean()
  def valid_at?(%__MODULE__{revoked_at: nil, expires_at: expires_at}, at) do
    DateTime.compare(at, expires_at) == :lt
  end

  def valid_at?(%__MODULE__{}, _at), do: false

  @doc "Reports whether the grant's scope authorizes a content read."
  @spec content_scope?(t()) :: boolean()
  def content_scope?(%__MODULE__{scope: :content}), do: true
  def content_scope?(%__MODULE__{}), do: false

  defp put_default_issued_at(changeset) do
    case get_field(changeset, :issued_at) do
      nil -> put_change(changeset, :issued_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp put_default_revoked_at(changeset) do
    case get_field(changeset, :revoked_at) do
      nil -> put_change(changeset, :revoked_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp put_default_scope(changeset) do
    case get_field(changeset, :scope) do
      nil -> put_change(changeset, :scope, :metadata)
      _present -> changeset
    end
  end

  defp validate_bounded_expiry(changeset) do
    issued_at = get_field(changeset, :issued_at)
    expires_at = get_field(changeset, :expires_at)

    cond do
      is_nil(issued_at) or is_nil(expires_at) ->
        changeset

      DateTime.compare(expires_at, issued_at) != :gt ->
        add_error(changeset, :expires_at, "must be after issued_at")

      DateTime.diff(expires_at, issued_at, :second) > @max_duration_seconds ->
        add_error(
          changeset,
          :expires_at,
          "must be within #{@max_duration_seconds} seconds of issue"
        )

      true ->
        changeset
    end
  end

  defp validate_not_already_revoked(changeset) do
    if is_nil(changeset.data.revoked_at) do
      changeset
    else
      add_error(changeset, :revoked_at, "is already recorded")
    end
  end
end
