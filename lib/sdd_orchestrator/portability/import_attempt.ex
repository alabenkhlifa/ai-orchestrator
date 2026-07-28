defmodule SddOrchestrator.Portability.ImportAttempt do
  @moduledoc """
  Short-lived encrypted restore intake bound to one authorized destination.

  Hosted attempts use the database field-encryption type. Device attempts use
  the same value shape but remain in the device store under its operating-system
  boundary, with the encrypted package additionally sealed by the local vault.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [
             :id,
             :workspace_id,
             :device_workspace_id,
             :destination,
             :status,
             :expires_at,
             :inserted_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "import_attempts" do
    field :device_workspace_id, :binary_id
    field :destination, :string
    field :status, :string, default: "uploaded"
    field :encrypted_package, SddOrchestrator.Encrypted.Binary, redact: true
    field :expires_at, :utc_datetime

    belongs_to :workspace, SddOrchestrator.Accounts.Workspace

    timestamps()
  end

  @doc "Builds a hosted restore intake bound to one persisted workspace."
  def hosted_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:workspace_id, :destination, :status, :encrypted_package, :expires_at])
    |> validate_required([:workspace_id, :destination, :status, :encrypted_package, :expires_at])
    |> validate_inclusion(:destination, ["hosted"])
    |> validate_inclusion(:status, ["uploaded", "validating"])
    |> foreign_key_constraint(:workspace_id)
    |> check_constraint(:destination, name: :import_attempt_authority_shape)
    |> check_constraint(:status, name: :import_attempt_status)
  end

  @doc "Builds a device restore intake without a hosted workspace association."
  def device_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :device_workspace_id,
      :destination,
      :status,
      :encrypted_package,
      :expires_at
    ])
    |> validate_required([
      :device_workspace_id,
      :destination,
      :status,
      :encrypted_package,
      :expires_at
    ])
    |> validate_inclusion(:destination, ["device"])
    |> validate_inclusion(:status, ["uploaded", "validating"])
  end

  @doc "Advances an authorized intake to transient validation."
  def validation_changeset(attempt) do
    change(attempt, status: "validating")
  end
end
