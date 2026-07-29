defmodule SddOrchestrator.Participation.ParticipationEmailDelivery do
  @moduledoc """
  One minimized invitation or participation email-delivery result.

  The record keeps the smallest evidence needed to explain and retry delivery:
  the event, its subject and version, the encrypted recipient address, the
  outcome, and a short failure code. Invitation credentials, message bodies,
  provider responses, and project content are never stored here.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Encrypted

  @event_types ~w(invitation invitation_resent invitation_canceled participant_removed)
  @statuses ~w(pending sent failed)
  @failure_codes ~w(delivery_failed invalid_recipient provider_unavailable)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [:id, :event_type, :subject_ref, :event_version, :status, :failure_code]}

  @type t :: %__MODULE__{}

  schema "participation_email_deliveries" do
    field :event_type, :string
    field :subject_ref, Ecto.UUID
    field :event_version, :integer, default: 1
    field :recipient_address, Encrypted.Binary, redact: true
    field :status, :string, default: "pending"
    field :failure_code, :string
    field :attempted_at, :utc_datetime
    field :delivered_at, :utc_datetime

    timestamps()
  end

  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec failure_codes() :: [String.t()]
  def failure_codes, do: @failure_codes

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :event_type,
      :subject_ref,
      :event_version,
      :recipient_address,
      :status,
      :failure_code,
      :attempted_at,
      :delivered_at
    ])
    |> put_default(:event_version, 1)
    |> put_default(:status, "pending")
    |> put_default(:attempted_at, now())
    |> validate_required([
      :event_type,
      :subject_ref,
      :event_version,
      :recipient_address,
      :status,
      :attempted_at
    ])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_failure_code()
    |> validate_number(:event_version, greater_than: 0)
    |> unique_constraint([:event_type, :subject_ref, :event_version],
      name: :participation_email_deliveries_event_subject_index,
      message: "was already attempted for this event"
    )
    |> check_constraint(:status, name: :participation_email_deliveries_status_allowed)
  end

  @spec sent?(t()) :: boolean()
  def sent?(%__MODULE__{status: "sent"}), do: true
  def sent?(%__MODULE__{}), do: false

  defp validate_failure_code(changeset) do
    case get_field(changeset, :failure_code) do
      nil ->
        changeset

      code ->
        validate_inclusion(
          put_change(changeset, :failure_code, code),
          :failure_code,
          @failure_codes
        )
    end
  end

  defp put_default(changeset, field, default) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, default),
      else: changeset
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
