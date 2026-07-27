defmodule SddOrchestrator.Accounts.MagicLinkAttempt do
  @moduledoc """
  One short-lived passwordless authentication attempt.

  The raw credential is never stored. Email and protected credential fields are
  excluded from struct inspection so ordinary diagnostics expose only lifecycle
  state.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @delivery_statuses ~w(pending sent failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [
             :id,
             :delivery_status,
             :expires_at,
             :consumed_at,
             :invalidated_at,
             :failure_code
           ]}

  @type t :: %__MODULE__{}

  schema "magic_link_attempts" do
    field :token_digest, :binary, redact: true
    field :token_salt, :binary, redact: true
    field :email_key, :string, redact: true
    field :delivery_email, :string, redact: true
    field :delivery_status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime
    field :invalidated_at, :utc_datetime
    field :failure_code, :string

    timestamps()
  end

  @doc false
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :token_digest,
      :token_salt,
      :email_key,
      :delivery_email,
      :delivery_status,
      :expires_at,
      :consumed_at,
      :invalidated_at,
      :failure_code
    ])
    |> validate_required([
      :token_digest,
      :token_salt,
      :email_key,
      :delivery_email,
      :delivery_status,
      :expires_at
    ])
    |> validate_inclusion(:delivery_status, @delivery_statuses)
    |> validate_length(:email_key, max: 320)
    |> validate_length(:delivery_email, max: 320)
    |> unique_constraint(:token_digest)
    |> unique_constraint(:email_key, name: :magic_link_attempts_one_active_email_index)
    |> check_constraint(:delivery_status,
      name: :magic_link_attempts_delivery_status_check
    )
  end
end
