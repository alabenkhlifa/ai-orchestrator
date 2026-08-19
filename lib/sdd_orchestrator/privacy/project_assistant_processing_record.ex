defmodule SddOrchestrator.Privacy.ProjectAssistantProcessingRecord do
  @moduledoc """
  One mechanically classified specs/12 (project-assistant) field.

  A deliberately separate struct from `SddOrchestrator.Privacy.DeliveryProcessingRecord`
  rather than a reuse of it: project-assistant's own contract has no
  `:current_participants` recipient at all for its participant-private
  entities (`ProjectAssistantConversation`, `ProjectAssistantTurn`,
  `ProjectAssistantCitation`, `AssistantBoundaryConfirmation` are each
  visible only to the one participant they belong to — design.md: "The
  owner, another participant, an assignee, a reviewer, and operations
  personnel cannot read another participant's assistant conversation merely
  because they can read the project"), and it has one recipient and
  transfer classification delivery's contract never needs at all: the
  participant's own configured personal AI connection, the one external
  transfer this feature makes (mirroring
  `SddOrchestrator.Privacy.AIRuntimeDataUsePolicy`'s reasoning for why a
  model provider is treated as a distinct, narrowly-scoped recipient rather
  than folded into a generic "processor" bucket).

  This record is itself governance configuration: entity and field names
  plus classification atoms, never conversation content, prompts, answers,
  citations, source excerpts, or credentials.
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

  @type basis :: :contract_necessity

  @type authority :: :hosted | :device | :both

  @type recipient_category ::
          :owning_participant | :current_participants | :model_provider

  @type processor_category ::
          :hosted_database | :hosted_database_or_device_worker

  @type transfer_classification :: :no_transfer | :configured_model_provider

  @type lifecycle_owner :: :specs_12_project_assistant_lifecycle

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

  @bases ~w(contract_necessity)a
  @authorities ~w(hosted device both)a
  @recipient_categories ~w(owning_participant current_participants model_provider)a
  @processor_categories ~w(hosted_database hosted_database_or_device_worker)a
  @transfer_classifications ~w(no_transfer configured_model_provider)a
  @lifecycle_owners ~w(specs_12_project_assistant_lifecycle)a

  @doc "The one approved lawful basis: the participant's own requested question."
  @spec bases() :: [basis()]
  def bases, do: @bases

  @doc "The approved authoritative-store classifications for a project-assistant field."
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

  @doc "The approved lifecycle-owner references. specs/12 Task 9 enforces removal for every field."
  @spec lifecycle_owners() :: [lifecycle_owner()]
  def lifecycle_owners, do: @lifecycle_owners

  @doc """
  Validates one record against the fixed classification vocabulary.

  Returns `:ok` when every classification is present and an approved member
  of its enum; otherwise `{:error, [reason, ...]}` naming every field that
  failed, not just the first.
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
