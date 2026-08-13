defmodule SddOrchestrator.Privacy.DeliveryProcessingRecord do
  @moduledoc """
  One mechanically classified Slice 07 (guided-delivery) field or transfer.

  Deliberately a separate struct from `SddOrchestrator.Privacy.DataProcessingRecord`
  rather than an extension of it: that struct holds hand-written free-text
  purpose/basis/retention prose per *activity*, with no fixed vocabulary a
  validator could check. AC-01 requires every Slice 07 *field* to carry a
  purpose, basis, authority, recipients, processors, transfer classification,
  and lifecycle owner drawn from a closed set, so "no unclassified processing"
  can be verified by `validate/1` instead of by hand-written assertions. A
  dedicated struct also keeps the 27 already-approved legacy records
  (`SddOrchestrator.Privacy.ProcessingInventory`) untouched.

  This record is itself governance configuration: entity and field names plus
  classification atoms, never feature text, source content, prompts, outputs,
  evidence bytes, credentials, participant emails, or provider payloads.
  """

  @enforce_keys [
    :entity,
    :field,
    :purpose,
    :basis,
    :authority,
    :recipient_category,
    :processor_category,
    :transfer_classification,
    :lifecycle_owner
  ]
  defstruct @enforce_keys

  @type basis :: :contract_necessity | :operational_security

  @type authority :: :hosted | :device | :both

  @type recipient_category ::
          :current_participants | :worker_or_provider_capability | :operations_support

  @type processor_category ::
          :hosted_database | :hosted_database_or_device_worker | :preview_provider

  @type transfer_classification ::
          :no_transfer | :hosted_relay_transient | :configured_remote_capability

  @type lifecycle_owner ::
          :specs_17_notification_access
          | :specs_19_operational_retention
          | :specs_20_device_data_retention
          | :specs_21_deletion_and_recovery

  @type t :: %__MODULE__{
          entity: atom(),
          field: atom(),
          purpose: String.t(),
          basis: basis(),
          authority: authority(),
          recipient_category: recipient_category(),
          processor_category: processor_category(),
          transfer_classification: transfer_classification(),
          lifecycle_owner: lifecycle_owner()
        }

  @bases ~w(contract_necessity operational_security)a
  @authorities ~w(hosted device both)a
  @recipient_categories ~w(current_participants worker_or_provider_capability operations_support)a
  @processor_categories ~w(hosted_database hosted_database_or_device_worker preview_provider)a
  @transfer_classifications ~w(no_transfer hosted_relay_transient configured_remote_capability)a
  @lifecycle_owners ~w(
    specs_17_notification_access
    specs_19_operational_retention
    specs_20_device_data_retention
    specs_21_deletion_and_recovery
  )a

  @doc "The approved lawful bases: the participant-requested service, or documented service security."
  @spec bases() :: [basis()]
  def bases, do: @bases

  @doc "The approved authoritative-store classifications for a Slice 07 field."
  @spec authorities() :: [authority()]
  def authorities, do: @authorities

  @doc "The approved recipient categories."
  @spec recipient_categories() :: [recipient_category()]
  def recipient_categories, do: @recipient_categories

  @doc "The approved processor categories."
  @spec processor_categories() :: [processor_category()]
  def processor_categories, do: @processor_categories

  @doc "The approved transfer classifications."
  @spec transfer_classifications() :: [transfer_classification()]
  def transfer_classifications, do: @transfer_classifications

  @doc "The approved lifecycle-owner references. None enforce retention here; specs/19-21 do."
  @spec lifecycle_owners() :: [lifecycle_owner()]
  def lifecycle_owners, do: @lifecycle_owners

  @doc """
  Validates one record against the fixed classification vocabulary.

  Returns `:ok` when every classification is present and an approved member of
  its enum; otherwise `{:error, [reason, ...]}` naming every field that failed,
  not just the first, so a caller sees the whole defect at once.
  """
  @spec validate(t()) :: :ok | {:error, [atom()]}
  def validate(%__MODULE__{} = record) do
    reasons =
      []
      |> check(blank?(record.entity), :entity)
      |> check(blank?(record.field), :field)
      |> check(blank?(record.purpose), :purpose)
      |> check(record.basis not in @bases, :basis)
      |> check(record.authority not in @authorities, :authority)
      |> check(record.recipient_category not in @recipient_categories, :recipient_category)
      |> check(record.processor_category not in @processor_categories, :processor_category)
      |> check(
        record.transfer_classification not in @transfer_classifications,
        :transfer_classification
      )
      |> check(record.lifecycle_owner not in @lifecycle_owners, :lifecycle_owner)

    if reasons == [], do: :ok, else: {:error, Enum.reverse(reasons)}
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_atom(value), do: false
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp check(reasons, true, reason), do: [reason | reasons]
  defp check(reasons, false, _reason), do: reasons
end
