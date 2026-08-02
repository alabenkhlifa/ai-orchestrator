# Guided Delivery Deletion And Recovery Tasks

## Status

Blocked

The agreement is approved. Task 1 is blocked until its processing-control, operational-retention, device-retention, notification-governance, and project-storage-governance prerequisites are ready.

## Active Slice

Enforce 35-day recovery-only backup expiry and one fail-closed guided-delivery project-deletion flow across authoritative hosted and device records, configured derived copies, and restricted retryable reconciliation.

## Cross-Specification Dependencies

Requires:

- `capability:guided-delivery-artifact-preview-boundary` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 4`.
- `capability:guided-delivery-notification-governance` — provider `specs/17-guided-delivery-notification-access#Task 5` — required before `Task 1`.
- `capability:guided-delivery-processing-controls` — provider `specs/18-guided-delivery-data-protection-controls#Task 4` — required before `Task 1`.
- `capability:guided-delivery-operational-retention` — provider `specs/19-guided-delivery-operational-retention#Task 5` — required before `Task 1`.
- `capability:guided-delivery-device-transient-retention` — provider `specs/20-guided-delivery-device-data-retention#Task 2` — required before `Task 1`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 1`.

Provides:

- `capability:guided-delivery-project-deletion-governance` — ready after `Task 6`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Every task is `Size: Standard`, owns one deletion, cleanup, recovery, or reconciliation outcome, has at most three acceptance criteria and two entities, and has focused proof expected to run in about ten minutes.
- No task-size exception is used; full repository, browser, security, production, and release proof remains at the slice gates.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Encrypted rolling-backup expiry and tombstone-first recovery.
- Immediate hosted and device-authoritative guided-delivery deletion.
- Preview, artifact, relay, cache, index, and configured processor cleanup requests.
- Restricted idempotent cleanup reconciliation.

Excluded:

- Project deletion authorization and confirmation UX.
- Vendor selection, ownership transfer, legal holds, and active-project individual rights requests.

Deferred after this slice:

- Additional derived-copy adapters not configured for the first release.
- Deferred criteria: none.
- Deferred entities: none.

Release gates:

- Live deletion acknowledgement and enforced expiry evidence for every configured backup, preview, artifact, hosting, cache, index, and processor destination.
- Deployment-specific controller, processor, region, transfer, incident, notice, and accountable privacy or legal review.
- Release criteria: none.
- Release entities: none.

## Tasks

- [ ] Task 1 — Enforce encrypted-backup expiry and recovery-only access.
  - Status: Blocked until `capability:guided-delivery-notification-governance`, `capability:guided-delivery-processing-controls`, `capability:guided-delivery-operational-retention`, `capability:guided-delivery-device-transient-retention`, and `capability:project-storage-governance` are ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Keep guided-delivery backups inside the approved 35-day recovery-only boundary.
  - Owned surfaces: Backup selection, encryption and recovery-only access checks, 35-day expiry, deletion tombstone preservation, restore ordering, fixtures, and negative product and ordinary-support reads.
  - Owns: AC-01
  - Proof: Focused 35-day boundary, encryption-state, product-denial, support-denial, expiry, tombstone-preservation, and restore-order tests pass through task scope.

- [ ] Task 2 — Delete authoritative hosted guided-delivery records.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Remove hosted delivery state without delaying immediate access denial.
  - Owned surfaces: Project-deletion event consumer, hosted delivery-record selection, immediate authorization denial assertion, transactional deletion batches, idempotency, restart behavior, and fixtures.
  - Owns: AC-02
  - Proof: Focused deletion-event, immediate-denial, hosted-record, repeat, partial-batch, restart, and project-isolation tests pass through task scope.

- [ ] Task 3 — Delete authoritative device guided-delivery records.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Remove device-authoritative delivery state without creating a hosted copy.
  - Owned surfaces: Device deletion command, worker authorization, local delivery-store deletion, offline and restart handling, idempotency, hosted-store negative scan, and fixtures.
  - Owns: AC-03
  - Proof: Focused authorized-worker, offline, reconnect, restart, repeat, local-deletion, and no-hosted-copy tests pass through task scope.

- [ ] Task 4 — Delete preview and artifact copies with restricted failure state.
  - Status: Blocked until `capability:guided-delivery-artifact-preview-boundary` is ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Remove configured preview and artifact copies without retaining their content in cleanup state.
  - Owned surfaces: Preview and artifact deletion adapters, opaque target references, idempotency keys, acknowledgement normalization, `ProjectCleanupReconciliation`, restricted access, content-free error state, fixtures, and rollback.
  - Owns: AC-04, entity:ProjectCleanupReconciliation
  - Proof: Focused preview, artifact, duplicate, acknowledgement, failure, restricted-access, forbidden-content, and rollback tests pass through task scope.

- [ ] Task 5 — Delete cache, index, and configured processor copies.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Propagate deletion to the remaining configured derived-copy destinations.
  - Owned surfaces: Relay, cache, index, and processor deletion adapters, minimum request allowlist, destination registry, idempotency, acknowledgement normalization, content-negative scan, and fixtures.
  - Owns: AC-05
  - Proof: Focused destination-registry, relay, cache, index, processor, duplicate, minimum-request, and forbidden-content tests pass through task scope.

- [ ] Task 6 — Reconcile incomplete cleanup without restoring access.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Finish interrupted deletion safely across retries, restarts, and backup recovery.
  - Owned surfaces: Reconciliation claim and lock, retry policy, acknowledgement preservation, terminal and retryable error states, restart and recovery resume, access-denial invariant, operations projection, `capability:guided-delivery-project-deletion-governance` provider, and readiness write-back.
  - Owns: AC-06
  - Proof: Focused retry, lock, concurrent worker, restart, backup restore, acknowledgement preservation, permanent failure, access denial, and capability-readiness tests pass through task scope.

## Verification Gate

- [ ] All acceptance criteria pass across hosted and device-authoritative modes.
- [ ] Backup expiry, tombstone-first recovery, immediate denial, derived-copy cleanup, and restricted reconciliation suites pass.
- [ ] Privacy, authorization, redaction, idempotency, restart, and no-restored-access suites pass.
- [ ] `mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice-scoped proof-runner invocations.
- [ ] `npm --prefix assets ci` and the desktop and mobile browser matrix pass through slice scope.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.

## Blocked Decisions

- Task 1 is blocked on unavailable provider capabilities; no product decision is unresolved.

## Progress Log

### 2026-08-02 - Focused deletion and recovery slice created

- Completed: Approved the backup, authoritative hosted and device deletion, configured derived-copy cleanup, restricted reconciliation, and no-restored-access contracts split from the Slice 07 legacy plan.
- Scope classification: Standard focused slice with six tasks and a six-task critical path.
- Remaining: Wait for the named provider capabilities, then implement Tasks 1–6 and complete the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass with the coordinated continuation-specification update.
- Spec updates: Created requirements, design, capability ownership, task proof scope, traceability, and release boundaries for deletion and recovery.
