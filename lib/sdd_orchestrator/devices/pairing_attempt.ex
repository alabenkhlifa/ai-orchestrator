defmodule SddOrchestrator.Devices.PairingAttempt do
  @moduledoc """
  One short-lived attempt to pair a worker to an accountless device workspace.

  The raw pairing code is never stored; only a salted digest, the opaque
  device-workspace id, and lifecycle timestamps are persisted. An attempt is
  single-use: once confirmed or canceled it can no longer complete a pairing.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [:id, :device_workspace_id, :expires_at, :confirmed_at, :canceled_at, :worker_id]}

  @type t :: %__MODULE__{}

  schema "pairing_attempts" do
    field :device_workspace_id, :binary_id
    field :code_digest, :binary, redact: true
    field :code_salt, :binary, redact: true
    field :expires_at, :utc_datetime
    field :confirmed_at, :utc_datetime
    field :canceled_at, :utc_datetime
    field :worker_id, :binary_id

    timestamps()
  end

  @doc "Changeset for issuing a new pairing attempt."
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:device_workspace_id, :code_digest, :code_salt, :expires_at])
    |> validate_required([:device_workspace_id, :code_digest, :code_salt, :expires_at])
  end
end
