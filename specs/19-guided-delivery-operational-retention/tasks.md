# Guided Delivery Operational Retention Tasks

## Status

Blocked

Implementation depends on the published guided-delivery data surfaces and `capability:guided-delivery-processing-controls`, which are not yet ready. The required project-storage governance capability is already available.

## Active Slice

Delete inactive temporary execution mechanics, superseded artifact bytes, and minimized operational-security logs on their approved 30-day schedules through locked, restart-safe hosted and device retention behavior.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 1`.
- `capability:guided-delivery-data-surfaces` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-processing-controls` — provider `specs/18-guided-delivery-data-protection-controls#Task 4` — required before `Task 1`.

Provides:

- `capability:guided-delivery-operational-retention` — ready after `Task 5`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Thirty-day temporary execution-data selection and deletion.
- Thirty-day superseded-artifact byte deletion with immutable provenance preservation.
- Locked hosted and device retention execution, restart, and reconciliation.
- Minimized structured Slice 07 security logs and their 30-day expiry.

Excluded:

- Notification, relay, cache, backup, project-deletion, rights, anonymization, processor, or transfer lifecycles.
- Deletion of active state, accepted evidence, participant-visible history, or project authorization.
- Product analytics or stable operational profiles.

Deferred after this slice:

- Notification retention, device relay and cache retention, project deletion and recovery, rights, anonymization, and deployment governance in their focused specifications.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Enforce temporary execution-data selection and expiry.
  - Size: Standard
  - Proof scope: Focused
  - Status: Blocked until `capability:guided-delivery-data-surfaces` and `capability:guided-delivery-processing-controls` are ready.
  - Depends on: none
  - Purpose: Delete inactive command payloads, checkpoints, provider-thread references, and transient logs after their recovery or diagnostic purpose ends.
  - Owned surfaces: Purpose-ended timestamps and selectors for command payloads, checkpoints, provider-thread references and transient logs, 30-day boundary, active run and current recovery exclusion, hosted and device authority operations, fixtures, and no-hosted-device-copy behavior.
  - Owns: AC-01
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/delivery_temporary_retention_test.exs` passes focused 29-day and 30-day, command, checkpoint, provider-thread, transient-log, active-run, current-recovery, hosted, device, and no-copy cases.

- [ ] Task 2 — Enforce superseded-artifact expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Remove unnecessary superseded artifact bytes without rewriting accepted evidence or immutable proof history.
  - Owned surfaces: Superseded-artifact eligibility, 30-day purpose-ended boundary, private artifact delete operation, accepted and current artifact preservation, immutable evidence-row preservation, unavailable-artifact presentation seam, hosted and device fixtures, and digest-safe deletion.
  - Owns: AC-02
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/delivery_artifact_retention_test.exs` passes focused superseded, accepted, current, 29-day, 30-day, hosted, device, byte deletion, provenance preservation, and unavailable-presentation cases.

- [ ] Task 3 — Deliver locked retention execution and reconciliation.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2
  - Purpose: Apply temporary-data retention safely under repeats, concurrent schedulers, process restart, and partial failure.
  - Owned surfaces: Shared retention-rule registration, distributed or database lock use, idempotent prune result, rule-level failure state, restart discovery, hosted and device reconciliation, retry, minimized retention diagnostics, fixtures, and deleted-data non-restoration.
  - Owns: AC-03
  - Proof: `python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/privacy/delivery_retention_runner_test.exs` passes focused duplicate, lock, concurrency, injected failure, restart, retry, reconciliation, hosted, device, minimized diagnostic, and non-restoration cases.

- [ ] Task 4 — Enforce minimized Slice 07 security logs.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Preserve only the structured minimum security evidence needed for short-lived operational diagnosis.
  - Owned surfaces: Slice 07 security-event type allowlist, fixed field schema, non-secret correlation reference, outcome and occurrence time, worker, provider, authorization and retention event minimization, credential, email and project-content rejection, typed refusal, fixtures, and diagnostic scans.
  - Owns: AC-04
  - Proof: `python3 .agents/scripts/run_proof.py task --task 4 -- mix test test/sdd_orchestrator/privacy/delivery_security_log_test.exs` passes focused event, field-allowlist, correlation, credential, email, feature, specification, prompt, output, evidence, provider-payload, failure, and diagnostic-scan cases.

- [ ] Task 5 — Enforce security-log expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3, Task 4
  - Purpose: Delete Slice 07 operational-security records at 30 days without changing authoritative delivery or access state.
  - Owned surfaces: Slice 07 security-log selection, 30-day boundary, shared retention-runner integration, project and event filtering, idempotent deletion, lock, restart, reconciliation, delivery-state non-mutation, authorization non-mutation, fixtures, `capability:guided-delivery-operational-retention` provider, and readiness write-back.
  - Owns: AC-05
  - Proof: `python3 .agents/scripts/run_proof.py task --task 5 -- mix test test/sdd_orchestrator/privacy/delivery_security_log_retention_test.exs` passes focused 29-day and 30-day, project, event, idempotency, lock, restart, reconciliation, feature, run, evidence, and authorization non-mutation cases.

## Verification Gate

- [ ] All five acceptance criteria pass against hosted and device authority where applicable.
- [ ] Active recovery state and accepted evidence remain available after every retention rule.
- [ ] Security-log field allowlists and content, credential, and email negative scans pass.
- [ ] Retention lock, restart, partial-failure, retry, and reconciliation scenarios pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass for the repository browser matrix.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.
- [ ] New decisions and proof receipts are written back.

## Blocked Decisions

- Active-slice implementation is blocked until `capability:guided-delivery-data-surfaces` and `capability:guided-delivery-processing-controls` are ready; no product or technical-design decision is unresolved.

## Progress Log

### 2026-08-02 — Focused child specification created

- Completed: Moved unfinished temporary execution-data and security-log retention out of the Slice 07 umbrella without changing approved lifecycle behavior.
- Remaining: Publish the data-surface and processing-control capabilities, then implement Tasks 1 through 5 and the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass; implementation has not started because required provider capabilities are unavailable.
- Proof receipts: None.
- Spec updates: Added focused ownership for temporary data, artifact expiry, retention reconciliation, structured security logs, and log expiry.
