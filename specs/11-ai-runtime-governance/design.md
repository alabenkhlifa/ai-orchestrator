# AI Runtime Governance Design

## Context

Slice 07 launches a configured coding agent through a worker and deliberately leaves provider setup and model-selection experience outside its scope. The project also needs support assistants that use AI outside a guided-delivery run. Both surfaces need one connection, catalog, quota, configuration, and observation vocabulary, but Slice 07 remains the owner of its run, branch, workspace, cancellation, retry, and review lifecycle.

Provider credentials and authenticated account facts create a stricter boundary than ordinary project configuration. Credentials must stay inside the worker or operating-system keychain, while the control plane needs enough opaque state to let a user choose a connection and observe authorized work. Providers expose different catalog and quota shapes, so absence must remain unknown and arbitrary buckets must survive normalization.

## Proposed Approach

Define a provider-neutral personal-worker RPC boundary on top of the existing paired-local-worker authorization capability. It carries bounded, correlated account-level AI requests and responses and remains separate from Slice 07's project and run-scoped worker gateway. The first slice accepts only paired local workers; remote and cloud worker identity, transport, credential custody, and deployment remain separate work.

Inside that worker boundary, supervise one OpenAI Codex App Server process over local standard input and output. Generate the protocol schema from the installed Codex version, admit only explicitly verified version and schema-digest pairs, and allowlist the documented account, login, model, rate-limit, usage, and token-observation methods. Managed ChatGPT browser or device-code login and API-key login remain worker-local. Externally supplied ChatGPT tokens, WebSocket transport, raw account identity, and raw App Server errors are excluded.

Store multiple account-owned `PersonalAIConnection` records as opaque references to distinct worker-local Codex profiles. Each connection has one user-chosen account-scoped label, one immutable account and worker binding, one provider and authentication mode, and one safe availability state. The account-level AI Connections screen performs linking, inspection, rename, and revocation without accepting an API key or receiving provider email, account ID, workspace ID, plan detail, or credential material.

Create one immutable runtime-session record for each support conversation or working-agent run. It pins the connection reference, model, effort, catalog provenance, configuration version, and active safety choices. Concurrent sessions may reuse the same connection, but no session inherits another session's fallback, opt-in, ceiling, pause, or observation state.

Normalize provider quota into an open list of typed buckets rather than fixed plan fields. Keep ChatGPT rate-limit and token-activity facts separate from API-key billing, and keep provider facts, worker observations, and local estimates distinct. API-key sessions use a `RuntimeCostLedger`: before every chargeable turn it atomically reserves the conservative maximum derived from the pinned model, bounded request configuration, and a current versioned official-price snapshot, then reconciles the reservation against observed usage. Missing or stale pricing refuses the turn.

A runtime observation projects exact account-wide data only to the connection owner and derives a safe project view for current participants. Slice 11 owns the projection contracts and capability; Slice 07 and Slice 12 own the eventual per-agent presentation inside their workflows.

The active slice stops at provider-neutral personal connections, catalogs, quotas, pinned sessions, spending-ceiling pause decisions, and operational observation. Project-shared API funding and Slice 07 pause, resume, stop, and linked-continuation integration remain separate work. Slice 07 must be updated before it consumes the new capabilities.

## Components Affected

- Account-level personal-worker RPC transport over the existing paired-local-worker authorization boundary.
- Worker-local provider connection and credential adapter, including the first operational OpenAI Codex App Server adapter.
- Control-plane personal connection registry with opaque references.
- Account-level AI Connections LiveView and worker-local secret-entry or managed-login handoff.
- Live model catalog and compatibility projection.
- Quota normalization and spending-ceiling evaluator.
- Runtime-session configuration and pinning boundary.
- Versioned provider-price configuration and strict per-session cost ledger.
- Runtime usage and observation projection.
- Connection-owner and project-participant access checks.
- Support-assistant and working-agent consumer contracts.
- Privacy, lifecycle, log, cache, backup, and rights integration.
- Future Slice 07 and project-shared funding consumers.

## Data and Access Boundaries

- `PersonalAIConnection`: one account-owned opaque control-plane reference to a credential-bearing worker-local Codex profile, containing a user label, provider and authentication mode, immutable account and worker references, safe availability, adapter compatibility version, and lifecycle state but no credential, provider email, raw provider account or workspace identifier, or plan detail. An account may own multiple connections; labels are trimmed and case-insensitively unique within the account, and the same account, worker, and worker-local profile link is idempotent.
- `ModelCatalogSnapshot`: one short-lived authenticated worker projection containing catalog provenance, retrieval time, proven models, supported effort choices, compatibility facts, and current or default designation without plan inference.
- `QuotaSnapshot`: one short-lived connection-owned set of arbitrary provider-reported quota buckets, reset facts, credit or paid-continuation facts, source time, and unknown markers.
- `AIRuntimeSession`: one immutable configuration for a support conversation or working-agent run, containing consumer reference, opaque connection reference, selected model, effort, catalog provenance, configuration version, explicit scarcity or paid-use choices, spending ceiling, and lifecycle reference.
- `RuntimeCostLedger`: one API-key session's strict ceiling state containing currency, ceiling, versioned official-price snapshot reference, bounded request configuration, current atomic reservation, reconciled observed cost, remaining approved capacity, and pause state without provider invoice or payment credentials.
- `AgentRuntimeObservation`: one ordered minimized observation for an agent containing elapsed time, token counters when available, estimated cost and basis when calculable, applicable quota references, status, source labels, and observation time.
- `SharedProjectAIConnection`: deferred project-owned API capacity with participant permissions and no personal-subscription credential.
- `ProjectAIBudget`: deferred project-shared total budget and per-run ceiling enforcement state.
- `RuntimeContinuation`: deferred link from a paused original session or run to an explicitly approved continuation configuration without overwriting original history.

Required boundaries:

- Credentials and raw authenticated client state remain exclusively in the worker or operating-system keychain and are never serialized into a control-plane command or record.
- The browser application never accepts an API key. Managed login and API-key entry occur through the local worker-owned Codex profile interface.
- The personal-worker RPC accepts only a currently authorized paired local worker and never carries a Slice 07 project-run command or credential.
- Exact account-wide quota, credits, and spend require connection-owner authorization.
- Safe project observation requires current project-participant authorization from the existing participation capability and contains no unrelated account or project values.
- Catalog and quota snapshots are personal data, expire on a short configured lifetime, and are refreshed from the authenticated source rather than treated as durable entitlements.
- Provider output is untrusted. Adapters validate versions, field sets, sizes, value ranges, source labels, and credential-shaped content before projection.

## Interfaces

- Personal-worker RPC: authenticate an existing paired local worker, negotiate versioned AI capabilities, correlate bounded account-scoped requests and responses, reject replay or cross-workspace use, survive reconnects, and remain independent from Slice 07's run gateway.
- Codex App Server adapter: supervise a local standard-input and standard-output process, verify the installed version and generated-schema digest, initialize the documented protocol, allowlist approved methods, normalize typed failures, and reject WebSocket, experimental external-token login, unknown schema, credential-shaped output, raw errors, and oversized payloads.
- Personal connection adapter: create or resolve one worker-local Codex profile, start managed ChatGPT or API-key login locally, return an opaque reference and safe availability, revoke local credentials, and never return credential or raw provider-account material.
- AI Connections interface: authorize the signed-in account and selected paired local worker, create and rename account-scoped labels, show safe availability and corrective actions, inspect live catalog and quota projections, and revoke without rendering or accepting credential material.
- Catalog adapter: fetch from the authenticated provider API Models endpoint or official installed client, return proven model, effort, compatibility, current or default, source, and retrieval facts, or a typed enumeration-unsupported result.
- Quota adapter: return any number of typed general or model-specific buckets, reset facts, paid-continuation facts, source time, and explicit unknown fields without inventing unlimited capacity.
- Official-client usage adapter: query a supported deterministic account or usage surface rather than model prose; a future Claude Code adapter may use supported rate-limit fields or `/usage`, and must treat an unrecognized output version as unknown.
- Runtime-session interface: validate an eligible connection and proven compatible model and effort, record explicit opt-ins and a spending ceiling, pin the configuration, and return an immutable session reference reusable by either consumer kind.
- Runtime-cost interface: load a current versioned official-price snapshot, calculate a conservative maximum for the next bounded API-key turn, atomically reserve it inside the session ceiling, reconcile it against observed usage, and fail closed on stale price, missing price, insufficient capacity, duplicate reservation, or concurrent over-allocation.
- Runtime-observation interface: append ordered usage and status observations, label provider facts and local estimates, evaluate quota and spending pause conditions, and project owner-exact or participant-safe views.
- Participation interface: consume `capability:project-participation-boundary` for project-run observation without changing membership or Slice 07 authority.
- Future Slice 07 interface: consume `capability:ai-runtime-session` and `capability:ai-runtime-observation` only after an approved `update-spec` defines manifest references, pause, resume, stop, cancellation, and continuation mapping.

## Decisions and Tradeoffs

### Paired Local Worker First

- Choice: Deliver personal provider setup only through an already authorized paired local worker in the first slice.
- Reason: The repository already has a workspace-bound local-worker authorization capability, while remote and cloud workers introduce separate identity, credential custody, transport, operating-system, and deployment trust boundaries.
- Consequence: A user without a compatible paired local worker receives setup guidance and cannot link a connection. Remote and cloud connection setup remains a focused later specification.

### Separate Personal-Worker RPC

- Choice: Add an account and device-workspace-scoped personal AI RPC transport instead of extending Slice 07's project and run-scoped worker gateway.
- Reason: Provider setup happens before a run and may serve support conversations unrelated to a project. Reusing the run gateway would either invent a project authorization or broaden Slice 07 ownership.
- Consequence: The native worker maintains a distinct negotiated channel and operation allowlist for personal AI setup and runtime facts.

### Version-Checked Codex App Server Over Standard Input And Output

- Choice: Integrate Codex through a worker-supervised local App Server process over standard input and output, accepting only tested Codex-version and generated-schema-digest pairs.
- Reason: The documented App Server exposes the required account, model, rate-limit, usage, and token-observation methods, but the command remains experimental and can change between Codex releases.
- Consequence: An unknown Codex version, schema digest, method, or response shape makes the connection incompatible until the adapter is updated and proved. WebSocket transport and externally supplied ChatGPT tokens are not used.

### Multiple Labelled Worker-Local Profiles

- Choice: Let one account own multiple labelled personal connections, each immutably bound to one paired worker and worker-local Codex profile.
- Reason: A user may use separate devices or provider accounts, and explicit selection needs a stable human label without exposing provider account identity.
- Consequence: Labels are account-scoped and case-insensitively unique. Rebinding is prohibited; revocation and a new link replace an obsolete binding.

### Credential-Local Personal Connections

- Choice: Keep provider credentials in the authenticated worker or operating-system keychain and expose only an opaque account-owned connection reference to the control plane.
- Reason: Support and project workflows need stable selection without turning project storage, logs, backups, or exports into credential stores.
- Consequence: Connection availability and revocation require the owning worker boundary; an unavailable worker fails closed.

### Live Catalog With Proven Limited Fallback

- Choice: Retrieve models from the provider API Models endpoint or official installed client and expose only the proven current or default model when enumeration is unsupported.
- Reason: Model availability changes and cannot be reliably inferred from plan names or a hardcoded registry.
- Consequence: A provider with limited discovery offers fewer choices rather than guessed choices.

### Open Quota Buckets

- Choice: Normalize quota as an arbitrary list of provider-labelled general or model-specific buckets with explicit unknown fields.
- Reason: Providers may add new quota scopes, reset windows, or paid-continuation facts that do not fit a fixed schema.
- Consequence: UI and policy evaluate applicable buckets generically and cannot assume one universal remaining percentage.

### Strict API-Key Cost Reservation

- Choice: Enforce each API-key spending ceiling by reserving a conservative maximum before a chargeable turn and reconciling the reservation afterward.
- Reason: Completed-turn accounting can overshoot on the last request and does not satisfy a strict non-exceeding boundary.
- Consequence: Work can pause before the nominal ceiling when the remaining amount cannot cover the bounded worst case. Missing or stale official pricing refuses execution rather than treating the model as free.

### Immutable Session Configuration

- Choice: Pin connection, model, effort, provenance, version, opt-ins, and ceiling per conversation or run while permitting concurrent sessions on one connection.
- Reason: Active work must remain reproducible and must not change because another session, catalog refresh, or quota view changed.
- Consequence: Changing model or connection creates a linked continuation or new session rather than mutating the original.

### Facts, Estimates, And Unknowns

- Choice: Keep provider-reported facts, worker-observed counters, local estimates, and unknown values distinct through storage and presentation.
- Reason: Estimated cost is useful operationally but is not a provider invoice, and missing quota cannot safely mean unlimited.
- Consequence: Some views show unknown or partially populated values instead of a false precise total.

### Consumer-Owned Per-Agent Presentation

- Choice: Publish observation and authorization projections from this slice while leaving per-agent screens to Slice 07 and Slice 12.
- Reason: Those specifications own the workflows that create and present working-agent runs and support-assistant conversations.
- Consequence: Slice 11 delivers the account-level AI Connections screen and reusable projection contracts, not an orphan agent-monitoring page.

### Pause Foundation Without Owning Workflow Lifecycles

- Choice: Let the runtime evaluator produce resumable quota and spending pause reasons while deferring Slice 07 state transitions, stop mapping, and continuation to an approved consumer update.
- Reason: Slice 07 owns cancellation authority, branch and workspace preservation, attempts, retry, and terminal outcomes.
- Consequence: The active slice can prove safety decisions and observation without changing guided-delivery behavior.

### One Operational Provider Before Provider Breadth

- Choice: Deliver OpenAI Codex as the first production worker adapter while keeping the contracts provider-neutral.
- Reason: OpenAI Codex is the project's approved primary coding agent, and an executable slice needs a real authenticated catalog and quota path rather than only test doubles.
- Consequence: Claude Code and other providers remain later adapters. They must use officially supported authentication and deterministic usage interfaces; natural-language self-reporting and inferred quota are prohibited.

## Risks

- Codex App Server is documented for product integration but its CLI command is still experimental. Pin tested version and generated-schema-digest pairs, use standard input and output only, keep protocol fixtures, and fail closed until drift is reviewed.
- A personal-worker RPC could accidentally become a second run gateway. Keep its authentication account and device-workspace scoped, allowlist only connection, catalog, quota, and observation operations, and reject project-run commands.
- An opaque reference may still become linkable personal data. Scope it to the owning account and worker, exclude it from analytics and user-visible logs, and delete or revoke it through the connection lifecycle.
- Provider adapters may leak credentials or raw account identifiers inside error text. Use strict typed results, allowlisted fields, size limits, and credential-pattern rejection.
- Catalog caches may present withdrawn models as available. Use short lifetimes, source timestamps, refresh before session creation, and fail closed on unknown compatibility.
- Quota shapes may evolve. Preserve arbitrary typed buckets and unknown fields instead of rejecting new safe buckets or forcing them into fixed plan semantics.
- Concurrent sessions may overspend against stale quota. Apply per-session ceilings before chargeable work and treat provider quota as observed availability, not a transaction lock.
- A conservative API-key reservation may pause earlier than actual usage requires. Show the reservation basis, bound request inputs, reconcile promptly, and never weaken the ceiling silently.
- A stale or incorrect price snapshot could under-reserve. Version the official source, reject expired or missing model prices, and keep the deployment's current price-source evidence in the release gate.
- Cost estimates may be mistaken for exact charges. Store their calculation basis and label them as estimates in every projection.
- Participant views may expose an owner's account-wide quota or spend. Derive a separate safe projection and prove forbidden fields are absent, not merely hidden in the UI.
- A consumer may interpret runtime pause as Slice 07 cancellation or failure. Require a later `update-spec` and contract tests before lifecycle integration.

## Open Questions

- None.
