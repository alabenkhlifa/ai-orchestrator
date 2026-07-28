# Project Specification Storage Tasks

## Status

In Progress

The product, technical, privacy, task-sequence, and verification contracts are approved. Slice 05 has delivered both required capabilities. Tasks 2, 6, 3, and 4 are complete, and Task 7 is the next executable task.

## Active Slice

Deliver one shared hosted and device-authoritative project-specification store with stable specification identity, immutable complete document-set revisions, optimistic current-head updates, consistent current-project snapshots, and a destination-local restoration transaction seam for Slice 06 and Slice 07.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 2`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 5`.

Provides:

- `capability:project-specification-store` — ready after `Task 8`.
- `capability:project-specification-governance` — ready after `Task 5`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Existing task labels are preserved; newly split tasks use the next unused labels and are listed by dependency order rather than numeric order.

## Implementation Boundary

Included:

- Stable project-scoped specification identity and current revision reference.
- Immutable complete `requirements.md`, `design.md`, and `tasks.md` revisions.
- Hosted PostgreSQL and device-authoritative adapter implementations.
- Authorized create, optimistic append, current retrieval, and consistent snapshot.
- Destination-local same-project restoration transaction participation.
- Validation, configured limits, concurrency, idempotency, isolation, privacy, lifecycle, and adapter-contract proof.

Excluded:

- Feature board, guided editing, readiness, agents, evidence, preview, review, and notifications.
- Backup package format, encryption, delivery, intake, compatibility, conflict workflow, or UI.
- Participant provisioning, assignment, comments, attachments, rich text, and repository source.
- Filesystem scanning, executable content, cross-project copying, merging, or synchronization.

Deferred after this slice:

- Additional logical document types, attachments, comments, and generated artifacts.
- User-facing title uniqueness, rename, editing, and navigation behavior.
- Participant-authorized editing through the later project-participation consumer.
- Deferred criteria: none.
- Deferred entities: none.

Release gates:

- Deployment-specific controller details, hosted and device processors, regions, transfer safeguards, notices, incident handling, enforced deletion and backup expiry, and final accountable privacy or legal review.
- Release criteria: none.
- Release entities: none.

## Tasks

- [x] Task 1 — Approve the shared specification-storage product, technical, privacy, and verification contracts.
  - Size: Standard
  - Depends on: none
  - Purpose: Establish one capability owner and executable contract before backup or delivery implements specification persistence.
  - Owned surfaces: Outcome and scope, stable identity, revision and snapshot semantics, authorization extension seam, hosted and device authority, restoration transaction seam, privacy lifecycle, cross-specification capability, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Proof: Requirements, design, data boundaries, interfaces, capability dependencies, task ownership, sequence, traceability, and verification commands have no unresolved agreement decision.

- [x] Task 2 — Implement hosted specification creation and current retrieval.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Establish the hosted stable specification identity and atomic first complete revision.
  - Owned surfaces: `ProjectSpecification`, `SpecificationRevision`, hosted migrations and schemas, complete document-set validation, stable digest, project-owner authorization seam, create transaction, current retrieval, uniqueness and foreign-key constraints, configured limits, fixtures, and hosted failure behavior.
  - Owns: AC-01, AC-04, AC-07, entity:ProjectSpecification, entity:SpecificationRevision
  - Proof: Focused migration, changeset, authorization, create, current-read, constraint, hostile-text, limit, isolation, rollback, and non-execution tests prove one atomic hosted specification foundation.

- [x] Task 6 — Implement hosted optimistic revision append.
  - Size: Standard
  - Depends on: Task 2
  - Purpose: Advance one hosted specification from an expected current revision without permitting stale or mutable history.
  - Owned surfaces: Expected-current-revision validation, immutable complete revision insert, atomic current-reference advance, stable digest comparison, stale-head rejection, concurrent append serialization, committed retry, fixtures, and rollback.
  - Owns: AC-02
  - Proof: Focused append, immutability, expected-head, stale-writer, concurrency, duplicate-retry, current-reference, constraint, and rollback tests pass.

- [x] Task 3 — Implement the device-authoritative adapter and shared store contract.
  - Size: Standard
  - Depends on: Task 2, Task 6
  - Purpose: Provide equivalent specification behavior without creating a hosted device-project copy.
  - Owned surfaces: `SpecificationStore` behavior, hosted adapter conformance, worker-owned device adapter contract, development device-store persistence, destination ownership checks, device transactions, protocol value shapes, adapter fixtures, no-hosted-copy enforcement, and parity tests.
  - Owns: AC-05
  - Proof: Shared adapter-contract, device persistence, isolation, transaction, restart, concurrency, and negative hosted-copy tests prove equivalent create, append, current-read, validation, and failure behavior in both destinations.

- [x] Task 4 — Implement consistent current-project snapshots.
  - Size: Standard
  - Depends on: Task 3
  - Purpose: Give authorized consumers one deterministic current view from either authoritative destination.
  - Owned surfaces: `SpecificationSnapshot`, deterministic current-project ordering, consistent hosted and device snapshot reads, strict allowlisted snapshot shape, snapshot limits, concurrent-append observation boundary, fixtures, and consumer snapshot contract tests.
  - Owns: AC-03, entity:SpecificationSnapshot
  - Proof: Focused hosted and device snapshot consistency, allowlist, ordering, limit, authorization, concurrent-append, and deterministic fixture tests pass.

- [ ] Task 7 — Implement restoration transaction participation.
  - Size: Standard
  - Depends on: Task 4
  - Purpose: Contribute validated specification state atomically to a caller-owned hosted or device project-creation transaction.
  - Owned surfaces: `SpecificationStore.prepare_restore/4`, hosted `Ecto.Multi` contribution, device transaction contribution, stable specification and revision identity preservation, conflict validation, caller idempotency key, rollback, fault injection, and Slice 06 consumer contract fixtures.
  - Owns: AC-06
  - Proof: Focused hosted and device restore-contract, conflict, replay, idempotency, injected-failure, identity-preservation, and rollback tests prove no partial or duplicate specification state.

- [ ] Task 8 — Enforce cross-operation concurrency and idempotency.
  - Size: Standard
  - Depends on: Task 6, Task 7
  - Purpose: Preserve stable identities and current-head correctness when create, append, snapshot, and restore operations race or retry.
  - Owned surfaces: Cross-operation uniqueness and transaction invariants, concurrent create and append outcomes, snapshot commit boundary, restore replay, committed retry, stale-write rejection, deterministic race fixtures, and `capability:project-specification-store` readiness write-back.
  - Owns: AC-08
  - Proof: Focused create, append, snapshot, and restore race, replay, retry, stale-head, uniqueness, snapshot-consistency, and no-partial-state tests pass before capability readiness is recorded.

- [ ] Task 5 — Enforce lifecycle, privacy, and cross-specification compatibility.
  - Size: Standard
  - Depends on: Task 2, Task 3, Task 4, Task 6, Task 7, Task 8
  - Purpose: Make the capability safe and stable for Slice 06 and Slice 07 consumption.
  - Owned surfaces: Processing inventory, field-purpose map, access and rights integration, project-deletion cascade, device locality, hosted processor boundary, cache and index minimization, structured security logging, 30-day log expiry, 35-day encrypted-backup expiry, no analytics or secondary use, content-redaction scans, Slice 06 snapshot and restore contract fixtures, Slice 07 revision and authorization-extension contract fixtures, `capability:project-specification-governance` readiness write-back, and required privacy and security review.
  - Owns: AC-09, AC-10
  - Proof: Privacy inventory, access, deletion, rights, processor, transfer, retention, log, backup, no-analytics, secret and content exposure, adapter-boundary, and both consumer compatibility suites pass with the required local privacy and security review.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Every active acceptance criterion and data entity has one clear primary task owner.
- [ ] Hosted and device adapters pass the same create, append, current-read, snapshot, validation, concurrency, idempotency, and failure contract.
- [ ] Stable specification and revision identities, immutable complete document sets, expected-head updates, and consistent current snapshots pass transaction and constraint tests.
- [ ] Cross-project, cross-workspace, cross-device, unauthorized, and content-existence disclosure tests fail closed.
- [ ] Device-authoritative specifications create no hosted authoritative or cache copy.
- [ ] Restoration transaction participation preserves stable identities and leaves no partial state under conflict, replay, or injected failure.
- [ ] Slice 06 and Slice 07 compatibility fixtures use the shared capability without a duplicate specification store.
- [ ] Privacy inventory, lifecycle, deletion, rights, processor, transfer, redaction, no-analytics, 30-day log, and 35-day encrypted-backup checks pass.
- [ ] `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [ ] Applicable production build and existing browser regression checks pass.
- [ ] New decisions and invalidated proof are written back.

## Blocked Decisions

- None. Both required Slice 05 capabilities are available, and Task 2 is the next executable task.

## Progress Log

### 2026-07-28 - Task 4 complete: consistent current-project snapshots

- Completed: Added one strict transient `SpecificationSnapshot` allowlist, deterministic specification-id ordering, configured count and byte limits, a single joined hosted current-head query, and a worker-serialized device snapshot read. Snapshots contain only stable specification and current revision identities, titles, and the three approved documents; concurrent append proof observes either complete revision without mixing document fields.
- Remaining: Implement restoration transaction participation in Task 7, then cross-operation readiness, governance, and verification.
- Failed checks: Strict Credo initially rejected one alias ordering in the focused test; it was corrected. Final proof passes: `MIX_ENV=test mix test test/sdd_orchestrator/specifications/snapshot_test.exs` (5 tests), the combined specification suite (23 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 4 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Task 3 complete: device-authoritative specification adapter

- Completed: Extended the worker-owned `DeviceStore` contract and development DETS adapter with atomic one-record specification aggregates, device value shapes matching the shared stable specification and immutable revision contract, create, optimistic append, current retrieval, capacity enforcement, restart durability, cross-device and cross-project authorization, serialized concurrency, and idempotent retry. Device specifications never create a hosted Ecto row or cache copy.
- Remaining: Implement consistent current-project snapshots in Task 4, then restoration participation, cross-operation readiness, governance, and verification.
- Failed checks: None. Final proof passes: the shared hosted and device specification suites (18 tests), existing device-store and registration regressions (18 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 3 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Task 6 complete: hosted optimistic revision append

- Completed: Added `SpecificationStore.append_revision/5` and the hosted locked transaction that requires the expected current revision, inserts one immutable complete revision, atomically advances the current pointer and optional title, preserves the earlier revision, rejects stale or conflicting revision identities, and returns the committed revision on an identical retry.
- Remaining: Implement the device-authoritative adapter and shared contract in Task 3, then snapshots, restoration participation, cross-operation readiness, governance, and verification.
- Failed checks: Strict Credo initially rejected one alias ordering in the focused test; it was corrected. Final proof passes: `MIX_ENV=test mix test test/sdd_orchestrator/specifications/hosted_append_test.exs` (6 tests), the combined hosted suite (14 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 6 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Task 2 complete: hosted specification creation and current retrieval

- Completed: Added the hosted `ProjectSpecification` and immutable `SpecificationRevision` schemas and migration, configured document and aggregate limits, complete-document validation and stable SHA-256 digesting, fail-closed owner authorization, the shared `SpecificationStore` facade, one `Ecto.Multi` for first-revision creation and current-pointer assignment, current retrieval, and focused fixtures. The stored revision accepts hostile-looking text only as inert content and rejects extra path fields, incomplete sets, oversize data, cross-workspace access, and email actor references.
- Remaining: Implement hosted optimistic append in Task 6, then the device adapter, consistent snapshots, restoration participation, concurrency readiness, governance, and the slice verification gate.
- Failed checks: The first focused run exposed an unhandled primary-key constraint and a fixture repository collision; both were corrected. Final proof passes: `MIX_ENV=test mix test test/sdd_orchestrator/specifications/hosted_store_test.exs` (8 tests), migration rollback and reapply, `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 2 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Provider readiness and task size reconciled

- Completed: Confirmed the Slice 05 authority and governance capabilities are ready, applied the Task Size Gate, preserved Tasks 1–5, split hosted append, restore participation, and cross-operation concurrency into Tasks 6–8, and moved the specification-store readiness boundary to Task 8.
- Remaining: Implement Tasks 2, 6, 3, 4, 7, 8, and 5 in dependency order, publish both capabilities at their named task boundaries, validate the Slice 06 and Slice 07 consumer contracts, and run the verification gate.
- Failed checks: The first global graph check rejected missing Slice 05 capability readiness write-backs; those write-backs are now explicit and the graph passes.
- Spec updates: Moved the slice from `Blocked` to `Not Started`, removed stale provider blockers, added standard size declarations with no exception, split independently provable state transitions, and changed the `capability:project-specification-store` provider from Task 4 to Task 8 without changing approved behavior.

### 2026-07-28 - Shared specification-storage foundation approved

- Completed: Extracted stable project-specification identity, immutable complete revisions, current-head updates, hosted and device adapters, consistent snapshots, and restoration transaction participation from the portability and guided-delivery consumers into one focused shared capability.
- Remaining: Complete Slice 05 Task 4 to start Tasks 2–4, complete Slice 05 Task 6 before Task 5, validate both consumer contracts, and run the verification gate.
- Failed checks: None; implementation has not started.
- Spec updates: Approved the product, technical, privacy, capability, task-sequence, and verification contracts; separated project-storage authority from governance prerequisites and project-specification store readiness from governance readiness.
