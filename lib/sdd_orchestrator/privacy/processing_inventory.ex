defmodule SddOrchestrator.Privacy.ProcessingInventory do
  @moduledoc """
  The approved processing inventory for the implemented slices.

  Enumerates every processing activity that touches personal data — identity,
  session, credential, transient authorization state, passwordless delivery and
  abuse protection, workspace, project and repository metadata, transient
  onboarding state, personal AI connection references, short-lived model
  catalog and quota projections, pinned runtime configurations, spending-ceiling
  ledgers, agent runtime observations, and operational-security logs — with its
  purpose, lawful basis, retention, rights behaviour, processors, and transfers.
  Purpose limitation is explicit: no activity has an analytics, advertising, or
  model-training purpose, and analytics is not a listed activity.

  Deployment-specific controller, processor, region, and transfer evidence lives in
  `DeploymentPrivacyProfile` and is enforced by the release gate, not here.
  """
  alias SddOrchestrator.Privacy.DataProcessingRecord

  @records [
    %DataProcessingRecord{
      activity: :github_identity,
      purpose: "Identify the authenticated GitHub user so their workspace is restored.",
      lawful_basis: :contract,
      personal_data: ["github_user_id", "login", "avatar_url"],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention: "While the account is active.",
      rights:
        "Access, correction, erasure, restriction, objection, portability via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved development data contract (design.md)."
    },
    %DataProcessingRecord{
      activity: :application_session,
      purpose: "Maintain the protected hosted session for the user-requested service.",
      lawful_basis: :contract,
      personal_data: ["account_id", "token_digest", "last_used_at"],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention: "Deleted within 24 hours of expiry or revocation.",
      rights: "Access, erasure, restriction via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved development data contract (design.md)."
    },
    %DataProcessingRecord{
      activity: :github_credential,
      purpose: "Call GitHub on the user's behalf to read repository access and metadata.",
      lawful_basis: :contract,
      personal_data: ["encrypted access token", "encrypted refresh token", "granted scopes"],
      access: "Protected server boundary only; never the browser, logs, agents, or workers.",
      retention: "Encrypted; kept only while the connected account requires it.",
      rights: "Erasure and restriction via operator workflow; revoked on sign-out.",
      processors: ["Hosting database", "GitHub (independent controller of its platform)"],
      transfers: "Per deployment privacy profile.",
      review: "Approved development data contract (design.md)."
    },
    %DataProcessingRecord{
      activity: :github_authorization_attempt,
      purpose: "Bind and validate one GitHub OAuth flow (state, PKCE) against replay.",
      lawful_basis: :contract,
      personal_data: ["state_digest", "browser_nonce_digest", "encrypted PKCE verifier"],
      access: "Protected server boundary only.",
      retention: "Unusable after 10 minutes; deleted within 24 hours.",
      rights: "Transient; deleted by retention before a rights request is actionable.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved development data contract (design.md)."
    },
    %DataProcessingRecord{
      activity: :hosted_identity,
      purpose: "Restore one stable hosted account and personal workspace after verified sign-in.",
      lawful_basis: :contract,
      personal_data: ["account_id", "hosted_identity_id"],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention: "While the hosted account is active; removed by account erasure.",
      rights: "Access, erasure, restriction, objection, and portability via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved passwordless authentication data contract (Slice 03 design.md)."
    },
    %DataProcessingRecord{
      activity: :external_identity,
      purpose: "Bind a verified sign-in method to the stable hosted identity.",
      lawful_basis: :contract,
      personal_data: ["provider", "provider subject", "verified email", "verified_at"],
      access: "Protected authentication boundary and authorized operations roles.",
      retention: "While the sign-in method or hosted account is active.",
      rights: "Access, correction, erasure, restriction, and portability via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved passwordless authentication data contract (Slice 03 design.md)."
    },
    %DataProcessingRecord{
      activity: :magic_link_attempt,
      purpose: "Issue and atomically verify one short-lived passwordless sign-in credential.",
      lawful_basis: :contract,
      personal_data: [
        "verified email",
        "salted token digest",
        "expiry and lifecycle timestamps",
        "delivery outcome class"
      ],
      access: "Protected authentication boundary and authorized operations roles.",
      retention:
        "Unusable after 15 minutes and pruned after the configured short grace period; final duration requires release approval.",
      rights: "Access and erasure through the verified operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved passwordless authentication data contract (Slice 03 design.md)."
    },
    %DataProcessingRecord{
      activity: :passwordless_email_delivery,
      purpose: "Deliver the user-requested one-time passwordless sign-in link.",
      lawful_basis: :contract,
      personal_data: ["delivery email", "one-time sign-in link", "delivery outcome"],
      access: "Configured delivery processor and protected authentication boundary only.",
      retention:
        "Provider copies and delivery records use the short duration approved at the release gate.",
      rights:
        "Access, erasure, and restriction through the verified operator workflow and processor.",
      processors: ["Production email provider selected in the deployment privacy profile"],
      transfers: "Provider region and safeguards must pass the passwordless release gate.",
      review:
        "Approved locally; provider, DPA, region, transfers, and retention are release gates."
    },
    %DataProcessingRecord{
      activity: :hosted_session,
      purpose: "Maintain and independently revoke a verified hosted browser session.",
      lawful_basis: :contract,
      personal_data: [
        "hosted_identity_id",
        "session token digest",
        "coarse browser and OS family",
        "first, last, and expiry timestamps"
      ],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention:
        "Until revocation or expiry, then pruned after the configured short grace period.",
      rights: "Access, erasure, restriction, and portability via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved passwordless authentication data contract (Slice 03 design.md)."
    },
    %DataProcessingRecord{
      activity: :passwordless_abuse_control,
      purpose: "Limit unwanted passwordless sends and protect authentication availability.",
      lawful_basis: :legitimate_interests,
      personal_data: [
        "process-secret HMAC email bucket",
        "process-secret HMAC IP bucket",
        "short-lived counters"
      ],
      access:
        "In-memory authentication service only; no browser, worker, or coding-agent access.",
      retention: "Memory-only refill windows; discarded on expiry or process restart.",
      rights: "Restriction and objection via operator workflow; no durable profile is retained.",
      processors: ["Application runtime"],
      transfers: "No separate transfer; deployment hosting profile applies.",
      review: "Approved passwordless abuse-control contract (Slice 03 design.md)."
    },
    %DataProcessingRecord{
      activity: :personal_workspace,
      purpose: "Own the user's projects and repository connections.",
      lawful_basis: :contract,
      personal_data: ["account_id"],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention: "While the account is active.",
      rights: "Access, erasure, portability via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved development data contract (design.md)."
    },
    %DataProcessingRecord{
      activity: :project_and_repository_connection,
      purpose: "Link one confirmed repository to one SDD Orchestrator project.",
      lawful_basis: :contract,
      personal_data: [
        "project display name",
        "provider_repository_id",
        "owner",
        "name",
        "full_name",
        "html_url",
        "visibility",
        "organization"
      ],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention: "While the project exists; only confirmed-repository metadata is retained.",
      rights: "Access, correction, erasure, portability via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved development data contract (design.md)."
    },
    %DataProcessingRecord{
      activity: :workspace,
      purpose:
        "Own projects and repository connections through one common logical hosted workspace root.",
      lawful_basis: :contract,
      personal_data: ["workspace id", "workspace kind (hosted)"],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention: "While the hosted account is active; removed by account erasure.",
      rights: "Access, erasure, portability via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved storage-selection data contract (Slice 05 design.md)."
    },
    %DataProcessingRecord{
      activity: :hosted_project_storage,
      purpose: "Establish the hosted storage root for a project the user saved to their account.",
      lawful_basis: :contract,
      personal_data: ["project id", "internal storage root key", "storage state"],
      access: "Authenticated user and authorized operations roles; never coding agents.",
      retention: "While the hosted project exists; removed by erasure or service termination.",
      rights: "Access, erasure via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved storage-selection data contract (Slice 05 design.md)."
    },
    %DataProcessingRecord{
      activity: :hosted_local_repository_binding,
      purpose: "Route the user's explicit local repository connection for one hosted project.",
      lawful_basis: :contract,
      personal_data: ["project id", "worker id", "last successful validation time"],
      access:
        "Owning personal workspace, explicitly selected authorized worker for local operations, and approved operations personnel when necessary.",
      retention:
        "Only while explicitly connected; deleted on disconnect, worker revocation, replacement, project erasure, or service termination, with encrypted backup copies expired within 35 days.",
      rights:
        "Access, correction, erasure, restriction, objection, and portability via the verified operator workflow.",
      processors: ["Hosting database", "Authorized device worker"],
      transfers: "Per deployment privacy profile; no device project data is copied to hosting.",
      review: "Approved project-portability binding data contract (Slice 06 design.md)."
    },
    %DataProcessingRecord{
      activity: :package_provenance,
      purpose:
        "Record the minimum project-bound fact needed to apply the restored package schema.",
      lawful_basis: :contract,
      personal_data: ["project id", "payload schema version", "restoration time"],
      access:
        "Owning project authority and approved operations personnel when necessary; never a source account, workspace, device, or exporter.",
      retention:
        "Only while the restored project or hosted service requires it; deleted with project erasure or service termination, with encrypted backup copies expired within 35 days.",
      rights:
        "Access, erasure, restriction, objection, and portability via the verified project workflow.",
      processors: [
        "Hosting database for hosted projects",
        "Device worker under the operating-system boundary for device projects"
      ],
      transfers:
        "Hosted processing follows the deployment privacy profile; device provenance has no hosted transfer.",
      review: "Approved project-portability provenance data contract (Slice 06 design.md)."
    },
    %DataProcessingRecord{
      activity: :project_package,
      purpose:
        "Generate, deliver, validate, and restore the user-requested encrypted project backup.",
      lawful_basis: :contract,
      personal_data: [
        "stable project id and display name",
        "provider and canonical repository identity",
        "current specification identities, titles, and document sets",
        "encrypted package and non-secret envelope parameters"
      ],
      access:
        "Authorized user and selected destination boundary for the active operation; never coding agents, model providers, analytics, diagnostics, caches, or indexes.",
      retention:
        "No completed service copy; passphrase, derived key, and decrypted content are discarded immediately, and the downloaded package remains under user control.",
      rights:
        "Active service copies are removed immediately; external user-held copies remain under the user's control.",
      processors: [
        "Application runtime for hosted operations",
        "Device worker under the operating-system boundary for device operations"
      ],
      transfers:
        "Hosted processing follows the deployment privacy profile; device generation has no hosted transfer.",
      review: "Approved project-portability package data contract (Slice 06 design.md)."
    },
    %DataProcessingRecord{
      activity: :import_attempt,
      purpose:
        "Hold one encrypted package while the authorized destination validates and commits a restore.",
      lawful_basis: :contract,
      personal_data: [
        "destination authority reference",
        "encrypted package",
        "coarse lifecycle status",
        "expiry and lifecycle timestamps"
      ],
      access:
        "Authorized user and selected destination boundary; approved operations only for lifecycle enforcement; never coding agents or model providers.",
      retention:
        "Deleted immediately on success, cancellation, or failure; stranded attempts expire within 24 hours.",
      rights:
        "Verified access exposes minimized lifecycle metadata without ciphertext; erasure deletes the attempt and propagates to processors.",
      processors: [
        "Hosting database for hosted attempts",
        "Device worker under the operating-system boundary for device attempts"
      ],
      transfers:
        "Hosted processing follows the deployment privacy profile; device attempts have no hosted transfer.",
      review: "Approved project-portability intake data contract (Slice 06 design.md)."
    },
    %DataProcessingRecord{
      activity: :restore_operation,
      purpose:
        "Decrypt, validate, preflight, and atomically commit one user-requested restoration.",
      lawful_basis: :contract,
      personal_data: [
        "transient recovery passphrase and derived key",
        "transient decrypted project, repository, and specification content",
        "selected destination authority"
      ],
      access:
        "Selected authorized destination in the active call only; never logs, diagnostics, analytics, caches, indexes, coding agents, or model providers.",
      retention:
        "Passphrase, derived key, and decrypted content are discarded immediately when the active call ends.",
      rights:
        "No durable operation copy remains; committed records use the verified project rights workflow.",
      processors: [
        "Application runtime for hosted restores",
        "Device worker under the operating-system boundary for device restores"
      ],
      transfers:
        "Hosted processing follows the deployment privacy profile; device restoration has no hosted transfer.",
      review: "Approved project-portability restore-operation data contract (Slice 06 design.md)."
    },
    %DataProcessingRecord{
      activity: :project_onboarding_attempt,
      purpose: "Hold short-lived onboarding workflow state until a project is created.",
      lawful_basis: :contract,
      personal_data: [
        "origin and target workspace references",
        "source-approved repository metadata (GitHub numeric id, or local fingerprint and display name)",
        "storage mode",
        "status and idempotency key",
        "one-time device-readiness and hosted-return proof digests",
        "browser-flow binding",
        "issue, expiry, consumption, and acknowledgement timestamps"
      ],
      access: "Authenticated user and authorized operations roles.",
      retention:
        "Unusable on consumption or expiry and deleted within 24 hours; raw device-readiness and hosted-return proofs are discarded immediately after verification and only their digests persist.",
      rights: "Access, erasure via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved storage-selection data contract (Slice 05 design.md)."
    },
    %DataProcessingRecord{
      activity: :project_specification_storage,
      purpose:
        "Persist versioned specification documents and current heads for the user-requested project workflows.",
      lawful_basis: :contract,
      personal_data: [
        "project and specification ids",
        "display title",
        "current revision id",
        "complete requirements, design, and tasks documents",
        "content digest",
        "minimum non-email actor reference",
        "revision sequence and lifecycle timestamps"
      ],
      access:
        "Authorized project workflows in the selected hosted or device boundary; operations and coding agents receive content only through an explicitly authorized workflow.",
      retention:
        "While the project exists or an approved accountability need applies; authoritative records are deleted with the project or verified rights outcome, security logs after 30 days, and encrypted rolling backups within 35 days.",
      rights:
        "Access and portability include version history; correction appends a revision; erasure and restriction use the verified project or account workflow and processor propagation.",
      processors: [
        "Hosting database for hosted projects",
        "Device worker under the operating-system boundary for device projects"
      ],
      transfers:
        "Hosted processing follows the deployment privacy profile; device-authoritative content has no hosted transfer.",
      review:
        "Approved local specification-storage privacy and security contract; deployment processor, region, transfer, notice, retention-enforcement, and accountable review evidence remain release gates."
    },
    %DataProcessingRecord{
      activity: :operational_security_log,
      purpose: "Diagnose failures and protect the service (security and reliability).",
      lawful_basis: :legitimate_interests,
      personal_data: ["event type", "timestamp", "outcome class", "internal correlation id"],
      access: "Authorized operations roles; excludes credentials, names, URLs, and bodies.",
      retention: "Deleted after 30 days.",
      rights: "Access, restriction, objection via operator workflow.",
      processors: ["Hosting and logging services"],
      transfers: "Per deployment privacy profile.",
      review: "Approved legitimate-interests assessment (design.md)."
    },
    %DataProcessingRecord{
      activity: :personal_ai_connection,
      purpose:
        "Select and address one worker-local personal AI profile for the runs the user asks for.",
      lawful_basis: :contract,
      personal_data: [
        "account and paired worker references",
        "opaque worker-local profile reference",
        "owner-chosen label",
        "provider and authentication mode",
        "availability and adapter compatibility version",
        "revocation state, removal-outcome vocabulary, counts, and lifecycle timestamps"
      ],
      access:
        "The owning account, the explicitly paired authorized worker for worker-local operations, approved operations personnel only for lifecycle enforcement, and a verified rights operator only for a verified rights request; coding agents and model providers never receive it.",
      retention:
        "While the connection is active; a revoked connection carries a deletion schedule once worker-local removal is acknowledged, is deleted with the account, and encrypted backup copies expire within 35 days.",
      rights:
        "Access and portability by export; correction of the owner-chosen label through the account workflow; erasure with the account; restriction and objection through the verified operator workflow.",
      processors: [
        "Hosting database",
        "Authorized device worker under the operating-system boundary",
        "OpenAI (independent controller of its own platform; contacted only by the user's worker-local official client)"
      ],
      transfers:
        "No credential or provider identity is transferred to the control plane; the provider is reached only by the user's own worker-local official client, and hosted processing follows the deployment privacy profile.",
      review:
        "Approved AI runtime governance data contract (Slice 11 design.md); deployment processor, region, transfer, notice, retention-enforcement, and accountable review evidence remain release gates."
    },
    %DataProcessingRecord{
      activity: :ai_model_catalog,
      purpose:
        "Offer only the models the user's own connection proved it can run for a requested selection.",
      lawful_basis: :contract,
      personal_data: [
        "account and connection references",
        "provider and enumeration status",
        "official-client provenance, method, and version",
        "proven model compatibility entries",
        "retrieval and expiry timestamps"
      ],
      access:
        "The owning account for its own selection, approved operations personnel only for lifecycle enforcement, and a verified rights operator only for a verified rights request; coding agents and model providers never receive it.",
      retention:
        "Expires on the stored short lifetime it was refreshed with (300 seconds by default, 3600 seconds at most), is deleted outright once its connection is terminally revoked or scheduled for deletion, is deleted with the account, and encrypted backup copies expire within 35 days.",
      rights:
        "Access and portability by export; correction does not apply to a provider-proven projection that expires within the hour; erasure with the account or its connection; restriction and objection through the verified operator workflow.",
      processors: [
        "Hosting database",
        "Authorized device worker under the operating-system boundary",
        "OpenAI (independent controller of its own platform; contacted only by the user's worker-local official client)"
      ],
      transfers:
        "No credential or provider identity is transferred to the control plane; the provider is reached only by the user's own worker-local official client, and hosted processing follows the deployment privacy profile.",
      review: "Approved AI runtime governance data contract (Slice 11 design.md)."
    },
    %DataProcessingRecord{
      activity: :ai_quota_snapshot,
      purpose:
        "Show the owning account its own remaining allowance and reset credits before work is funded.",
      lawful_basis: :contract,
      personal_data: [
        "account and connection references",
        "provider and authentication mode",
        "normalized allowance buckets and reset credits",
        "token-activity counters",
        "reported status and unknown-field markers",
        "official-client provenance, methods, and version",
        "retrieval and expiry timestamps"
      ],
      access:
        "The owning account only, because allowance, credits, and spend are account-wide; approved operations personnel only for lifecycle enforcement and a verified rights operator only for a verified rights request; never a project participant, and coding agents and model providers never receive it.",
      retention:
        "Expires on the stored short lifetime it was refreshed with (300 seconds by default, 3600 seconds at most), is deleted outright once its connection is terminally revoked or scheduled for deletion, is deleted with the account, and encrypted backup copies expire within 35 days.",
      rights:
        "Access and portability by export; correction does not apply to a provider-proven projection that expires within the hour; erasure with the account or its connection; restriction and objection through the verified operator workflow.",
      processors: [
        "Hosting database",
        "Authorized device worker under the operating-system boundary",
        "OpenAI (independent controller of its own platform; contacted only by the user's worker-local official client)"
      ],
      transfers:
        "No credential or provider identity is transferred to the control plane; the provider is reached only by the user's own worker-local official client, and hosted processing follows the deployment privacy profile.",
      review: "Approved AI runtime governance data contract (Slice 11 design.md)."
    },
    %DataProcessingRecord{
      activity: :ai_runtime_session,
      purpose:
        "Pin one immutable runtime configuration so a support conversation or agent run stays accountable to what was approved.",
      lawful_basis: :contract,
      personal_data: [
        "account and connection references",
        "consumer kind and opaque consumer reference",
        "provider, authentication mode, pinned model, and reasoning effort",
        "configuration version and catalog provenance",
        "the owner opt-ins in force",
        "any approved spending ceiling and its currency",
        "pin timestamp"
      ],
      access:
        "The owning account; a current authorized project participant only through the access-safe project-run projection; approved operations personnel only for lifecycle enforcement; a verified rights operator only for a verified rights request; coding agents and model providers never receive it.",
      retention:
        "Pruned 90 days after the pin while its connection is attached and 30 days after connection removal; deleted with the account, and encrypted backup copies expire within 35 days.",
      rights:
        "Access and portability by export; correction is refused because the pinned configuration is the immutable record of what ran; erasure with the account; restriction and objection through the verified operator workflow.",
      processors: [
        "Hosting database",
        "Authorized device worker under the operating-system boundary"
      ],
      transfers: "Per deployment privacy profile.",
      review:
        "Approved AI runtime governance data contract (Slice 11 design.md); deployment processor, region, transfer, notice, retention-enforcement, and accountable review evidence remain release gates."
    },
    %DataProcessingRecord{
      activity: :ai_runtime_cost_ledger,
      purpose:
        "Hold one runtime session strictly inside the spending ceiling its owner approved.",
      lawful_basis: :contract,
      personal_data: [
        "account and session references",
        "approved currency and ceiling",
        "versioned official price snapshot and its validity window",
        "bounded request configuration the calculations assume",
        "outstanding reservations and reconciled observed cost",
        "pause state, reason, and timestamp"
      ],
      access:
        "The owning account, because credits and spend are account-wide; approved operations personnel only for lifecycle enforcement; a verified rights operator only for a verified rights request; never a project participant, and coding agents and model providers never receive it.",
      retention:
        "Cascades with its runtime session, so it is pruned on the same 90-day attached and 30-day detached windows; deleted with the account, and encrypted backup copies expire within 35 days.",
      rights:
        "Access and portability by export; correction does not apply to a reconciled account of what was already spent; erasure with the account; restriction and objection through the verified operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review:
        "Approved AI runtime governance data contract (Slice 11 design.md); deployment processor, region, transfer, notice, retention-enforcement, and accountable review evidence remain release gates."
    },
    %DataProcessingRecord{
      activity: :agent_runtime_observation,
      purpose:
        "Report what a working agent is doing, what it has consumed, and whether it paused, to the people entitled to see that run.",
      lawful_basis: :contract,
      personal_data: [
        "account and session references",
        "ordering sequence and idempotent event key",
        "elapsed time and token counters when available",
        "estimated cost and the versioned basis it was calculated from",
        "applicable allowance bucket references",
        "status, resumable pause reason, and source markers",
        "observation time"
      ],
      access:
        "The owning account and a current authorized project participant through the access-safe project-run projection; approved operations personnel only for lifecycle enforcement; a verified rights operator only for a verified rights request; coding agents and model providers never receive it.",
      retention:
        "Pruned 30 days after the observation time; deleted with the account, and encrypted backup copies expire within 35 days.",
      rights:
        "Access and portability by export; correction is refused because an observation is the record of what was observed; erasure with the account; restriction and objection through the verified operator workflow.",
      processors: [
        "Hosting database",
        "Authorized device worker under the operating-system boundary"
      ],
      transfers: "Per deployment privacy profile.",
      review:
        "Approved AI runtime governance data contract (Slice 11 design.md); deployment processor, region, transfer, notice, retention-enforcement, and accountable review evidence remain release gates."
    },
    %DataProcessingRecord{
      activity: :ai_runtime_operational_log,
      purpose:
        "Diagnose failures and protect the AI-runtime boundary (security and reliability).",
      lawful_basis: :legitimate_interests,
      personal_data: ["event type", "timestamp", "outcome class", "internal correlation id"],
      access:
        "Authorized operations roles; excludes credentials, provider identity, worker-profile references, labels, and model or prompt content.",
      retention: "Deleted after 30 days.",
      rights: "Access, restriction, objection via operator workflow.",
      processors: ["Hosting and logging services"],
      transfers: "Per deployment privacy profile.",
      review:
        "Approved AI runtime governance data contract (Slice 11 design.md); deployment logging processor, region, transfer, and retention-enforcement evidence remain release gates."
    }
  ]

  @doc "The approved processing activities for this slice."
  @spec records() :: [DataProcessingRecord.t()]
  def records, do: @records

  @doc "The set of activity keys covered by the inventory."
  @spec activities() :: [atom()]
  def activities, do: Enum.map(@records, & &1.activity)

  @doc "Purpose limitation for every persisted specification field."
  @spec specification_field_purposes() :: %{atom() => %{atom() => String.t()}}
  def specification_field_purposes do
    %{
      project_specification: %{
        id: "Preserve the stable project-scoped specification identity.",
        project_id: "Bind the specification to its authoritative project and deletion lifecycle.",
        title: "Present the current user-facing specification label.",
        current_revision_id: "Select one complete immutable current document set.",
        inserted_at: "Record specification creation for lifecycle accountability.",
        updated_at: "Record current-head or title changes for lifecycle accountability."
      },
      specification_revision: %{
        id: "Preserve the stable immutable revision identity.",
        specification_id: "Bind the revision to its stable specification.",
        project_id: "Enforce project isolation and deletion propagation.",
        sequence: "Order immutable revisions within one specification.",
        requirements_document: "Provide the approved requirements document.",
        design_document: "Provide the approved design document.",
        tasks_document: "Provide the approved tasks document.",
        content_digest: "Verify deterministic document-set integrity and committed retries.",
        actor_ref: "Attribute an authorized change without retaining an email address.",
        inserted_at: "Record immutable revision creation for lifecycle accountability."
      }
    }
  end

  @doc "Purpose limitation for every persisted AI-runtime field."
  @spec ai_runtime_field_purposes() :: %{atom() => %{atom() => String.t()}}
  def ai_runtime_field_purposes do
    %{
      personal_ai_connection: %{
        id: "Preserve the stable control-plane identity of one personal AI connection.",
        account_id: "Bind the connection to its owning account and deletion lifecycle.",
        worker_id: "Address the one paired worker that holds the profile locally.",
        worker_profile_ref:
          "Address the worker-local profile opaquely, without provider identity.",
        label: "Let the owner tell their own connections apart in the interface.",
        provider: "Select the adapter and compatibility rules the connection is served by.",
        authentication_mode:
          "Decide which allowance and spending controls apply to the connection.",
        availability: "Show whether the connection can be selected for work right now.",
        adapter_compatibility_version:
          "Refuse work when the worker-side adapter is too old to honour the contract.",
        revocation_state: "Drive the one-way revocation lifecycle to its terminal state.",
        revocation_requested_at:
          "Record when revocation was requested so the lifecycle is auditable.",
        revocation_acknowledged_at:
          "Record when the worker confirmed removal so the deletion schedule can start.",
        credential_removal_attempts: "Bound retries of the worker-local removal request.",
        credential_removal_attempted_at:
          "Record when the last worker-local removal was attempted.",
        credential_removal_failure_reason:
          "Record one typed reason a worker-local removal is still outstanding.",
        credential_removal_result:
          "Record whether the worker-local removal completed or found nothing to remove.",
        deletion_scheduled_at:
          "Schedule deletion of the opaque control-plane reference after acknowledgement.",
        inserted_at: "Record connection creation for lifecycle accountability.",
        updated_at: "Record label and lifecycle changes for accountability."
      },
      model_catalog_snapshot: %{
        id: "Preserve the stable identity of one short-lived catalog projection.",
        account_id: "Enforce account isolation and deletion propagation.",
        connection_id: "Bind the projection to the connection that proved it.",
        provider: "Apply the provider's own compatibility rules to the projection.",
        status: "Say whether enumeration succeeded or the source cannot enumerate.",
        source: "Record that the facts came from the user's own official client.",
        source_method: "Record which official-client call produced the facts.",
        source_version: "Bound how the facts may be interpreted as the client changes.",
        retrieved_at: "Anchor the storage-limitation window to when the facts were read.",
        expires_at: "Enforce the short lifetime the projection may be relied on for.",
        models: "Offer only the selections the connection proved it can run.",
        inserted_at: "Record projection creation for lifecycle accountability.",
        updated_at: "Record projection refreshes for lifecycle accountability."
      },
      quota_snapshot: %{
        id: "Preserve the stable identity of one short-lived allowance projection.",
        account_id: "Enforce account isolation and deletion propagation.",
        connection_id: "Bind the projection to the connection whose allowance it reports.",
        provider: "Apply the provider's own allowance vocabulary to the projection.",
        authentication_mode: "Decide which allowance and spending controls the projection feeds.",
        status: "Say whether the allowance facts are complete, partial, or unknown.",
        source: "Record that the facts came from the user's own official client.",
        source_methods: "Record which official-client calls contributed the facts.",
        source_version: "Bound how the facts may be interpreted as the client changes.",
        retrieved_at: "Anchor the storage-limitation window to when the facts were read.",
        expires_at: "Enforce the short lifetime the projection may be relied on for.",
        buckets: "Show the owner the remaining allowance each bucket reports.",
        reset_credits: "Show the owner when a spent bucket is reported to recover.",
        token_activity: "Show the owner the consumption the provider reported for the window.",
        unknown_fields:
          "Name reported keys this version refuses to interpret, without keeping their values.",
        inserted_at: "Record projection creation for lifecycle accountability.",
        updated_at: "Record projection refreshes for lifecycle accountability."
      },
      ai_runtime_session: %{
        id: "Preserve the stable identity of one pinned runtime configuration.",
        account_id: "Enforce account isolation and deletion propagation.",
        connection_id: "Name the connection that funded the run until it is removed.",
        consumer_kind: "Distinguish a support conversation from a working agent run.",
        consumer_ref: "Address the one consumer this pin belongs to, opaquely.",
        provider: "Record which provider contract the run was served under.",
        authentication_mode: "Record which allowance and spending controls governed the run.",
        model: "Record the selection the run was actually pinned to.",
        reasoning_effort: "Record the effort setting the run was actually pinned to.",
        configuration_version:
          "Let a later reader interpret the pin under the rules that created it.",
        catalog_snapshot_ref: "Point at the projection that proved the pinned selection.",
        catalog_source: "Record that the proof came from the user's own official client.",
        catalog_source_method: "Record which official-client call proved the selection.",
        catalog_source_version: "Bound how the proof may be interpreted as the client changes.",
        catalog_retrieved_at: "Show when the proof behind the pin was read.",
        catalog_expires_at: "Show when the proof behind the pin stopped being current.",
        opt_ins: "Record the explicit owner choices that were in force for the run.",
        spending_ceiling_amount:
          "Record the ceiling the owner approved for a key-authenticated run.",
        spending_ceiling_currency: "Record the currency that ceiling was approved in.",
        pinned_at: "Anchor the retention window to the moment the configuration was pinned.",
        inserted_at: "Record pin creation for lifecycle accountability.",
        updated_at: "Record the single permitted detachment for lifecycle accountability."
      },
      runtime_cost_ledger: %{
        id: "Preserve the stable identity of one session's ceiling state.",
        account_id: "Enforce account isolation and deletion propagation.",
        session_id: "Bind the ceiling state to the one session it governs.",
        currency: "Make every amount in the row comparable and unambiguous.",
        ceiling: "Hold the run inside the limit its owner approved.",
        price_version: "Record which published price the reservations were calculated from.",
        price_source: "Record that the price came from the official published schedule.",
        price_published_at: "Show when the price used for the calculations took effect.",
        price_expires_at: "Refuse to keep calculating from a price that is no longer current.",
        input_unit_price: "Calculate a reservation from the bounded request configuration.",
        output_unit_price: "Calculate a reservation from the bounded request configuration.",
        max_input_tokens: "Bound the request so a reservation cannot understate the run.",
        max_output_tokens: "Bound the request so a reservation cannot understate the run.",
        reserved_amount: "Keep the sum of outstanding reservations enforceable in one place.",
        observed_amount: "Record the reconciled cost that was actually observed.",
        outstanding_reservations:
          "Make one reservation idempotent and releasable without a second row.",
        paused: "Stop new work as soon as the approved limit can no longer be honoured.",
        pause_reason: "Name the resumable reason work stopped, from a fixed vocabulary.",
        paused_at: "Record when work stopped so the pause is auditable.",
        inserted_at: "Record ledger creation for lifecycle accountability.",
        updated_at: "Record reservation, reconciliation, and pause changes for accountability."
      },
      agent_runtime_observation: %{
        id: "Preserve the stable identity of one observation.",
        account_id: "Enforce account isolation and deletion propagation.",
        session_id: "Bind the observation to the run it describes.",
        sequence: "Keep the run's history in an order that cannot be silently rewritten.",
        event_key: "Refuse to store the same reported event twice.",
        observed_at: "Anchor the 30-day retention window to when the run was observed.",
        elapsed_seconds: "Show how long the run has been working.",
        elapsed_source: "Say whether the elapsed value is observed or unknown.",
        input_tokens: "Show the consumption reported for the request side.",
        output_tokens: "Show the consumption reported for the response side.",
        total_tokens: "Show the combined consumption reported for the run.",
        tokens_source:
          "Say whether the counters are a provider fact, a worker observation, or unknown.",
        estimated_cost_amount: "Show the owner a local estimate of what the run is costing.",
        estimated_cost_currency: "Make that estimate comparable and unambiguous.",
        estimated_cost_basis:
          "Show what the estimate was calculated from so it is not mistaken for a bill.",
        cost_source: "Say whether the estimate is a local calculation or unavailable.",
        quota_refs: "Point at the allowance buckets the run draws on.",
        quota_source: "Say whether the bucket references are a provider fact or unknown.",
        status: "Show whether the run is working, waiting, paused, or finished.",
        status_source:
          "Say whether the status is a provider fact, a worker observation, or unknown.",
        pause_reason: "Name the resumable reason a paused run stopped, from a fixed vocabulary.",
        unknown_fields:
          "Name reported keys this version refuses to interpret, without keeping their values.",
        inserted_at: "Record observation storage for lifecycle accountability.",
        updated_at: "Record the row's last write for lifecycle accountability."
      }
    }
  end

  @doc """
  Whether the inventory declares any analytics processing. Always false: the
  implemented slices emit and retain no product analytics.
  """
  @spec analytics?() :: boolean()
  def analytics? do
    Enum.any?(@records, fn record ->
      String.contains?(String.downcase(record.purpose), ["analytic", "advertis", "model training"])
    end)
  end
end
