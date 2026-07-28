defmodule SddOrchestrator.Privacy.ProcessingInventory do
  @moduledoc """
  The approved processing inventory for the implemented slices.

  Enumerates every processing activity that touches personal data — identity,
  session, credential, transient authorization state, passwordless delivery and
  abuse protection, workspace, project and repository metadata, transient
  onboarding state, and operational-security logs — with its purpose, lawful
  basis, retention, rights behaviour, processors, and transfers. Purpose
  limitation is explicit: no activity has an analytics, advertising, or
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
      personal_data: ["internal correlation id", "outcome class", "timestamp"],
      access: "Authorized operations roles; excludes credentials, names, URLs, and bodies.",
      retention: "Deleted after 30 days.",
      rights: "Access, restriction, objection via operator workflow.",
      processors: ["Hosting and logging services"],
      transfers: "Per deployment privacy profile.",
      review: "Approved legitimate-interests assessment (design.md)."
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
