# Project Specification Storage Tasks

## Status

Blocked

The product, technical, privacy, task-sequence, and verification contracts are approved. Task 2 remains blocked until Slice 05 delivers the shared project-storage authority capability; the later privacy task separately waits for project-storage governance.

## Active Slice

Deliver one shared hosted and device-authoritative project-specification store with stable specification identity, immutable complete document-set revisions, optimistic current-head updates, consistent current-project snapshots, and a destination-local restoration transaction seam for Slice 06 and Slice 07.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 2`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 5`.

Provides:

- `capability:project-specification-store` — ready after `Task 4`.
- `capability:project-specification-governance` — ready after `Task 5`.

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
  - Depends on: none
  - Purpose: Establish one capability owner and executable contract before backup or delivery implements specification persistence.
  - Owned surfaces: Outcome and scope, stable identity, revision and snapshot semantics, authorization extension seam, hosted and device authority, restoration transaction seam, privacy lifecycle, cross-specification capability, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Proof: Requirements, design, data boundaries, interfaces, capability dependencies, task ownership, sequence, traceability, and verification commands have no unresolved agreement decision.

- [ ] Task 2 — Implement the shared domain and hosted specification store.
  - Depends on: Task 1
  - Purpose: Establish stable specification identity and immutable revision behavior in the hosted project boundary.
  - Owned surfaces: `ProjectSpecification`, `SpecificationRevision`, hosted migrations and schemas, complete document-set validation, stable digest, project-owner authorization seam, create transaction, expected-head append transaction, current retrieval, uniqueness and foreign-key constraints, configured limits, fixtures, and hosted failure behavior.
  - Owns: AC-01, AC-02, AC-04, AC-07, entity:ProjectSpecification, entity:SpecificationRevision
  - Proof: Migration, changeset, authorization, transaction, constraint, concurrency, stale-head, hostile-text, limit, rollback, and domain tests prove atomic creation, immutable complete revisions, current-head integrity, project isolation, and non-execution.

- [ ] Task 3 — Implement the device-authoritative adapter and shared store contract.
  - Depends on: Task 2
  - Purpose: Provide equivalent specification behavior without creating a hosted device-project copy.
  - Owned surfaces: `SpecificationStore` behavior, hosted adapter conformance, worker-owned device adapter contract, development device-store persistence, destination ownership checks, device transactions, protocol value shapes, adapter fixtures, no-hosted-copy enforcement, and parity tests.
  - Owns: AC-05
  - Proof: Shared adapter-contract, device persistence, isolation, transaction, restart, concurrency, and negative hosted-copy tests prove equivalent create, append, current-read, validation, and failure behavior in both destinations.

- [ ] Task 4 — Implement consistent snapshots and restoration transaction participation.
  - Depends on: Task 2, Task 3
  - Purpose: Give portability and guided delivery one deterministic current view and one atomic destination integration seam.
  - Owned surfaces: `SpecificationSnapshot`, deterministic current-project ordering, consistent hosted and device snapshot reads, strict allowlisted snapshot shape, `prepare_restore` hosted `Ecto.Multi` contribution, device transaction contribution, stable identity preservation, conflict validation, caller idempotency, rollback, fault injection, fixtures, consumer contract tests, and `capability:project-specification-store` readiness write-back.
  - Owns: AC-03, AC-06, AC-08, entity:SpecificationSnapshot
  - Proof: Snapshot consistency, allowlist, ordering, concurrent append, hosted and device restore-contract, conflict, replay, idempotency, injected-failure, and rollback tests prove one current view and no partial destination state.

- [ ] Task 5 — Enforce lifecycle, privacy, and cross-specification compatibility.
  - Depends on: Task 2, Task 3, Task 4
  - Status: Blocked until `capability:project-storage-governance` is available and its earlier task dependencies pass.
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

- No agreement decision remains unresolved. Task 2 is blocked until `capability:project-storage-authority` is delivered by `specs/05-project-storage-lifecycle#Task 4`; Task 5 additionally requires `capability:project-storage-governance` from `specs/05-project-storage-lifecycle#Task 6`.

## Progress Log

### 2026-07-28 - Shared specification-storage foundation approved

- Completed: Extracted stable project-specification identity, immutable complete revisions, current-head updates, hosted and device adapters, consistent snapshots, and restoration transaction participation from the portability and guided-delivery consumers into one focused shared capability.
- Remaining: Complete Slice 05 Task 4 to start Tasks 2–4, complete Slice 05 Task 6 before Task 5, validate both consumer contracts, and run the verification gate.
- Failed checks: None; implementation has not started.
- Spec updates: Approved the product, technical, privacy, capability, task-sequence, and verification contracts; separated project-storage authority from governance prerequisites and project-specification store readiness from governance readiness.
