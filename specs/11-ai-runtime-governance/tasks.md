# AI Runtime Governance Tasks

## Status

Not Started

The product and provider-neutral design agreements are approved. The active slice can begin with the personal connection boundary. Project-shared funding and Slice 07 lifecycle integration are deferred to focused follow-up specifications.

## Active Slice

Deliver the smallest provider-neutral foundation plus one operational OpenAI Codex worker adapter that registers a credential-local personal AI connection, retrieves a live proven model catalog and arbitrary quota facts through supported official-client interfaces, pins one compatible connection, model, and effort configuration for support or working-agent execution, enforces explicit scarcity and spending choices, and presents access-safe per-agent runtime observations.

## Cross-Specification Dependencies

Requires:

- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 5`.

Provides:

- `capability:ai-runtime-session` — ready after `Task 4`.
- `capability:ai-runtime-observation` — ready after `Task 5`.
- `capability:ai-runtime-governance` — ready after `Task 6`.

## Task Size Gate

- Every task is standard, owns one primary outcome, and is expected to produce one focused task-boundary commit.
- No task owns more than three active acceptance criteria or two data entities.
- Provider-specific production adapters, shared project funding, and workflow lifecycle integration are separate split signals and remain outside this active slice.
- No task-size exception is used.

## Implementation Boundary

Included:

- Opaque personal connection registration and worker-local credential contract.
- One operational OpenAI Codex adapter using supported official-client account, model, and rate-limit interfaces.
- Provider-neutral live model catalog and compatibility adapter with enumeration-unsupported behavior.
- Open quota-bucket normalization, explicit scarcity and paid-use choices, and a personal API per-session spending ceiling evaluator.
- Immutable support or working-agent runtime-session configuration with concurrent connection reuse.
- Per-agent usage, cost estimate, quota, and status observation with owner-exact and participant-safe projections.
- Active-slice privacy, lifecycle, security, retention, rights, logging, and no-analytics controls.

Excluded:

- Production provider adapters beyond the first OpenAI Codex adapter.
- Project-shared connections, permissions, project budgets, and project-funded per-run ceilings.
- Slice 07 manifests, commands, run transitions, pause, resume, stop, retry, cancellation, or continuation changes.
- Support-assistant conversation persistence or full consumer UI.
- Provider billing, subscription, credit purchase, or resale.

Deferred after this slice:

- Shared project API connection, participant permission, project budget, and per-run ceiling workflow.
- Explicit personal-versus-shared connection choice when both are eligible.
- Slice 07 `update-spec` and implementation for runtime-session manifest binding, quota and spending pause, resume after reset, initiator-or-owner stop, and linked continuation on an approved different model.
- Support-assistant conversation and runtime-control consumer UI.
- Production adapters for each approved provider and official client.
- Claude Code catalog and quota discovery through officially supported client interfaces, with versioned `/usage` parsing only when no structured supported surface exists.

Release gates:

- Actual provider and client versions, OAuth or API-key terms, processors, regions, transfer safeguards, retention and training-use settings, price sources, notices, incident handling, credential-revocation proof, enforced deletion and cache expiry, live adapter smoke tests, and final accountable privacy, security, and legal review.

Traceability:

- Deferred criteria: AC-08, AC-10, AC-11, AC-12
- Release criteria: none.
- Deferred entities: entity:SharedProjectAIConnection, entity:ProjectAIBudget, entity:RuntimeContinuation
- Release entities: none.

## Tasks

- [ ] Task 1 — Establish credential-local personal AI connections.
  - Size: Standard
  - Depends on: none
  - Purpose: Give support and working-agent consumers one personal provider reference without moving credentials into the control plane.
  - Owned surfaces: `PersonalAIConnection`, worker-local authentication and revocation adapter contract, first operational OpenAI Codex account adapter, opaque account and worker scoping, safe availability, unavailable-worker failure, no-funded-fallback enforcement, credential and raw-account-field exclusion, fixtures, and deterministic adapter double.
  - Owns: AC-01, entity:PersonalAIConnection
  - Proof: Focused account ownership, worker scoping, opaque reference, Codex ChatGPT-sign-in and API-key account modes through supported official-client interfaces, availability, unavailable worker, revocation, credential absence, raw account-field absence, no fallback, support-consumer, working-agent-consumer, and adapter-contract tests pass.

- [ ] Task 2 — Deliver live model catalog and compatible effort selection.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Present only models and effort choices proven by the authenticated provider boundary.
  - Owned surfaces: `ModelCatalogSnapshot`, provider-neutral catalog adapter, operational Codex model and effort discovery, API Models or official-client source type, live refresh, current and default designation, model and effort compatibility, enumeration-unsupported result, unknown-compatibility denial, provenance, expiry, input and output validation, fixtures, and deterministic adapter double.
  - Owns: AC-02, AC-03, entity:ModelCatalogSnapshot
  - Proof: Focused live enumeration, official-client, no-hardcode, no-plan-inference, current, default, effort, compatible, unknown, unsupported, stale, malformed, oversized, provenance, and deterministic adapter tests pass.

- [ ] Task 3 — Normalize quota and enforce explicit cost boundaries.
  - Size: Standard
  - Depends on: Task 2
  - Purpose: Fail closed on scarce or unknown capacity and pause before unapproved or over-ceiling spending.
  - Owned surfaces: `QuotaSnapshot`, operational Codex account rate-limit discovery, arbitrary general and model-specific buckets, reset and paid-continuation facts, unknown values, applicability evaluation, scarcity opt-in, model-specific opt-in, paid-continuation approval, no silent fallback, no silent paid use, personal API session ceiling evaluation, resumable pause decision, fixtures, and deterministic quota adapter.
  - Owns: AC-04, AC-05, AC-06, entity:QuotaSnapshot
  - Proof: Focused arbitrary-bucket, general, model-specific, reset, credit, paid-continuation, missing, unknown, scarcity, opt-in, no-fallback, no-paid-use, below-limit, at-limit, concurrent observation, pause, and preserved-state decision tests pass.

- [ ] Task 4 — Pin provider-neutral runtime sessions.
  - Size: Standard
  - Depends on: Task 3
  - Purpose: Bind support conversations and working-agent runs to one reproducible configuration without preventing concurrent connection reuse.
  - Owned surfaces: `AIRuntimeSession`, support and working-agent consumer kinds, connection eligibility, model and effort compatibility revalidation, catalog provenance, immutable configuration version, explicit opt-in references, personal spending ceiling, concurrent reuse, stale catalog refusal, idempotent creation, fixtures, and `capability:ai-runtime-session` readiness write-back.
  - Owns: AC-07, AC-14, entity:AIRuntimeSession
  - Proof: Focused support, working agent, connection, model, effort, provenance, version, opt-in, ceiling, immutable pin, concurrent reuse, stale, incompatible, unknown, idempotent, and capability-contract tests pass before readiness is recorded.

- [ ] Task 5 — Present access-safe per-agent runtime observation.
  - Size: Standard
  - Depends on: Task 4
  - Purpose: Show useful live operations without presenting estimates as facts or exposing the connection owner's account-wide provider data.
  - Owned surfaces: `AgentRuntimeObservation`, ordered per-agent elapsed time, token counters, estimated cost and basis, applicable quota references, available, constrained, paused and unknown statuses, provider-fact and estimate labels, owner-exact projection, current-participant safe project projection, cross-project and stale-participant denial, fixtures, responsive accessible operational view, and `capability:ai-runtime-observation` readiness write-back.
  - Owns: AC-09, AC-13, entity:AgentRuntimeObservation
  - Proof: Focused ordering, elapsed time, token, cost basis, quota, status, provider fact, estimate, unknown, owner, participant, forbidden-field absence, stale, removed, cross-project, support, working-agent, desktop, mobile, and capability-contract tests pass before readiness is recorded.

- [ ] Task 6 — Enforce active-slice privacy, lifecycle, and security controls.
  - Size: Standard
  - Depends on: Task 5
  - Purpose: Verify the runtime foundation remains credential-local, purpose-limited, minimized, access-controlled, and governed through deletion and rights handling.
  - Owned surfaces: `capability:ai-runtime-governance` provider and readiness write-back, active-slice processing inventory and field-purpose map, contract-necessity and service-security bases, connection removal, credential revocation acknowledgement, catalog and quota cache expiry, observation retention, project deletion integration, access and rights handling, processor and transfer inventory, content-free operational logs, backup exclusion or expiry, no analytics, no secondary use, fixtures, and local privacy and security review.
  - Owns: AC-15
  - Proof: Focused inventory, purpose, minimization, credential locality, owner and participant access, revocation, deletion, cache expiry, retention, rights, processor, transfer, log, backup, analytics, secondary-use, secret scan, and privacy and security review checks pass before `capability:ai-runtime-governance` readiness is recorded.

## Verification Gate

- [ ] Active-slice acceptance criteria pass and deferred criteria remain unimplemented.
- [ ] Every active acceptance criterion and data entity has one primary task owner.
- [ ] Personal credentials remain worker or keychain-local and forbidden-field scans find no credential or raw provider-account value in control-plane records, commands, logs, backups, exports, or UI.
- [ ] Catalog tests prove live authenticated source provenance, no hardcoded or plan-inferred models, limited unsupported behavior, compatibility enforcement, and expiry.
- [ ] Quota tests prove arbitrary buckets, unknown handling, explicit scarcity and paid-use consent, no silent fallback, and spending-ceiling pause before excess chargeable work.
- [ ] Runtime-session tests prove immutable pinning for both consumer kinds, idempotency, and concurrent connection reuse.
- [ ] Observation tests prove ordered per-agent status, fact-versus-estimate labels, owner-exact access, participant-safe projection, and cross-project denial.
- [ ] A live OpenAI Codex smoke test proves supported account, model, effort, general quota, and model-specific quota discovery without exposing credentials or asking the model to self-report usage.
- [ ] Privacy, security, retention, deletion, rights, processor, transfer, no-analytics, and no-secondary-use checks pass locally.
- [ ] `python3 .agents/scripts/test_validate_spec.py` passes.
- [ ] `python3 .agents/scripts/validate_spec.py specs/11-ai-runtime-governance` passes.
- [ ] `python3 .agents/scripts/validate_spec.py --all specs` passes.
- [ ] `git diff --check` passes.
- [ ] Production adapter and deployment-dependent evidence remains in the release gate.

## Blocked Decisions

- None.

## Progress Log

### 2026-07-31 - Provider-neutral runtime foundation approved

- Completed: Approved personal connection ownership, credential locality, live catalog provenance, unsupported-catalog behavior, model and effort selection, arbitrary quota buckets, explicit scarcity and paid-use consent, no silent fallback, per-session spending ceilings, immutable configuration pinning, concurrent reuse, operational observation, and access-safe visibility.
- Remaining: Implement Tasks 1 through 6, publish the two capabilities at Tasks 4 and 5, add focused project-shared funding and support consumers, and update Slice 07 before lifecycle integration.
- Failed checks: None recorded at creation.
- Spec updates: Created the focused runtime child and limited its active slice to provider-neutral personal connection, catalog, quota, session, observation, and governance foundations.
