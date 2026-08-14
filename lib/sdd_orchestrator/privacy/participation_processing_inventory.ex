defmodule SddOrchestrator.Privacy.ParticipationProcessingInventory do
  @moduledoc """
  The mechanically validated specs/26 (participation-data-protection-controls)
  processing inventory (Task 1, AC-01).

  Holds one `ParticipationProcessingRecord` per persisted field of every
  participation schema — `ProjectInvitation`, `ProjectParticipant`,
  `ProjectMemberProfile`, `ParticipationRevocation`, and
  `ParticipationEmailDelivery` — plus the `participation.`-namespace usage of
  the shared account-level notification foundation
  (`SddOrchestrator.Notifications.AccountNotification`; see
  `SddOrchestrator.Participation.ProjectNotifications`'s `@payload_fields` for
  the closed `participation.*` event vocabulary that defines this namespace
  boundary, mirroring how `SddOrchestrator.Delivery.NotificationAccess` keeps
  its own `delivery.` namespace separate). This inventory never touches or
  duplicates specs/18's existing classification of that same shared schema
  under its `delivery.` namespace — `SddOrchestrator.Privacy.DeliveryProcessingInventory`
  remains the sole owner of that inventory's `delivery.`-namespace records.

  `SddOrchestrator.Participation.InvitationProof` is a logic module with no
  persisted fields of its own (it reads `ProjectInvitation` and
  `HostedIdentity` and writes nothing), so it has no entity here.

  Field lists are read from each schema module's own `__schema__(:fields)`
  reflection rather than hand-copied, so `completeness/0` fails the moment a
  new participation column exists with no matching classification — that is
  what gives AC-01 ("no participation processing is unclassified") its teeth.

  Every record's purpose, basis, authority, recipient, processor, transfer,
  and lifecycle-owner classification is mechanized from the approved
  specs/26 contract; see `SddOrchestrator.Privacy.ParticipationProcessingRecord`'s
  moduledoc for the full reasoning behind each closed vocabulary.
  """

  alias SddOrchestrator.Privacy.ParticipationProcessingRecord

  @schemas %{
    project_invitation: SddOrchestrator.Participation.ProjectInvitation,
    project_participant: SddOrchestrator.Participation.ProjectParticipant,
    project_member_profile: SddOrchestrator.Participation.ProjectMemberProfile,
    participation_revocation: SddOrchestrator.Participation.ParticipationRevocation,
    participation_email_delivery: SddOrchestrator.Participation.ParticipationEmailDelivery,
    account_notification: SddOrchestrator.Notifications.AccountNotification
  }

  @entity_defaults %{
    project_invitation: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :owner_membership_management,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_25_participation_identity_lifecycle
    ],
    project_participant: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :owner_membership_management,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_25_participation_identity_lifecycle
    ],
    project_member_profile: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :participant_project_context,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_25_participation_identity_lifecycle
    ],
    participation_revocation: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :owner_membership_management,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_25_participation_identity_lifecycle
    ],
    participation_email_delivery: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :minimized_operations,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_27_participation_operational_retention
    ],
    account_notification: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :participant_project_context,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_27_participation_operational_retention
    ]
  }

  # Fields whose role differs from their entity's default classification.
  # `project_invitation`'s credential-verification fields (`email_digest`,
  # `token_digest`, `token_salt`) are pure cryptographic mechanics never shown
  # to the owner who created the invitation, so they narrow to
  # `:minimized_operations` rather than the entity's ordinary
  # membership-management recipient. `delivery_email` is the one invitation
  # field that genuinely leaves the hosted database, addressed to the
  # configured email-delivery processor; `participation_email_delivery`'s
  # `recipient_address` is the same kind of exception for the email-delivery
  # diagnostic record.
  @field_overrides %{
    project_invitation: %{
      email_digest: [recipient_category: :minimized_operations],
      token_digest: [recipient_category: :minimized_operations],
      token_salt: [recipient_category: :minimized_operations],
      delivery_email: [
        processor_category: :email_delivery_provider,
        transfer_classification: :configured_email_delivery
      ]
    },
    participation_email_delivery: %{
      recipient_address: [
        processor_category: :email_delivery_provider,
        transfer_classification: :configured_email_delivery
      ]
    }
  }

  @field_purposes %{
    project_invitation: %{
      id: "Preserve the stable project-scoped identity of one invitation.",
      email_digest:
        "Detect a duplicate pending invitation for the same address without storing it in comparable form.",
      delivery_email:
        "Address the one invitation-delivery email the invited person needs to prove and accept.",
      token_digest:
        "Verify the delivered invitation credential without ever storing it in usable form.",
      token_salt:
        "Bind the stored credential digest to this one invitation so it cannot be replayed against another.",
      status:
        "Track the invitation through its pending, accepted, declined, canceled, or expired lifecycle.",
      expires_at: "Bound how long an unproven invitation credential remains usable.",
      terminal_at:
        "Record when the invitation reached a terminal state for lifecycle accountability.",
      terminal_reason: "Record why the invitation ended, distinct from its terminal timestamp.",
      credential_version:
        "Distinguish a reissued invitation credential from an earlier one after a resend.",
      project_id: "Bind the invitation to the project it grants no access to until accepted.",
      invited_by_account_id: "Attribute the invitation to the owner who issued it.",
      inserted_at: "Record invitation creation for lifecycle accountability.",
      updated_at: "Record the invitation's last status or credential change for accountability."
    },
    project_participant: %{
      id: "Preserve the stable identity of one project authorization.",
      role: "Record the fixed participant role this authorization grants.",
      state: "Track the authorization through its active or departed lifecycle.",
      joined_at: "Record when the authorization became active for lifecycle accountability.",
      departed_at: "Record when the authorization ended for lifecycle accountability.",
      departure_reason: "Record whether the authorization ended by removal or a voluntary leave.",
      project_id: "Bind the authorization to the project it grants participant access to.",
      hosted_identity_id:
        "Bind the authorization to the proven hosted identity it authorizes, until release.",
      inserted_at: "Record authorization creation for lifecycle accountability.",
      updated_at: "Record the authorization's last state change for accountability."
    },
    project_member_profile: %{
      id: "Preserve the stable identity of one project presentation profile.",
      role: "Record whether this label presents the project's owner or a participant.",
      state:
        "Track the profile through its active, historical, or anonymized presentation lifecycle.",
      display_name: "Present the accepted display spelling shown to current project members.",
      display_name_key:
        "Enforce case-insensitive project-scoped label uniqueness without duplicating the display text.",
      anonymized_at:
        "Record when the profile's identity link was removed for rights accountability.",
      project_id: "Bind the profile to the project its display label is scoped to.",
      account_id:
        "Keep the stable account link while the profile's label still identifies a person.",
      inserted_at: "Record profile creation for lifecycle accountability.",
      updated_at:
        "Record the profile's last rename, reactivation, or anonymization for accountability."
    },
    participation_revocation: %{
      id: "Preserve the stable identity of one participation-ended handoff.",
      contract_version: "Distinguish the handoff's field shape for a downstream consumer.",
      last_display_name:
        "Preserve the last accepted project label the handoff can safely reuse in a notice.",
      reason: "Record whether the reported participation ended by removal or a voluntary leave.",
      occurred_at:
        "Record when participation ended, and start the 30-day identity-link retention clock.",
      claimed_at: "Record when a consumer first claimed this handoff for processing.",
      acknowledged_at:
        "Record when a consumer confirmed handling this handoff, clearing former-identity links.",
      consumer_ref:
        "Correlate the handoff to the consumer's own committed record of handling it.",
      project_id: "Bind the handoff to the project participation ended in.",
      project_participant_id:
        "Bind the handoff to the exact authorization it reports the end of.",
      former_hosted_identity_id:
        "Route the handoff to the former participant's hosted identity until acknowledgement or retention clears it.",
      former_account_id:
        "Route the handoff to the former participant's account until acknowledgement or retention clears it.",
      owner_account_id:
        "Identify the immutable owner who becomes the fallback for the ended participation.",
      inserted_at: "Record handoff creation for lifecycle accountability.",
      updated_at:
        "Record the handoff's claim, acknowledgement, or identity-link release for accountability."
    },
    participation_email_delivery: %{
      id: "Preserve the stable identity of one participation email-delivery attempt.",
      event_type: "Classify which approved participation email this attempt sent.",
      subject_ref:
        "Correlate the delivery attempt to the invitation or participation event it reports on.",
      event_version: "Distinguish a resent or reissued event from an earlier delivery attempt.",
      recipient_address:
        "Address the one recipient this attempt was sent to, held only for retry and diagnosis.",
      status: "Track the attempt through its pending, sent, or failed outcome.",
      failure_code: "Name a short machine-readable reason a failed attempt did not deliver.",
      attempted_at:
        "Record when delivery was attempted, and start the 30-day diagnostic retention clock.",
      delivered_at: "Record when the message was confirmed sent.",
      inserted_at: "Record delivery-record creation for lifecycle accountability.",
      updated_at: "Record the delivery attempt's last status change for accountability."
    },
    account_notification: %{
      id: "Preserve the stable identity of one participation notification.",
      event_type:
        "Classify the participation.* event this notification reports, from the approved vocabulary.",
      subject_ref:
        "Address the participation subject (invitation, profile, revocation) the notification is about.",
      event_version:
        "Distinguish a redelivered or updated participation event from the same subject.",
      title: "Present the short user-facing participation notification title.",
      body: "Present the short minimized user-facing participation notification body.",
      project_label: "Show the project display label without a second copy of project content.",
      actor_label: "Show the acting member's display label without their email.",
      link_path:
        "Route the recipient to the authorized in-product participation screen; never an absolute or external URL.",
      occurred_at: "Record when the underlying participation event happened.",
      read_at: "Track the participation notification's read state for the recipient.",
      account_id:
        "Bind the participation notification to the recipient account and its deletion lifecycle.",
      inserted_at: "Record participation notification creation for the 90-day retention window.",
      updated_at:
        "Record the participation notification's last read-state change for accountability."
    }
  }

  @records (for {entity, purposes} <- @field_purposes,
                {field, purpose} <- purposes do
              defaults = Map.fetch!(@entity_defaults, entity)

              overrides =
                @field_overrides |> Map.get(entity, %{}) |> Map.get(field, [])

              attrs =
                defaults
                |> Keyword.merge(overrides)
                |> Keyword.merge(entity: entity, field: field, purpose: purpose)

              struct!(ParticipationProcessingRecord, attrs)
            end)

  @doc "The participation schema modules this inventory classifies."
  @spec schemas() :: %{atom() => module()}
  def schemas, do: @schemas

  @doc "One classified record per inventoried participation field or transfer."
  @spec records() :: [ParticipationProcessingRecord.t()]
  def records, do: @records

  @doc "The purpose map this inventory was built from, keyed by entity then field."
  @spec field_purposes() :: %{atom() => %{atom() => String.t()}}
  def field_purposes, do: @field_purposes

  @doc """
  Every schema field with no matching inventory entry, keyed by entity.

  Reads each schema module's own `__schema__(:fields)` reflection, so a field
  added to a participation schema without a matching inventory entry is
  detected automatically rather than by keeping a second hand-written field
  list in sync. An entity with no missing fields is absent from the result.
  """
  @spec missing_fields() :: %{atom() => [atom()]}
  def missing_fields do
    for {entity, schema} <- @schemas,
        known = @field_purposes |> Map.get(entity, %{}) |> Map.keys() |> MapSet.new(),
        actual = schema.__schema__(:fields) |> MapSet.new(),
        missing = MapSet.difference(actual, known) |> Enum.sort(),
        missing != [],
        into: %{} do
      {entity, missing}
    end
  end

  @doc """
  Every inventory entry naming a field the schema no longer declares, keyed by
  entity. Catches a stale classification left behind by a removed column.
  """
  @spec unknown_fields() :: %{atom() => [atom()]}
  def unknown_fields do
    for {entity, schema} <- @schemas,
        known = @field_purposes |> Map.get(entity, %{}) |> Map.keys() |> MapSet.new(),
        actual = schema.__schema__(:fields) |> MapSet.new(),
        unknown = MapSet.difference(known, actual) |> Enum.sort(),
        unknown != [],
        into: %{} do
      {entity, unknown}
    end
  end

  @doc """
  Validates every record's classification.

  Returns `:ok` when every record names an approved purpose, basis, authority,
  recipient, processor, transfer, and lifecycle owner; otherwise
  `{:error, [{record, reasons}, ...]}` for every record that failed, so a
  caller sees every defect rather than only the first.
  """
  @spec validate_all() :: :ok | {:error, [{ParticipationProcessingRecord.t(), [atom()]}]}
  def validate_all do
    failures =
      for record <- records(),
          {:error, reasons} <- [ParticipationProcessingRecord.validate(record)],
          do: {record, reasons}

    if failures == [], do: :ok, else: {:error, failures}
  end
end
