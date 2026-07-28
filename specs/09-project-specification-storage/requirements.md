# Project Specification Storage

## Status

Approved

## Outcome

Every project can persist and retrieve an authoritative, versioned current specification document set through the project's selected storage boundary, giving backup, restoration, guided delivery, and later project workflows one stable specification contract without making any of those consuming features the owner of specification persistence.

## Users

- Project owners whose specification documents must remain available with their project.
- Authorized project workflows that create, revise, snapshot, restore, or consume specifications.
- Support and operations personnel enforcing approved lifecycle and security controls without receiving specification content by default.

## Primary Workflow

1. An authorized project workflow creates a project specification with one stable logical identity, a display title, and current `requirements.md`, `design.md`, and `tasks.md` content.
2. The specification and its first immutable revision commit atomically in the project's authoritative hosted or device storage boundary.
3. An authorized workflow may append a complete new document-set revision using the expected current revision.
4. The append either advances the current revision atomically or fails without changing the specification.
5. An authorized consumer requests one consistent current-specification snapshot for the project.
6. The storage boundary returns each current specification's stable identity, title, revision identity, and three current documents without returning repository paths, credentials, or prior revisions.
7. An authorized restoration workflow may prepare the same validated specification identities and revisions inside the destination's project-creation transaction; a conflict or failure leaves no partial specification state.

## In Scope

- One project-scoped `ProjectSpecification` identity and current-revision pointer.
- Immutable `SpecificationRevision` records containing one complete three-document set.
- Authoritative hosted and device persistence behind one shared storage interface.
- Atomic creation, optimistic revision append, current-head retrieval, and consistent current-project snapshot.
- A destination-transaction integration seam for validated same-project restoration.
- Project ownership and storage-boundary authorization with an additive extension point for later participant authorization.
- Content and size validation, non-execution, project isolation, concurrency, idempotency, and failure behavior.
- Purpose, access, minimization, retention, deletion, rights, processor, transfer, logging, backup, and no-analytics controls.

## Out of Scope

- Feature boards, guided requirement questions, readiness assessment, or approval.
- Agent execution, blocking-question write-back, evidence, previews, reviews, or notifications.
- Backup package creation, encryption, delivery, intake, compatibility, conflict handling, or restoration UI.
- Collaboration invitations, participant roles, assignment, or participant authorization.
- Editing UI, rich-text formatting, comments, attachments, generated artifacts, repository source, or arbitrary additional document types.
- Cross-project sharing, copying, merging, synchronization, or global specification discovery.
- Automatic filesystem or repository scanning for specification documents.

## Business Rules

- A project specification has one stable logical identity that does not change when its title or documents change.
- Every stored revision is immutable and contains the complete current `requirements.md`, `design.md`, and `tasks.md` content; partial document updates are rejected.
- Creating a specification commits the specification and its first revision together or not at all.
- Appending a revision requires the expected current revision identity. A stale or duplicate concurrent append cannot silently overwrite a newer current revision.
- The current-revision pointer advances in the same authoritative transaction as the new immutable revision.
- A current-project snapshot is consistent: it cannot combine specification heads observed before and after one concurrent commit.
- The snapshot contains only stable specification identity, current title, current revision identity, and the three current documents. Repository or filesystem paths, credentials, actor email, storage mode, prior revisions, and unrelated project records are excluded.
- Hosted-project specification data is stored in the hosted project boundary. Device-project specification data stays in the device-authoritative store and is not copied into hosted persistence.
- The shared interface exposes destination-local transaction participation rather than attempting a distributed transaction across hosted and device stores.
- A restoration caller may supply stable specification and revision identities only after its owning workflow has validated package authority, content, compatibility, and project conflicts.
- Restored specification state commits with destination project creation or leaves no partial project, specification, or revision record.
- Replaying the same authorized restoration operation returns the already committed result or an equivalent idempotent outcome; it does not create duplicate specifications or revisions.
- Specification titles are trimmed, non-empty display labels. Title uniqueness and user-facing naming policy remain owned by the consuming workflow unless a later approved specification establishes a shared rule.
- Document contents are untrusted text. Storage, validation, snapshot, and restoration paths never execute them, resolve embedded paths, or treat their text as commands.
- Configured per-document, per-revision, specification-count, and project-snapshot limits must be enforced before persistence or transfer through the interface.
- Current project authorization is checked for every read and write. The initial owner boundary may later be extended additively by the approved project-participation capability without changing stable identities or storage semantics.
- Specification contents and linkable metadata are personal or confidential project data, not anonymous analytics.
- Specification data is processed only to provide project specification storage and the explicitly authorized consuming workflows. It is not reused for analytics, advertising, model training, unrelated product improvement, or another secondary purpose.
- Specification content is retained only while the project or an approved project-accountability need requires it and is deleted through verified project deletion or applicable rights handling.
- Device-authoritative specification data remains under the operating-system boundary. Hosted data, encrypted rolling backups, processors, logs, caches, indexes, and rights workflows follow the project's approved storage and privacy boundary.
- Operational logs contain no document content, titles, stable specification identifiers, repository identity, credentials, or user-provided paths. Approved security logs expire within 30 days and encrypted rolling backups within 35 days.
- Technical controls and tests provide compliance evidence but do not replace deployment-specific privacy or legal approval.

## Acceptance Criteria

- [AC-01] Given an authorized project workflow supplies a stable specification identity, title, and all three required documents, when creation commits, then exactly one project specification and one immutable current revision exist together in the project's authoritative storage boundary.
- [AC-02] Given an authorized workflow supplies the expected current revision and a complete replacement document set, when revision append commits, then one immutable revision is added and the current pointer advances atomically; a stale expected revision changes nothing.
- [AC-03] Given a project has multiple specifications and concurrent revision activity, when an authorized current snapshot is requested, then every returned specification is observed from one consistent boundary and contains only its stable identity, title, current revision identity, and current three-document set.
- [AC-04] Given another project, workspace, device boundary, or unauthorized identity requests specification data or mutation, when authorization is evaluated, then the operation fails closed without exposing whether a specification identity exists.
- [AC-05] Given equivalent hosted and device projects, when specification operations run, then both adapters satisfy the same creation, revision, snapshot, concurrency, and failure contract while device-authoritative content creates no hosted specification copy.
- [AC-06] Given an authorized restoration workflow supplies a validated same-project specification set, when destination project creation commits, then the project and every supplied specification and revision commit atomically with preserved stable identities; conflict, replay, or injected failure creates no duplicate or partial state.
- [AC-07] Given missing documents, unsupported fields, oversized content, excessive counts, embedded paths, or command-like text, when validation and persistence run, then invalid structure or limits are rejected and accepted text is stored without execution or path resolution.
- [AC-08] Given concurrent create, append, snapshot, and restore operations, when constraints and transaction behavior are exercised, then stable identities remain unique, stale writes cannot win, snapshots remain consistent, and retries are idempotent.
- [AC-09] Given specification records, device data, hosted data, logs, caches, indexes, backups, processors, deletion, and rights workflows are inspected, when privacy verification runs, then the approved purpose, access, minimization, retention, deletion, transfer, redaction, and no-secondary-use contract is enforced.
- [AC-10] Given Slice 06 or Slice 07 consumes the specification-storage capability, when the consumer is integrated, then it uses the stable shared interface without defining a second specification identity, revision store, or authoritative document copy.

## Open Questions

- None.
