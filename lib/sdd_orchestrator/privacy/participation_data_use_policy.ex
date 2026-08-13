defmodule SddOrchestrator.Privacy.ParticipationDataUsePolicy do
  @moduledoc """
  Fail-closed purpose and recipient boundary for specs/26
  (participation-data-protection-controls) participation data (Task 5,
  AC-05).

  Mirrors `SddOrchestrator.Privacy.DeliveryDataUsePolicy`'s (specs/18 Task 4)
  exact shape: `authorize/3` refuses every `@prohibited_purposes` member and
  every `@prohibited_consumers` member unconditionally, before the
  per-entity `@allowed` map is even consulted, so a caller cannot construct
  a data class that legitimizes advertising, model training, unrelated
  product improvement, analytics, or identity tracking, or that routes data
  to an advertising network, analytics processor, or unrelated processor.
  Everything else is refused as `{:error, :not_authorized}` — an
  unrecognized data class, purpose, or consumer is never defaulted open.

  This policy covers the six entities classified field-by-field in
  `SddOrchestrator.Privacy.ParticipationProcessingInventory` (Task 1):
  `project_invitation`, `project_participant`, `project_member_profile`,
  `participation_revocation`, `participation_email_delivery`, and the
  `participation.`-namespace usage of the shared `AccountNotification`
  schema (`account_notification`).

  ## Purposes are coarser than Task 1's field classification

  Task 1 answers "what is this field's classification" (purpose, basis,
  authority, recipient, processor, transfer, lifecycle owner) per field.
  This module answers a different question — "is this purpose/consumer pair
  ever legitimate for this entity," regardless of which field within it
  carries the data — using purposes grounded directly in this
  specification's Business Rules:

    * `:membership_management` covers `project_invitation`,
      `project_participant`, and `participation_revocation`. Business Rules:
      "Owners receive only the membership-management data already approved
      for their project." Task 1 classifies every field of these three
      entities `:owner_membership_management` (no field override changes
      that recipient category), so the only legitimate human recipient for
      this purpose is the project owner.
    * `:participant_presentation` covers `project_member_profile`. Business
      Rules: "Participants receive only their own account context and
      approved project labels." Task 1 classifies every
      `project_member_profile` field `:participant_project_context` with no
      override, so its one legitimate recipient is the current participant
      viewing project labels.
    * `:notification_delivery` covers `account_notification`. Task 1
      classifies its fields `:participant_project_context`; this mirrors
      `DeliveryDataUsePolicy`'s identical `notification_delivery:
      [:current_participant]` route for the same shared schema under its
      `delivery.` namespace.
    * `:email_delivery` covers `project_invitation` and
      `participation_email_delivery`. Task 1's `@field_overrides` names
      exactly two fields that leave the hosted database:
      `ProjectInvitation.delivery_email` and
      `ParticipationEmailDelivery.recipient_address`, both classified
      `processor_category: :email_delivery_provider` /
      `transfer_classification: :configured_email_delivery`, addressed to
      the configured email-delivery processor already approved for
      passwordless access (`SddOrchestrator.Participation.EmailDelivery`).
    * `:operations_diagnostics` covers `participation_email_delivery`. Task
      1 classifies every field of this entity `:minimized_operations` by
      default (recipient_address's override changes only its processor and
      transfer classification, not its recipient category) — "operations
      access is limited to necessary minimized service and security
      metadata," and this entity exists only as delivery-attempt diagnostic
      evidence, never a participant-facing record. This mirrors
      `DeliveryDataUsePolicy`'s `processing_confirmation` /
      `:compliance_evidence` route for the same reason.
    * `:retention_cleanup` and `:verified_rights` are the universal
      lifecycle and rights routes every entity carries, identical in shape
      to `DeliveryDataUsePolicy`.

  ## `email_delivery_provider` is an ordinary consumer, not a blanket prohibition

  Like `DeliveryDataUsePolicy` treats `:model_provider` and
  `:preview_provider` as legitimate only through one narrow route rather
  than blanket-prohibiting them, `:email_delivery_provider` here is
  legitimate only through the `:email_delivery` purpose for
  `project_invitation` and `participation_email_delivery` — the two entities
  Task 1 actually classifies as leaving the hosted store. It is refused for
  every other purpose and every other entity by the same fail-closed
  `@allowed` lookup every other consumer is subject to, and it is refused
  outright for `:advertising` or `:model_training` because `authorize/3`
  checks the purpose before the consumer is even inspected.

  ## Task 5 authorizes a purpose; Task 4 authorizes a destination

  `SddOrchestrator.Privacy.ParticipationContentBoundary.authorize_destination/3`
  (Task 4) answers "is this one classified *field* allowed to reach this one
  *processor destination*," cross-referenced directly against the Task 1
  inventory. This module answers a different, complementary question — "is
  this *purpose*, for this *entity*, ever legitimate for this *consumer*" —
  independent of which specific field carries it. Task 4 stops an
  unapproved field from crossing a boundary; this module stops an approved
  field from being repurposed once it has legitimately crossed one.

  ## Anonymous aggregate boundary

  `@anonymous_aggregate_boundary` names the current prohibition and the
  minimum contract any future participation measurement proposal would have
  to satisfy. Its `prohibited_identifiers` list is taken verbatim from this
  specification's own design.md ("Aggregate measurement cannot contain or
  be grouped by account, identity, email or digest, project, workspace,
  invitation, participant, notification, repository, device, network,
  session, or another stable or singling-out identifier") — it is
  deliberately not `DeliveryDataUsePolicy`'s list, which names different
  entities (`feature`, `run`, `worker`, `provider`) that do not exist in
  this specification's domain.
  """

  @prohibited_purposes [
    :advertising,
    :analytics,
    :identity_tracking,
    :model_training,
    :unrelated_product_improvement
  ]

  @prohibited_consumers [
    :advertising_network,
    :analytics_processor,
    :unrelated_processor
  ]

  @allowed %{
    project_invitation: %{
      membership_management: [:project_owner],
      email_delivery: [:email_delivery_provider],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    project_participant: %{
      membership_management: [:project_owner],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    project_member_profile: %{
      participant_presentation: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    participation_revocation: %{
      membership_management: [:project_owner],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    participation_email_delivery: %{
      operations_diagnostics: [:approved_operations],
      email_delivery: [:email_delivery_provider],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    account_notification: %{
      notification_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    }
  }

  @anonymous_aggregate_boundary %{
    current_processing: :prohibited,
    future_requirement: :aggregate_and_genuinely_anonymous,
    prohibited_identifiers: [
      :account,
      :identity,
      :email_or_digest,
      :project,
      :workspace,
      :invitation,
      :participant,
      :notification,
      :repository,
      :device,
      :network,
      :session,
      :stable_or_singling_out_identifier
    ]
  }

  @type data_class ::
          :project_invitation
          | :project_participant
          | :project_member_profile
          | :participation_revocation
          | :participation_email_delivery
          | :account_notification

  @doc "Authorizes only an explicitly approved participation purpose and consumer."
  @spec authorize(data_class(), atom(), atom()) ::
          :ok
          | {:error, :secondary_use_prohibited | :consumer_prohibited | :not_authorized}
  def authorize(_data_class, purpose, _consumer) when purpose in @prohibited_purposes,
    do: {:error, :secondary_use_prohibited}

  def authorize(_data_class, _purpose, consumer) when consumer in @prohibited_consumers,
    do: {:error, :consumer_prohibited}

  def authorize(data_class, purpose, consumer) do
    with purposes when is_map(purposes) <- Map.get(@allowed, data_class),
         consumers when is_list(consumers) <- Map.get(purposes, purpose),
         true <- consumer in consumers do
      :ok
    else
      _not_authorized -> {:error, :not_authorized}
    end
  end

  @doc "The current prohibition and minimum contract for any future participation measurement proposal."
  @spec anonymous_aggregate_boundary() :: map()
  def anonymous_aggregate_boundary, do: @anonymous_aggregate_boundary

  @doc "The participation data classes governed by the fail-closed boundary."
  @spec data_classes() :: [data_class()]
  def data_classes, do: Map.keys(@allowed)

  @doc "The approved purpose-to-consumer routes, keyed by data class."
  @spec allowed_routes() :: %{data_class() => %{atom() => [atom()]}}
  def allowed_routes, do: @allowed

  @doc "The secondary-use purposes refused for every participation data class."
  @spec prohibited_purposes() :: [atom()]
  def prohibited_purposes, do: @prohibited_purposes

  @doc "The recipients refused for every participation data class and purpose."
  @spec prohibited_consumers() :: [atom()]
  def prohibited_consumers, do: @prohibited_consumers
end
