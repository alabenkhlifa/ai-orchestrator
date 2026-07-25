defmodule SddOrchestrator.Privacy.ProcessingInventory do
  @moduledoc """
  The approved Slice 01 processing inventory.

  Enumerates every processing activity that touches personal data in this slice —
  identity, session, credential, transient authorization state, workspace, project
  and repository metadata, transient onboarding state, and operational-security
  logs — with its purpose, lawful basis, retention, rights behaviour, processors,
  and transfers. Purpose limitation is explicit: no activity has an analytics,
  advertising, or model-training purpose, and analytics is not a listed activity.

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
      activity: :project_onboarding_attempt,
      purpose: "Hold short-lived onboarding workflow state until a project is created.",
      lawful_basis: :contract,
      personal_data: ["selected repository metadata", "storage mode", "device-setup receipt"],
      access: "Authenticated user and authorized operations roles.",
      retention: "Deleted 24 hours after abandonment or consumption.",
      rights: "Access, erasure via operator workflow.",
      processors: ["Hosting database"],
      transfers: "Per deployment privacy profile.",
      review: "Approved development data contract (design.md)."
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

  @doc """
  Whether the inventory declares any analytics processing. Always false: Slice 01
  emits and retains no product analytics.
  """
  @spec analytics?() :: boolean()
  def analytics? do
    Enum.any?(@records, fn record ->
      String.contains?(String.downcase(record.purpose), ["analytic", "advertis", "model training"])
    end)
  end
end
