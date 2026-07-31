# AI Runtime Governance Design

## Context

Slice 07 launches a configured coding agent through a worker and deliberately leaves provider setup and model-selection experience outside its scope. The project also needs support assistants that use AI outside a guided-delivery run. Both surfaces need one connection, catalog, quota, configuration, and observation vocabulary, but Slice 07 remains the owner of its run, branch, workspace, cancellation, retry, and review lifecycle.

Provider credentials and authenticated account facts create a stricter boundary than ordinary project configuration. Credentials must stay inside the worker or operating-system keychain, while the control plane needs enough opaque state to let a user choose a connection and observe authorized work. Providers expose different catalog and quota shapes, so absence must remain unknown and arbitrary buckets must survive normalization.

## Proposed Approach

Define a provider-neutral worker adapter with credential-local operations for connection availability, live catalog retrieval, quota retrieval, and runtime usage observation. Deliver one operational OpenAI Codex adapter in the first slice through supported official-client account, model, and rate-limit interfaces. The control plane receives strict allowlisted projections and stores opaque connection references rather than credentials. Deterministic adapter doubles prove failure and compatibility cases without requiring live provider access in local tests.

Create one immutable runtime-session record for each support conversation or working-agent run. It pins the connection reference, model, effort, catalog provenance, configuration version, and active safety choices. Concurrent sessions may reuse the same connection, but no session inherits another session's fallback, opt-in, ceiling, pause, or observation state.

Normalize provider quota into an open list of typed buckets rather than fixed plan fields. Keep provider facts, worker observations, and local estimates distinct. A runtime observation projects exact account-wide data only to the connection owner and derives a safe project view for current participants.

The active slice stops at provider-neutral personal connections, catalogs, quotas, pinned sessions, spending-ceiling pause decisions, and operational observation. Project-shared API funding and Slice 07 pause, resume, stop, and linked-continuation integration remain separate work. Slice 07 must be updated before it consumes the new capabilities.

## Components Affected

- Worker-local provider connection and credential adapter, including the first operational OpenAI Codex adapter.
- Control-plane personal connection registry with opaque references.
- Live model catalog and compatibility projection.
- Quota normalization and spending-ceiling evaluator.
- Runtime-session configuration and pinning boundary.
- Runtime usage and observation projection.
- Connection-owner and project-participant access checks.
- Support-assistant and working-agent consumer contracts.
- Privacy, lifecycle, log, cache, backup, and rights integration.
- Future Slice 07 and project-shared funding consumers.

## Data and Access Boundaries

- `PersonalAIConnection`: one account-owned opaque control-plane reference to a credential-bearing worker-local provider connection, containing provider kind, worker boundary, safe availability, version, and lifecycle state but no credential or raw provider-account identifier.
- `ModelCatalogSnapshot`: one short-lived authenticated worker projection containing catalog provenance, retrieval time, proven models, supported effort choices, compatibility facts, and current or default designation without plan inference.
- `QuotaSnapshot`: one short-lived connection-owned set of arbitrary provider-reported quota buckets, reset facts, credit or paid-continuation facts, source time, and unknown markers.
- `AIRuntimeSession`: one immutable configuration for a support conversation or working-agent run, containing consumer reference, opaque connection reference, selected model, effort, catalog provenance, configuration version, explicit scarcity or paid-use choices, spending ceiling, and lifecycle reference.
- `AgentRuntimeObservation`: one ordered minimized observation for an agent containing elapsed time, token counters when available, estimated cost and basis when calculable, applicable quota references, status, source labels, and observation time.
- `SharedProjectAIConnection`: deferred project-owned API capacity with participant permissions and no personal-subscription credential.
- `ProjectAIBudget`: deferred project-shared total budget and per-run ceiling enforcement state.
- `RuntimeContinuation`: deferred link from a paused original session or run to an explicitly approved continuation configuration without overwriting original history.

Required boundaries:

- Credentials and raw authenticated client state remain exclusively in the worker or operating-system keychain and are never serialized into a control-plane command or record.
- Exact account-wide quota, credits, and spend require connection-owner authorization.
- Safe project observation requires current project-participant authorization from the existing participation capability and contains no unrelated account or project values.
- Catalog and quota snapshots are personal data, expire on a short configured lifetime, and are refreshed from the authenticated source rather than treated as durable entitlements.
- Provider output is untrusted. Adapters validate versions, field sets, sizes, value ranges, source labels, and credential-shaped content before projection.

## Interfaces

- Personal connection adapter: authenticate or resolve one worker-local connection, return an opaque reference and safe availability, revoke local credentials, and never return credential material.
- Catalog adapter: fetch from the authenticated provider API Models endpoint or official installed client, return proven model, effort, compatibility, current or default, source, and retrieval facts, or a typed enumeration-unsupported result.
- Quota adapter: return any number of typed general or model-specific buckets, reset facts, paid-continuation facts, source time, and explicit unknown fields without inventing unlimited capacity.
- Official-client usage adapter: query a supported deterministic account or usage surface rather than model prose; a future Claude Code adapter may use supported rate-limit fields or `/usage`, and must treat an unrecognized output version as unknown.
- Runtime-session interface: validate an eligible connection and proven compatible model and effort, record explicit opt-ins and a spending ceiling, pin the configuration, and return an immutable session reference reusable by either consumer kind.
- Runtime-observation interface: append ordered usage and status observations, label provider facts and local estimates, evaluate quota and spending pause conditions, and project owner-exact or participant-safe views.
- Participation interface: consume `capability:project-participation-boundary` for project-run observation without changing membership or Slice 07 authority.
- Future Slice 07 interface: consume `capability:ai-runtime-session` and `capability:ai-runtime-observation` only after an approved `update-spec` defines manifest references, pause, resume, stop, cancellation, and continuation mapping.

## Decisions and Tradeoffs

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

### Immutable Session Configuration

- Choice: Pin connection, model, effort, provenance, version, opt-ins, and ceiling per conversation or run while permitting concurrent sessions on one connection.
- Reason: Active work must remain reproducible and must not change because another session, catalog refresh, or quota view changed.
- Consequence: Changing model or connection creates a linked continuation or new session rather than mutating the original.

### Facts, Estimates, And Unknowns

- Choice: Keep provider-reported facts, worker-observed counters, local estimates, and unknown values distinct through storage and presentation.
- Reason: Estimated cost is useful operationally but is not a provider invoice, and missing quota cannot safely mean unlimited.
- Consequence: Some views show unknown or partially populated values instead of a false precise total.

### Pause Foundation Without Owning Workflow Lifecycles

- Choice: Let the runtime evaluator produce resumable quota and spending pause reasons while deferring Slice 07 state transitions, stop mapping, and continuation to an approved consumer update.
- Reason: Slice 07 owns cancellation authority, branch and workspace preservation, attempts, retry, and terminal outcomes.
- Consequence: The active slice can prove safety decisions and observation without changing guided-delivery behavior.

### One Operational Provider Before Provider Breadth

- Choice: Deliver OpenAI Codex as the first production worker adapter while keeping the contracts provider-neutral.
- Reason: OpenAI Codex is the project's approved primary coding agent, and an executable slice needs a real authenticated catalog and quota path rather than only test doubles.
- Consequence: Claude Code and other providers remain later adapters. They must use officially supported authentication and deterministic usage interfaces; natural-language self-reporting and inferred quota are prohibited.

## Risks

- An opaque reference may still become linkable personal data. Scope it to the owning account and worker, exclude it from analytics and user-visible logs, and delete or revoke it through the connection lifecycle.
- Provider adapters may leak credentials or raw account identifiers inside error text. Use strict typed results, allowlisted fields, size limits, and credential-pattern rejection.
- Catalog caches may present withdrawn models as available. Use short lifetimes, source timestamps, refresh before session creation, and fail closed on unknown compatibility.
- Quota shapes may evolve. Preserve arbitrary typed buckets and unknown fields instead of rejecting new safe buckets or forcing them into fixed plan semantics.
- Concurrent sessions may overspend against stale quota. Apply per-session ceilings before chargeable work and treat provider quota as observed availability, not a transaction lock.
- Cost estimates may be mistaken for exact charges. Store their calculation basis and label them as estimates in every projection.
- Participant views may expose an owner's account-wide quota or spend. Derive a separate safe projection and prove forbidden fields are absent, not merely hidden in the UI.
- A consumer may interpret runtime pause as Slice 07 cancellation or failure. Require a later `update-spec` and contract tests before lifecycle integration.

## Open Questions

- None.
