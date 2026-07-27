defmodule SddOrchestrator.Devices.LocalWorker do
  @moduledoc """
  A device worker paired to one accountless device workspace.

  Persists only pairing and authorization metadata — a per-worker credential
  digest and salt, the opaque device-workspace id, coarse compatibility
  descriptors, and lifecycle state — never device-authoritative project data. The
  raw credential is returned once at pairing and lives only in the worker's
  operating-system keychain.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @states ~w(active revoked)

  @derive {Inspect,
           only: [
             :id,
             :device_workspace_id,
             :state,
             :os_family,
             :os_major,
             :app_version,
             :protocol_version,
             :last_seen_at,
             :revoked_at
           ]}

  @type t :: %__MODULE__{}

  schema "local_workers" do
    field :device_workspace_id, :binary_id
    field :credential_digest, :binary, redact: true
    field :credential_salt, :binary, redact: true
    field :os_family, :string
    field :os_major, :string
    field :app_version, :string
    field :protocol_version, :string
    field :state, :string, default: "active"
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps()
  end

  @doc "Changeset for a newly paired worker."
  def create_changeset(worker, attrs) do
    worker
    |> cast(attrs, [
      :device_workspace_id,
      :credential_digest,
      :credential_salt,
      :os_family,
      :os_major,
      :app_version,
      :protocol_version,
      :state
    ])
    |> validate_required([:device_workspace_id, :credential_digest, :credential_salt, :state])
    |> validate_inclusion(:state, @states)
  end

  @doc "Changeset for rotating the per-worker credential in place."
  def rotate_changeset(worker, attrs) do
    worker
    |> cast(attrs, [:credential_digest, :credential_salt])
    |> validate_required([:credential_digest, :credential_salt])
  end

  @doc "Changeset that revokes the worker credential."
  def revoke_changeset(worker, revoked_at) do
    change(worker, state: "revoked", revoked_at: revoked_at)
  end

  @doc "The persisted worker states."
  def states, do: @states
end
