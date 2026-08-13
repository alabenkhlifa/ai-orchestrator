# Participation Data Protection Controls Tasks

## Status

In Progress

All five tasks are complete and locally proven. `capability:participation-processing-controls` is ready. The verification gate is next.

## Active Slice

Classify every participation activity and transfer, enforce project, operations, and exceptional-support access, exclude credentials, secrets, and unauthorized content, and prohibit secondary use and linkable analytics without implementing provider-owned participation lifecycles.

## Cross-Specification Dependencies

Requires:

- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:participation-identity-lifecycle` — provider `specs/25-participation-identity-lifecycle#Task 4` — required before `Task 1`.

Provides:

- `capability:participation-processing-controls` — ready after `Task 5`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- All five tasks are `Size: Standard`: each owns one independently provable privacy invariant, no task owns more than one acceptance criterion or one data entity, and each has one focused proof command.
- No task-size exception is used; repository-wide security, dependency, browser, production, and integration proof remains at the slice verification gate.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Participation processing-inventory entries and purpose, basis, lifecycle-owner, processor, transfer, and review validation.
- Owner, participant, minimized operations, and exceptional-support access policies.
- Account-neutral invitation and identity enumeration denial.
- Credential, secret, project-content, participant-email, unrelated-identity, processor, transfer, and destination minimization.
- Negative advertising, model-training, unrelated-improvement, secondary-use, linkable-profile, and product-analytics controls.
- Genuinely anonymous aggregate input boundary.

Excluded:

- Provider-owned invitation, acceptance, re-invitation, participation, profile, revocation, notification, delivery, retention, deletion, rights, anonymization, backup, and release-governance behavior.
- Changes to the authoritative participation boundary or identity-lifecycle contracts.
- Product analytics implementation, production deployment, processor selection, legal conclusions, or release approval.

Deferred after this slice:

- Any future approved genuinely anonymous aggregate measurement implementation.
- New participation roles, organization access, standing support roles, or additional processor categories.

Release gates:

- Deployment-specific controller identity, processors and agreements, hosting, email, logging, support and backup regions, cross-border transfers and safeguards, notices, incident evidence, DPIA or legal assessment where required, and accountable privacy and security approval.
- Live processor and transfer enforcement evidence for the selected deployment.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Classify participation processing and transfer activity.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give every participation field and transfer one complete, lifecycle-consistent purpose, basis, authority, recipient, processor, transfer, and review classification.
  - Owned surfaces: `ParticipationProcessingRecord` participation activities, processing-inventory completeness, contract-necessity and legitimate-interest purpose map, personal-data field lists, hosted authority, owner, participant, operations and support recipient classes, final lifecycle-owner references from `capability:participation-identity-lifecycle`, processor categories, minimum processor fields, transfer classifications, review state, invalid and duplicate classification rejection, fixtures, and content-absence checks.
  - Owns: AC-01, entity:ParticipationProcessingRecord
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/participation_processing_inventory_test.exs` passes focused activity-completeness, field, purpose, basis, authority, recipient, lifecycle-provider, processor, minimum-field, transfer, review, invalid-classification, duplicate, and governed-content-absence cases.

- [x] Task 2 — Enforce participation and operations access.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Return only approved project-scoped owner and participant data or minimized operations metadata without exposing account, invitation, identity, or content existence.
  - Owned surfaces: `capability:project-participation-boundary` consumption, immutable-owner and active-participant-first authorization, owner membership-management view, participant own-account and project-label view, minimized operations metadata view, optional presentation lookup, explicit absent-presentation handling, stale, removed, departed, absent and cross-project denial, invitation and identity enumeration resistance, account-neutral errors, fixtures, and no unauthorized content lookup.
  - Owns: AC-02
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/participation_access_controls_test.exs` passes focused owner, participant, operations, absent-presentation, stale, removed, departed, absent, cross-project, invitation, identity, account-neutral denial, project-scope, recipient-minimization, and no-content-lookup cases.

- [x] Task 3 — Enforce exceptional-support access.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2
  - Purpose: Keep support content-free by default and constrain every exceptional access decision to verified, least-privilege, purpose-bound, expiring, revocable, audited scope.
  - Owned surfaces: Metadata-only support default, support-actor verification, exceptional capability issue and validation, incident purpose, project and field scope, least privilege, fixed expiry, immediate revocation, content-existence non-disclosure, minimized audit fields, audit credential, email, secret and project-content exclusion, replay and expiry behavior, and fixtures.
  - Owns: AC-03
  - Proof: `python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/privacy/participation_support_access_test.exs` passes focused default-denial, metadata-only, actor-verification, purpose, scope, least-privilege, issue, expiry, revocation, replay, audit-minimization, non-disclosure, and forbidden-audit-content cases.

- [x] Task 4 — Enforce participation content and destination minimization.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2, Task 3
  - Purpose: Stop credentials, secrets, unauthorized content, and unapproved destinations before participation data crosses a persistence or transmission boundary.
  - Owned surfaces: Participation content field allowlists, typed credential and secret rejection, repository-provider, worker, coding-agent, model-provider, session, invitation and email-delivery credential-transfer denial, unauthorized project-content exclusion, out-of-context participant-email and unrelated-identity exclusion, processor and transfer destination allowlists, diagnostic field-name-only errors, negative persistence and transmission scans, and fixtures.
  - Owns: AC-04
  - Proof: `python3 .agents/scripts/run_proof.py task --task 4 -- mix test test/sdd_orchestrator/privacy/participation_content_boundary_test.exs` passes focused field-allowlist, credential, secret, project-content, participant-email, unrelated-identity, processor, transfer, destination, persistence, transmission, diagnostic, and no-live-provider cases.

- [x] Task 5 — Prohibit participation secondary use and linkable analytics.
  - Status: Complete. `capability:participation-processing-controls` ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 4
  - Purpose: Keep participation data out of advertising, training, unrelated-improvement, product-analytics, and stable-profile paths and publish the processing-control capability.
  - Owned surfaces: Advertising, model-training, unrelated-improvement, product-analytics, stable-profile and secondary-use denial, store, request, event, metric and destination negative scans, operational-telemetry governed-data classification, genuinely anonymous aggregate input contract, raw participation and stable-identifier rejection, fixtures, `capability:participation-processing-controls` provider, and readiness write-back.
  - Owns: AC-05
  - Proof: `python3 .agents/scripts/run_proof.py task --task 5 -- mix test test/sdd_orchestrator/privacy/participation_purpose_limitation_test.exs` passes focused advertising, training, unrelated-use, analytics store, request, event, metric, destination, stable-profile, operational-telemetry, anonymous-aggregate, raw-input, stable-identifier, readiness, and no-live-provider cases.

## Verification Gate

- [ ] All five acceptance criteria and the complete `ParticipationProcessingRecord` traceability map pass.
- [ ] Every participation activity and transfer has one lifecycle-consistent purpose, basis, authority, recipient, minimum-field, processor, transfer, and review classification.
- [ ] Owner, participant, operations, stale, removed, departed, absent, cross-project, and exceptional-support paths authorize or deny exactly as approved without enumeration disclosure.
- [ ] Credential, secret, unauthorized project-content, out-of-context participant-email, unrelated-identity, processor, transfer, persistence, and transmission negative scans pass.
- [ ] No advertising, model-training reuse, unrelated improvement, product analytics, linkable stable profile, or other secondary-use path exists, and aggregate-boundary proof rejects raw or linkable input.
- [ ] Deterministic participation notification, delivery, revocation, rights, retention, and recipient-routing compatibility suites pass through slice scope without changing provider behavior.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` passes.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix format --check-formatted`, `python3 .agents/scripts/run_proof.py slice -- mix compile --warnings-as-errors`, `python3 .agents/scripts/run_proof.py slice -- mix credo --strict`, `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `python3 .agents/scripts/run_proof.py slice -- mix deps.audit`, `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config`, and `python3 .agents/scripts/run_proof.py slice -- mix test` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [ ] The individual specification validator and global cross-specification capability graph pass, the two provider contracts remain authoritative, and the provided capability readiness write-back is recorded.
- [ ] Implementation and local-verification readiness are recorded separately from deployment release readiness.

## Blocked Decisions

- None. `capability:project-participation-boundary` and `capability:participation-identity-lifecycle` are both ready.

## Progress Log

See [progress.md](progress.md).
