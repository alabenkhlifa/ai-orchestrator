# Guided Delivery Operational Retention Tasks

## Status

Not Started

Product readiness: `Approved`. Design readiness: `Approved`. Implementation readiness: ready to start; every required capability is available and Task 1 is executable. Verification readiness: not started. Release readiness: no release gate applies to this slice.

The task plan was reconciled with `specs/18-guided-delivery-data-protection-controls`' processing inventory, which is the authoritative classification of what this specification's lifecycle owns.

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

One coherent outcome — inactive guided-delivery execution mechanics and operational-security logs are gone within 30 days — through one verification gate, ten tasks total, and a longest `Depends on:` path of five tasks (`Task 1 → Task 2 → Task 10 → Task 3 → Task 5`). Both are inside the standard limits.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- The hosted rule (Task 1), the device rule (Task 6), and the worker-local rule (Task 7) are separate tasks because they are three different mechanisms — a row delete, a tombstone commit through the device seam, and a local file rewrite — that fail independently and are proved independently. Combining them would hide a device or worker failure behind a passing hosted assertion.
- Artifact expiry splits hosted (Task 2) from device (Task 10) for the same reason: the hosted half queries the `evidence` table while the device half enumerates the device store, so the two enumerations fail independently even though they share one deletion seam.
- Each remaining lifecycle owns its own task because its eligibility signal is different: supersession for artifacts (Task 2), expiry and cleanup state for preview deployments (Task 8), and attempt terminality for lease material (Task 9).
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Thirty-day temporary execution-data selection and deletion under hosted and device authority.
- Thirty-day superseded-artifact byte deletion with immutable provenance preservation.
- Thirty-day preview-deployment and attempt-lease cleanup.
- Thirty-day removal of the worker-local provider-thread reference.
- Locked retention execution with durable per-rule outcome, restart, and reconciliation.
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

- [x] Task 1 — Enforce hosted temporary execution-data expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Delete inactive command payloads and checkpoints from the hosted store once their recovery and diagnostic purpose has ended, together with the transient result and failure detail they carry.
  - Owned surfaces: The purpose-ended signal for `run_commands` and `blocking_questions`, the shared 30-day window constant, the hosted eligibility selectors, the active-run and current-recovery exclusion, registration of the rule in the shared prune pass, and hosted fixtures. Both a `run_commands` row and a resolved `blocking_questions` row are deleted outright. Neither is participant-visible history: `run_commands` carries only execution mechanics, and a blocking question is the worker's resume aid whose human-readable question and answer are duplicated into `activity_entries`, which `specs/21-guided-delivery-deletion-and-recovery` owns and this slice does not touch. The only reader of `blocking_questions` filters `state == "open"`, so an expired resolved row is invisible to every surface.
  - Owns: AC-01
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/delivery_temporary_retention_test.exs` passes focused day-29 and day-30 boundary, acknowledged and failed command, resolved checkpoint, active-run exclusion, current-recovery exclusion, transient result and failure-code removal, and idempotent-repeat cases.

- [x] Task 6 — Enforce device temporary execution-data expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Apply the same boundary to a device-authoritative project through the device seam, without ever creating a hosted copy of device data to do it.
  - Owned surfaces: Device eligibility resolution inside the device authority, the tombstone commit for expired command and checkpoint records, the unreachable-device pause, and device fixtures.
  - Owns: AC-06
  - Proof: `python3 .agents/scripts/run_proof.py task --task 6 -- mix test test/sdd_orchestrator/privacy/delivery_device_temporary_retention_test.exs` passes focused device day-29 and day-30, tombstone-not-delete, unreachable-device pause, no-hosted-copy assertion, and repeat cases.

- [x] Task 2 — Enforce hosted superseded-artifact expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Remove unnecessary superseded artifact bytes from the hosted store without rewriting accepted evidence or immutable proof history.
  - Owned surfaces: Superseded-artifact eligibility from the replacement row's `inserted_at`, the 30-day boundary, the private artifact delete operation, accepted and current artifact preservation, immutable evidence-row preservation, the unavailable-artifact presentation seam, digest-safe deletion where two evidence rows share one artifact, and hosted fixtures.
  - Owns: AC-02
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/delivery_artifact_retention_test.exs` passes focused superseded, accepted, current, day-29, day-30, shared-digest survival, byte-deletion, provenance-preservation, and unavailable-presentation cases.

- [ ] Task 10 — Enforce device superseded-artifact expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Apply the same artifact boundary inside a device-authoritative project, where evidence lives in the device store rather than the hosted table.
  - Owned surfaces: Device evidence enumeration, eligibility from the replacement record's `recorded_at`, the device artifact tombstone, the same digest-safe check within the project, the no-hosted-copy guarantee, and device fixtures.
  - Owns: AC-10
  - Proof: `python3 .agents/scripts/run_proof.py task --task 10 -- mix test test/sdd_orchestrator/privacy/delivery_device_artifact_retention_test.exs` passes focused device superseded, day-29, day-30, shared-digest survival, tombstone-not-delete, no-hosted-copy, unreachable-device pause, and repeat cases.

- [ ] Task 8 — Enforce preview-deployment expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Remove expired and superseded preview deployments, which already carry their own expiry and cleanup state, once they are 30 days past use.
  - Owned surfaces: Preview-deployment eligibility from expiry, supersession, and cleanup state, the 30-day boundary, deletion of the deployment record, preservation of the feature, run, and evidence it belonged to, and preview fixtures.
  - Owns: AC-08
  - Proof: `python3 .agents/scripts/run_proof.py task --task 8 -- mix test test/sdd_orchestrator/privacy/delivery_preview_retention_test.exs` passes focused expired, superseded, still-ready exclusion, day-29, day-30, cleanup-state, and owning-record preservation cases.

- [ ] Task 9 — Clear spent attempt-lease material.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Blank the lease owner, lease expiry, and fence token of a terminal attempt without touching the attempt itself, which is participant-visible history owned elsewhere.
  - Owned surfaces: Terminal-attempt eligibility, the 30-day boundary, the in-place clearing of the three lease columns, non-deletion of the attempt row, non-mutation of its participant-visible outcome, and attempt fixtures.
  - Owns: AC-09
  - Proof: `python3 .agents/scripts/run_proof.py task --task 9 -- mix test test/sdd_orchestrator/privacy/delivery_attempt_lease_retention_test.exs` passes focused terminal, non-terminal exclusion, day-29, day-30, row-preservation, outcome-preservation, and idempotent-repeat cases.

- [x] Task 7 — Expire the worker-local provider-thread reference.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Remove the provider-thread reference from the device, which is the only place it exists, once its run is terminal and 30 days have passed.
  - Owned surfaces: The terminal-lifecycle and age check over the worker's own run state, removal of the provider-thread reference from the current and previous slots, the rewrite of the local run-state file with its existing permissions, non-mutation of the run's participant-visible history, and worker run-state fixtures.
  - Owns: AC-07
  - Proof: `python3 .agents/scripts/run_proof.py task --task 7 -- mix test test/sdd_orchestrator/worker/run_state_retention_test.exs` passes focused terminal, non-terminal exclusion, day-29, day-30, previous-slot, file-permission, missing-file, and history-unchanged cases.

- [ ] Task 3 — Deliver locked retention execution, durable rule outcome, and reconciliation.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2, Task 6, Task 8, Task 9, Task 10
  - Purpose: Apply this slice's retention rules safely under repeats, concurrent schedulers, process restart, and partial failure, and make a failed or interrupted rule discoverable instead of silent.
  - Owned surfaces: The `RetentionRuleOutcome` record and its migration, shared retention-rule registration, the per-rule advisory lock, the idempotent prune result, rule-level failure state and attempt count, restart discovery, hosted and device reconciliation, retry, minimized retention diagnostics, fixtures, and deleted-data non-restoration.
  - Owns: AC-03, entity:RetentionRuleOutcome
  - Proof: `python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/privacy/delivery_retention_runner_test.exs` passes focused duplicate, lock-contention, injected-failure, attempt-count, restart-discovery, retry, reconciliation, minimized-diagnostic, and non-restoration cases.

- [x] Task 4 — Enforce minimized Slice 07 security logs.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Preserve only the structured minimum security evidence needed for short-lived operational diagnosis, in a sink that can actually be pruned.
  - Owned surfaces: The Slice 07 security-event type allowlist, the fixed field schema and its persisted record, the non-secret correlation reference, outcome and occurrence time, worker, provider, authorization and retention event minimization, credential, email and project-content rejection, typed refusal, fixtures, and diagnostic scans.
  - Owns: AC-04
  - Proof: `python3 .agents/scripts/run_proof.py task --task 4 -- mix test test/sdd_orchestrator/privacy/delivery_security_log_test.exs` passes focused event-allowlist, field-allowlist, correlation, credential, email, feature, specification, prompt, output, evidence, provider-payload, failure, and diagnostic-scan cases.

- [ ] Task 5 — Enforce security-log expiry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3, Task 4
  - Purpose: Delete Slice 07 operational-security records at 30 days without changing authoritative delivery or access state.
  - Owned surfaces: Slice 07 security-log selection, the 30-day boundary, shared retention-runner integration, project and event filtering, idempotent deletion, lock, restart, reconciliation, delivery-state non-mutation, authorization non-mutation, fixtures, the `capability:guided-delivery-operational-retention` provider, and the readiness write-back.
  - Owns: AC-05
  - Proof: `python3 .agents/scripts/run_proof.py task --task 5 -- mix test test/sdd_orchestrator/privacy/delivery_security_log_retention_test.exs` passes focused day-29 and day-30, project, event, idempotency, lock, restart, reconciliation, feature, run, evidence, and authorization non-mutation cases.

## Verification Gate

- [ ] All ten acceptance criteria pass against hosted, device, and worker-local authority where applicable.
- [ ] Active recovery state, accepted evidence, attempt rows, and participant-visible history remain available after every retention rule.
- [ ] Security-log field allowlists and content, credential, and email negative scans pass.
- [ ] Retention lock, restart, partial-failure, retry, and reconciliation scenarios pass, and a failed rule is discoverable through its durable outcome record.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass for the repository browser matrix.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.
- [ ] New decisions and proof receipts are written back.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
