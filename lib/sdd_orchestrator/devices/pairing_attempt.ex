defmodule SddOrchestrator.Devices.PairingAttempt do
  @moduledoc """
  One short-lived attempt to pair a worker to an accountless device workspace.

  The raw pairing code is never stored; only a salted digest, the opaque
  device-workspace id, and lifecycle timestamps are persisted. An attempt is
  single-use: once confirmed or canceled it can no longer complete a pairing.

  An attempt has exactly two valid shapes.

  A *bound* attempt carries the device workspace it belongs to. This is the
  original shape, still produced by `Pairing.start_pairing/2` for the dashboard
  and the `Open in App` deep link, where the workspace is known before the code
  is issued.

  An *unbound* attempt carries no workspace at all. It exists because a worker
  app that has never been paired has no workspace identity to name — acquiring
  one is what pairing is for. An unbound attempt authorizes nothing: it names no
  person, no machine, and no workspace, and its whole content is a random digest
  and an expiry. It becomes bound once, when an authorized owner redeems its
  code against their own workspace (`specs/38` Task 2).

  The third combination — confirmed, or holding a worker, while belonging to no
  workspace — is a credential attached to nobody. It is unreachable by database
  constraint rather than by convention, so no code path can produce it.
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

  @doc "Changeset for issuing a new pairing attempt bound to a known workspace."
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:device_workspace_id, :code_digest, :code_salt, :expires_at])
    |> validate_required([:device_workspace_id, :code_digest, :code_salt, :expires_at])
  end

  @doc """
  Changeset for issuing a pairing attempt that belongs to no workspace yet.

  `:device_workspace_id` is not in the cast list, so a caller cannot smuggle one
  in through the attrs map. An unbound attempt is unbound because nothing may
  name a workspace at this point, not because the caller chose to omit it.
  """
  def create_unbound_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:code_digest, :code_salt, :expires_at])
    |> validate_required([:code_digest, :code_salt, :expires_at])
    |> check_constraint(:device_workspace_id,
      name: :pairing_attempts_bound_before_use_check,
      message: "an unbound attempt cannot be confirmed or hold a worker"
    )
  end
end
