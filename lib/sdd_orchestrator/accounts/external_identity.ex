defmodule SddOrchestrator.Accounts.ExternalIdentity do
  @moduledoc """
  A verified sign-in method attached to one stable hosted identity.

  The case-insensitive comparison key is kept separate from the spelling used
  for delivery and display. Personal identifiers are intentionally excluded
  from struct inspection.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @providers ~w(email github)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect, only: [:id, :provider, :hosted_identity_id, :verified_at]}

  @type t :: %__MODULE__{}
  @type normalized_email :: %{display_identifier: String.t(), subject_key: String.t()}

  schema "external_identities" do
    field :provider, :string
    field :subject_key, :string, redact: true
    field :display_identifier, :string, redact: true
    field :verified_at, :utc_datetime

    belongs_to :hosted_identity, SddOrchestrator.Accounts.HostedIdentity

    timestamps()
  end

  @doc """
  Trims an email and returns its preserved display spelling plus the
  case-insensitive identity key.
  """
  @spec normalize_email(term()) :: {:ok, normalized_email()} | {:error, :invalid_email}
  def normalize_email(email) when is_binary(email) do
    display_identifier = String.trim(email)

    if valid_email?(display_identifier) do
      {:ok,
       %{
         display_identifier: display_identifier,
         subject_key: String.downcase(display_identifier)
       }}
    else
      {:error, :invalid_email}
    end
  end

  def normalize_email(_email), do: {:error, :invalid_email}

  @doc false
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :provider,
      :subject_key,
      :display_identifier,
      :verified_at,
      :hosted_identity_id
    ])
    |> validate_required([
      :provider,
      :subject_key,
      :display_identifier,
      :verified_at,
      :hosted_identity_id
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_length(:subject_key, max: 320)
    |> validate_length(:display_identifier, max: 320)
    |> validate_email_key()
    |> unique_constraint([:provider, :subject_key],
      name: :external_identities_provider_subject_key_index
    )
    |> unique_constraint([:hosted_identity_id, :provider],
      name: :external_identities_hosted_identity_provider_index
    )
    |> foreign_key_constraint(:hosted_identity_id)
  end

  defp validate_email_key(changeset) do
    case get_field(changeset, :provider) do
      "email" -> validate_email_fields(changeset)
      _other -> changeset
    end
  end

  defp validate_email_fields(changeset) do
    case normalize_email(get_field(changeset, :display_identifier)) do
      {:ok, %{subject_key: key}} -> validate_subject_key(changeset, key)
      {:error, :invalid_email} -> add_error(changeset, :display_identifier, "is not valid")
    end
  end

  defp validate_subject_key(changeset, expected_key) do
    if expected_key == get_field(changeset, :subject_key) do
      changeset
    else
      add_error(changeset, :subject_key, "does not match the verified email")
    end
  end

  defp valid_email?(email) do
    email != "" and
      byte_size(email) <= 320 and
      Regex.match?(~r/^[^\s@]+@[^\s@]+$/u, email)
  end
end
