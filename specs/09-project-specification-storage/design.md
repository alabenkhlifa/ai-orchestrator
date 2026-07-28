# Project Specification Storage Design

## Context

Project portability needs a consistent snapshot of current specification documents, while guided delivery needs durable revisions for readiness, execution binding, and accepted-answer write-back. Neither backup nor orchestration should own the shared specification identity or authoritative persistence model.

The existing project-storage boundary selects hosted PostgreSQL or device-authoritative persistence, but it does not yet store specification documents. Slice 07 currently names `SpecificationRevision` inside its broader delivery workflow, creating an implicit forward dependency for Slice 06. This specification extracts that shared prerequisite into one focused foundation.

## Proposed Approach

Introduce a project-scoped `ProjectSpecification` aggregate with one stable identity, current display title, and current revision reference. Store every complete three-document state as an immutable `SpecificationRevision`. Create the aggregate and first revision atomically, and append later revisions through optimistic expected-head validation so concurrent writers cannot silently overwrite each other.

Expose a shared `SpecificationStore` contract implemented by hosted and device adapters. The contract supports authorized create, append, current retrieval, consistent current-project snapshot, and transaction-local restoration preparation. Hosted operations use PostgreSQL transactions and constraints. Device operations use the worker-owned device transaction boundary and the development adapter mirrors that contract without creating a hosted copy.

Keep snapshots and restoration inputs as allowlisted values without paths. Slice 06 owns package cryptography, intake, conflict handling, and user workflow; it consumes the current snapshot and destination-transaction seams. Slice 07 owns the board, guidance, readiness, and orchestration behavior; it consumes the same identities and revision operations instead of defining another store.

## Components Affected

- Project-scoped specification domain and stable identity.
- Hosted specification and immutable revision persistence.
- Device-authoritative specification persistence contract and development adapter.
- Shared current-snapshot and destination-transaction interfaces.
- Project authorization extension seam for later participation.
- Privacy inventory, retention, rights, backup, logging, and no-analytics enforcement.

## Data and Access Boundaries

- `ProjectSpecification`: the stable project-scoped specification identity, current display title, current revision reference, lifecycle timestamps, and destination ownership key.
- `SpecificationRevision`: one immutable, ordered, project-scoped revision containing a complete `requirements.md`, `design.md`, and `tasks.md` document set, its content digest, creation time, and minimum non-email actor reference when the authorized caller supplies one.
- `SpecificationSnapshot`: a transient allowlisted current-project view containing stable specification identity, title, current revision identity, and the three current documents; it is not persisted as a second authoritative copy.

Required boundaries:

- The project and its specifications live in the same authoritative storage destination.
- Hosted authorization resolves through the current project owner boundary and can later accept the project-participation capability as an additive policy input.
- Device authorization resolves under the current device workspace and operating-system boundary.
- Cross-project, cross-workspace, cross-device, and unauthorized access fails closed before content or identity disclosure.
- Revision rows are immutable; only the specification's current revision reference and mutable display title can change.
- Every revision contains exactly the approved three logical documents and no path, executable artifact, credential, repository content, comment, attachment, or generated output.
- A stable digest covers the normalized three-document value for integrity and deterministic comparison; it is governed project metadata, not anonymous data.
- Snapshots are transient values created from one destination-local consistent read.
- Restore preparation accepts only already validated allowlisted values and participates in the caller's destination-local project-creation transaction.
- Hosted and device stores never coordinate through a distributed transaction or copy device-authoritative specification content into hosted persistence.
- Logs, diagnostics, telemetry, caches, and indexes exclude document content and stable project or specification identifiers unless a separately approved security record is strictly necessary.

## Interfaces

- `SpecificationStore.create/4`: authorize the project, validate one complete document set, and atomically create the stable specification and its first revision.
- `SpecificationStore.append_revision/5`: authorize the project, require an expected current revision, validate one complete document set, insert one immutable revision, and atomically advance the current reference.
- `SpecificationStore.get_current/3`: return one authorized specification and its current complete revision without loading unrelated project data.
- `SpecificationStore.current_snapshot/2`: return one consistent, deterministically ordered, allowlisted snapshot of every current project specification.
- `SpecificationStore.prepare_restore/4`: contribute validated stable specification and revision inserts to the destination-local project-creation transaction, enforce conflicts and idempotency, and expose no package or cryptographic behavior.
- `SpecificationAuthorization`: resolve current project-owner access initially and accept later participant authorization through an additive policy adapter without changing persistence identity.
- `SpecificationLimits`: provide configured document byte, revision byte, specification-count, and project-snapshot limits with deterministic defaults for tests.
- `SpecificationLifecycle`: cascade project deletion, extend verified rights processing, enforce log and backup expiry, and expose cleanup proof without reading document content.

## Decisions and Tradeoffs

### Shared Foundation Instead Of Consumer-Owned Persistence

- Choice: Give specification identity, revision persistence, and storage adapters to this focused foundation.
- Reason: Backup and guided delivery need the same authoritative documents but have independent workflows, failure paths, and release boundaries.
- Consequence: Slice 06 and Slice 07 must consume this capability and cannot introduce a second specification store.

### Versioned From The First Revision

- Choice: Store immutable complete revisions from initial creation rather than only a mutable current document row.
- Reason: Slice 07 requires revision binding and write-back, while Slice 06 needs a stable current snapshot. Adding versioning later would create migration and identity ambiguity.
- Consequence: The foundation retains revision history with the active project even though the initial Slice 06 package exports only current heads.

### Complete Document-Set Revisions

- Choice: Require every revision to contain `requirements.md`, `design.md`, and `tasks.md` together.
- Reason: Atomic complete revisions avoid mixed document versions and make snapshot, readiness, execution, and restore binding deterministic.
- Consequence: Consumers cannot append a partial document update; they must submit the resulting complete set.

### Optimistic Expected-Head Concurrency

- Choice: Require the expected current revision for append and enforce the head transition transactionally.
- Reason: Multiple authorized workflows may revise the same specification, and silent last-write-wins behavior would invalidate readiness and execution evidence.
- Consequence: A stale writer must reload and explicitly reconcile before retrying.

### Destination-Local Adapter Contract

- Choice: Implement identical logical operations through hosted PostgreSQL and the worker-owned device store.
- Reason: Project storage authority is already selected per project and device content must not become a hosted copy.
- Consequence: Transaction mechanics differ by destination, but adapter contract tests must prove equivalent observable behavior.

### Transaction Seam For Restoration

- Choice: Let an authorized restoration workflow contribute validated specification inserts to the same destination-local project-creation transaction.
- Reason: Slice 06 requires atomic project and specification restoration but should not own the specification schema.
- Consequence: Package decryption, compatibility, and conflict policy remain outside this foundation; this interface rejects unvalidated or conflicting values but does not parse packages.

### No Specification UI In The Foundation

- Choice: Expose domain and adapter interfaces only.
- Reason: Board, editing guidance, readiness, and user-facing naming belong to Slice 07, while backup and restore presentation belongs to Slice 06.
- Consequence: The foundation is not independently presented as a product page; its value is one stable contract shared by independently user-visible consumers.

### Approved Privacy Contract

- Choice: Treat document content, titles, revision metadata, digests, and linkable actor references as governed project data under the selected project-storage boundary.
- Reason: Specifications can contain personal, confidential, security, and repository-context information even when no direct identifier is intended.
- Consequence: Use service-performance processing for the user-requested storage operation and the approved security basis only for minimized protection records; prohibit analytics, advertising, model training, identity tracking, and unrelated reuse. Delete authoritative content with the project or applicable verified rights outcome, propagate deletion to derived copies and processors, expire security logs within 30 days and encrypted rolling backups within 35 days, and keep operations access content-free by default.

## Risks

- A consumer may create a second specification schema instead of using the shared capability. Enforce one capability owner and cross-specification dependency validation.
- Concurrent updates may mix readiness or execution with stale documents. Require immutable revisions and expected-head transitions.
- A snapshot may combine heads from different transaction moments. Use one destination-local consistent read and deterministic ordering.
- Device content may leak into hosted persistence through convenience caching. Prohibit hosted authoritative or cache copies and test adapter boundaries.
- Restore integration may partially create a project and specifications. Require destination-local transaction composition, constraints, idempotency, and fault-injection proof.
- Document text may be treated as a path, template, or command. Keep values path-free, never execute content, and test hostile text.
- Logs or diagnostics may capture document content. Use fixed structured outcomes and negative content scans.

## Open Questions

- None. The stable identity, immutable complete-revision model, expected-head concurrency, hosted and device adapter boundary, consistent snapshot, restoration transaction seam, and privacy lifecycle are approved.
