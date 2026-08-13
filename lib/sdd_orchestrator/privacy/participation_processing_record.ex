defmodule SddOrchestrator.Privacy.ParticipationProcessingRecord do
  @moduledoc """
  One mechanically classified specs/26 (participation-data-protection-controls)
  field or transfer.

  Deliberately a separate struct from `SddOrchestrator.Privacy.DataProcessingRecord`
  rather than an extension of it, for the same reason specs/18 introduced
  `SddOrchestrator.Privacy.DeliveryProcessingRecord`: that struct holds
  hand-written free-text purpose/basis/retention prose per *activity*, with no
  fixed vocabulary a validator could check, and it inlines retention and rights
  handling that this specification must not own
  (`capability:participation-identity-lifecycle` remains authoritative for
  that). AC-01 requires every participation *field* to carry a purpose, basis,
  authority, recipient, processor, transfer classification, and lifecycle
  owner drawn from a closed set, so "no unclassified processing" can be
  verified by `validate/1` instead of by hand-written assertions. A dedicated
  struct also keeps the legacy records in
  `SddOrchestrator.Privacy.ProcessingInventory` and the specs/18 delivery
  records in `SddOrchestrator.Privacy.DeliveryProcessingInventory` untouched.

  This record is itself governance configuration: entity and field names plus
  classification atoms, never feature content, invited or participant email
  addresses, credentials, display names, project content, or provider
  payloads.

  ## Basis

  Business Rules give participation processing exactly two lawful-basis
  buckets: "User-requested invitation, proof, participation, notification, and
  rights processing is limited to contract necessity. Minimum fraud, abuse,
  security, audit, operations, and support processing is limited to its
  documented legitimate-interest purpose and assessment." Every field
  inventoried here belongs to the first bucket — invitation, authorization,
  presentation, revocation-handoff, and notification records that exist only
  to deliver the participant-requested collaboration service — so every
  record below is `:contract_necessity`. `:legitimate_interests` (named
  directly after the requirement's own "documented legitimate-interest
  purpose" wording) remains an approved basis value for a future
  participation operational-security-log inventory: specs/27
  (`participation-operational-retention`) owns exactly that fixed minimized
  security-event stream, and it is not an Ecto schema this task inventories.

  ## Authority

  Every schema classified here — `ProjectInvitation`, `ProjectParticipant`,
  `ProjectMemberProfile`, `ParticipationRevocation`, and
  `ParticipationEmailDelivery` — commits directly through
  `SddOrchestrator.Repo` with no device-authoritative counterpart; so does the
  shared `AccountNotification` foundation this specification reuses under its
  `participation.` namespace. Unlike specs/07 (guided delivery), which has a
  genuinely dual-store `Feature`/`AgentRun`/etc. lineage, no participation
  record has ever been device-authoritative — a device-authoritative project
  still collaborates through the same hosted `Participation` context (see
  `SddOrchestrator.Participation.Invitations`'s note that "a device-
  authoritative project has no hosted owner, so collaboration stays" hosted).
  `authorities/0` is therefore a single-member vocabulary, `:hosted`, rather
  than inventing an unused `:device` value with no real target.

  ## Recipient

  Business Rules describe four distinct participation-data audiences, not the
  single "current participants" bucket specs/18 used: "Owners receive only
  the membership-management data already approved for their project.
  Participants receive only their own account context and approved project
  labels." "Operations access is limited to necessary minimized service and
  security metadata. Support access is content-free by default..."
  `recipient_categories/0` keeps all four distinct so a completeness proof can
  tell an owner-only authorization record from a participant-facing
  presentation label, from operations-only diagnostic evidence, from a
  support boundary that carries no content by default.

  ## Processor And Transfer

  Every field stays inside the hosted database (`:hosted_database`,
  `:no_transfer`) except the two fields that genuinely leave the hosted
  store: `ProjectInvitation.delivery_email` and
  `ParticipationEmailDelivery.recipient_address`, which are addressed to the
  configured email-delivery processor already approved for passwordless
  access (`SddOrchestrator.Participation.EmailDelivery`) so an invitation,
  resend, cancellation, or removal notice can be sent. No participation field
  ever transfers a repository-provider, worker, coding-agent, model-provider,
  session, invitation, or email-delivery credential — the credential fields
  themselves (`email_digest`, `token_digest`, `token_salt`) never leave the
  hosted database and are never even shown to the owner who created the
  invitation.

  ## Lifecycle Owner

  Points at the specification responsible for *enforcing* removal or
  anonymization of the classified field, not at whichever specification first
  implemented it (most of these schemas were originally established by
  specs/08). `capability:participation-identity-lifecycle` (specs/25) is the
  authoritative re-invitation, departure, revocation-link,
  historical-attribution, verified-rights, deletion, and anonymization owner
  for `ProjectInvitation`, `ProjectParticipant`, `ProjectMemberProfile`, and
  `ParticipationRevocation` — see this specification's design.md. specs/27
  (`participation-operational-retention`, not yet implemented) will own the
  30-day `ParticipationEmailDelivery` diagnostic cleanup and the 90-day
  participation-namespace `AccountNotification` cleanup. specs/28
  (`participation-deletion-and-recovery`, not yet implemented) will own
  encrypted-backup expiry and derived-copy propagation once a participation
  identity link is deleted or anonymized elsewhere; no field below names it
  directly (backup expiry is not itself a schema field), but it remains an
  approved lifecycle-owner value, mirroring how the specs/18 inventory keeps
  `:specs_20_device_data_retention` approved with no field naming it.

  Retention *enforcement* is out of this task's scope by design: a
  `lifecycle_owner` here is a pointer to the specification responsible for
  enforcing it, not the enforcement itself.
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

  @type basis :: :contract_necessity | :legitimate_interests

  @type authority :: :hosted

  @type recipient_category ::
          :owner_membership_management
          | :participant_project_context
          | :minimized_operations
          | :exceptional_support

  @type processor_category :: :hosted_database | :email_delivery_provider

  @type transfer_classification :: :no_transfer | :configured_email_delivery

  @type lifecycle_owner ::
          :specs_25_participation_identity_lifecycle
          | :specs_27_participation_operational_retention
          | :specs_28_participation_deletion_and_recovery

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

  @bases ~w(contract_necessity legitimate_interests)a
  @authorities ~w(hosted)a
  @recipient_categories ~w(
    owner_membership_management
    participant_project_context
    minimized_operations
    exceptional_support
  )a
  @processor_categories ~w(hosted_database email_delivery_provider)a
  @transfer_classifications ~w(no_transfer configured_email_delivery)a
  @lifecycle_owners ~w(
    specs_25_participation_identity_lifecycle
    specs_27_participation_operational_retention
    specs_28_participation_deletion_and_recovery
  )a

  @doc "The approved lawful bases: the participant-requested service, or documented legitimate interest."
  @spec bases() :: [basis()]
  def bases, do: @bases

  @doc "The approved authoritative-store classification for a participation field: hosted only."
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

  @doc "The approved lifecycle-owner references. None enforce retention here; specs/25, 27, and 28 do."
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
