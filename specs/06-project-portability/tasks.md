# Project Backup And Restoration Tasks

## Status

Not Started

## Active Slice

Deliver passphrase-encrypted backup and restoration of one minimal project package containing stable project ID and display name, non-secret canonical repository identity, and current specification identity and `requirements.md`, `design.md`, and `tasks.md` content, while preserving the stable project identity, rejecting an existing same-project identity, and providing version, integrity, secret exclusion, validation, and atomic restore behavior.

## Implementation Boundary

Included:

- Initial allowlisted backup schema and version with project, repository, and current-specifications sections.
- Consistent backup snapshot for stable project ID and display name, provider and canonical repository identity, and each current specification's logical identity, title, and current `requirements.md`, `design.md`, and `tasks.md` content.
- User-set recovery passphrase, unrecoverable-loss confirmation, package encryption, transient decryption, and required passphrase entry for every restoration.
- Packaged stable project identity and same-identity restore rejection.
- Duplicate discovery limited to the selected destination and catalogs already accessible to the current restore session.
- Integrity information and negative secret filtering.
- Isolated restore validation, authority check, and temporary cleanup.
- Atomic restoration into an available storage mode.
- User-entered display-name recovery for a name-only conflict and blocking canonical-repository conflicts.
- Approved package, temporary-data, provenance, log, backup, processor, rights, no-reuse, security, compatibility, and responsive browser proof.

Excluded:

- Cross-user sharing, package exchange, ownership transfer, and creating a copy with a new identity.
- Updating, merging, replacing, or restoring over an existing project.
- Repository source, credentials, sessions, worker or agent data, collaboration memberships, and arbitrary executable artifacts.
- Project or specification revision history, runs and run output, generated artifacts, comments, attachments, audit or security logs, analytics, mutable repository display or access metadata, workspace identity, source storage mode, and source lifecycle state.
- Direct storage migration, source deactivation, and automatic repository reconnection.
- Global project-identity registry, background identity-presence reporting, signed-out account lookup, unavailable-device lookup, and later-visible collision resolution.

Deferred after this slice:

- A separate child specification for cross-user package exchange and create-copy behavior.
- Additional history, runs and run output, generated artifacts, comments, attachments, audit evidence, richer provenance, and cross-version migrations.
- Repository source inclusion under a separate approved threat model.
- Deferred criteria: none.
- Deferred entities: none.

Release boundary:

- This slice requires the approved authority, package, compatibility, privacy, and verification contracts plus all active-slice proofs before release.
- A public hosted deployment remains gated on its deployment-specific controller, processor, region, transfer, notice, incident, retention-enforcement, and required privacy or legal evidence.
- Release criteria: none.
- Release entities: none.

## Tasks

- [x] Task 1 - Approve the initial backup, restore-authority, lifecycle, and compatibility contract.
  - Purpose: Define exactly what crosses the backup boundary, who may restore it, and how the data is governed before coding starts.
  - Owned surfaces: Active package scope, stable-identity semantics, passphrase and destination-authorization contract, conflict policy, package and compatibility contract, threat model, privacy data contract, and canonical verification commands.
  - Owns: none (agreement gate)
  - Depends on: none
  - Proof: Requirements, design, package schema, identity and authority model, threat model, data contract, task ownership, sequence, and canonical test commands have no unresolved active-slice blockers.

- [ ] Task 2 - Implement the consistent backup snapshot and allowlisted package.
  - Purpose: Produce one deterministic, versioned package from authorized current project data while preserving the stable project identity.
  - Owned surfaces: `ProjectPackage`, `PackageSection`, authorization at snapshot time, minimum envelope metadata, explicit project ID and display-name field map, provider and canonical-repository-identity field map, current specification identity, title, and three-document serialization, excluded-association boundary, manifest and section versions, section ordering, stable identity, and concurrent-update behavior.
  - Owns: AC-01, entity:ProjectPackage, entity:PackageSection
  - Depends on: Task 1
  - Proof: Golden decrypted-payload, authorization, explicit field-map, excluded-field, deterministic-ordering, and concurrent-update tests cover every approved and forbidden field, all three sections, every current specification document, versions, and stable-identity values.

- [ ] Task 3 - Implement secret exclusion, package encryption, and integrity.
  - Purpose: Prevent credential leakage, encrypt every package with the user-set recovery passphrase, and detect corruption or tampering before restoration.
  - Owned surfaces: Allowlist enforcement, forbidden-field and excluded-category detection, repository-source absence, secret filtering, passphrase handling, non-secret encryption parameters, transient key derivation, authenticated package encryption and decryption, passphrase and derived-key disposal, integrity calculation and verification, and negative package inspection.
  - Owns: AC-02, AC-14
  - Depends on: Task 2
  - Proof: Negative secret, repository-source, excluded-category, and persistence scans; missing and incorrect passphrase tests; transient-key disposal checks; mutation tests; encryption and integrity fixtures; and schema coverage pass for every forbidden category and exported section.

- [ ] Task 4 - Implement isolated restore intake and validation.
  - Purpose: Reject unsafe, incompatible, or unauthorized content before persistence and clean up every transient artifact.
  - Owned surfaces: `ImportAttempt`, isolated encrypted intake, required passphrase handoff to the Task 3 decryption boundary, destination-authorization verification, format and version compatibility, unknown fields, integrity, size, path and extraction safety, attachment and content limits, resource limits, failure state, and temporary cleanup.
  - Owns: AC-03, AC-04, AC-11, entity:ImportAttempt
  - Depends on: Task 3
  - Proof: Compatibility, destination-authorization, and security tests cover supported and unsupported versions, unknown fields, malformed sections, tampering, oversized input, path traversal, archive bombs, unsafe links, resource exhaustion, cancellation, failure, expiry, and cleanup without decrypted-content exposure or persistent project data.

- [ ] Task 5 - Implement conflict preflight and atomic same-project restoration.
  - Purpose: Restore the packaged stable project once without silent overwrite, copy identity, duplicate repository identity, or partial state.
  - Owned surfaces: `Project`, `PackageProvenance`, packaged-identity validation, selected-destination and current-accessible-catalog scope derivation, visibility-bounded duplicate checks, no global registry or unavailable-boundary query, later-visible collision handoff to the combined-catalog contract, case-insensitive display-name conflict detection, user-supplied replacement-name validation, cancellation without mutation, canonical-repository hard block, conflict precedence, selected storage prerequisites, atomic restore with packaged identity and approved display name, rollback, idempotency, and explicit repository reconnection boundary.
  - Owns: AC-05, AC-06, AC-07, AC-08, AC-09, AC-10, AC-15, entity:Project, entity:PackageProvenance
  - Depends on: Task 4
  - Proof: Domain, adapter, transaction, constraint, concurrency, retry, and fault-injection tests cover identity preservation, same-identity rejection in every accessible boundary, absence of signed-out or unavailable-device queries and global reporting, later-visible collision handoff without record mutation, conflicting packaged names, explicit valid and invalid replacement names, repeat name collisions, cancellation, repository hard blocks with and without name conflicts, both storage modes, missing authorization, atomic success, rollback, no partial records, and unchanged repository content and configuration.

- [ ] Task 6 - Build the backup and restoration interface.
  - Purpose: Show package scope, authority requirements, validation results, conflicts, and actionable recovery without presenting sharing or copy behavior.
  - Owned surfaces: Backup scope and result UI with the three included content categories and explicit excluded categories, passphrase creation and confirmation, unrecoverable-loss acknowledgement, restore passphrase entry, restore intake and destination selection, destination-authorization step, validation progress and errors, name-only conflict form and inline validation, blocking repository-conflict state, cancellation, completion, and responsive accessibility behavior.
  - Owns: AC-13
  - Depends on: Task 2, Task 4, Task 5
  - Proof: LiveView and desktop and mobile browser scenarios cover included and excluded scope, passphrase confirmation, unrecoverable-loss warning, encrypted backup, missing and incorrect restore passphrases, compatible restore, destination-authorization failure, unsafe rejection, same-identity rejection, explicit replacement-name success and validation failure, repository conflict with no bypass, cancellation, completion, and absence of cross-user sharing or create-copy claims.

- [ ] Task 7 - Enforce the backup privacy lifecycle and security review.
  - Purpose: Govern packages, temporary files, logs, backups, provenance, restored records, processors, transfers, rights, and deletion.
  - Owned surfaces: Active data inventory, approved service and security purposes and lawful bases, authorized-user and operations access controls, no completed service-package retention, immediate passphrase, derived-key, and decrypted-content disposal, immediate terminal and 24-hour stranded encrypted-temporary and `ImportAttempt` cleanup, minimal schema-version and restoration-time `PackageProvenance`, project-bound provenance deletion, 30-day structured security-log expiry, 35-day encrypted-backup expiry, derived-record and processor deletion propagation, verified rights behavior, processor and transfer configuration, no analytics, advertising, model training, identity tracking, or unrelated reuse, log redaction, audit minimization, and required privacy or legal review.
  - Owns: AC-12, AC-16
  - Depends on: Task 2, Task 3, Task 4, Task 5, Task 6
  - Proof: Data-inventory, purpose and basis, access, terminal and stranded cleanup, no-completed-package, passphrase and decrypted-content disposal, provenance-field, project-erasure, rights, processor, transfer, structured-log, 30-day log-expiry, 35-day backup-expiry, derived-record propagation, negative secondary-use, secret-exposure, audit-minimization, and required privacy or legal checks pass.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Every active acceptance criterion and data entity has one clear primary task owner.
- [ ] Golden decrypted-payload, deterministic snapshot, explicit field-map, excluded-category, and supported-version compatibility fixtures prove the exact project, canonical repository, and current-specifications allowlist.
- [ ] Stable project identity is preserved, and existing same-identity restoration is rejected without overwrite, merge, update, rename, or partial mutation.
- [ ] Duplicate discovery checks only the selected destination and catalogs already accessible in the restore session; no signed-out or unavailable-device query, global registry, or background identity-presence signal occurs, and later-visible same-ID records remain separate and unchanged.
- [ ] Passphrase-based package control and normal destination-authorization checks pass for every signed-in and accountless restore path.
- [ ] Every backup is encrypted with its confirmed user-set recovery passphrase; every restore requires the correct passphrase; passphrase-loss confirmation, missing and incorrect input, transient key disposal, and unrecoverable-support-boundary tests pass.
- [ ] Secret-exclusion, passphrase and derived-key non-persistence, allowlist, authenticated encryption, integrity, tampering, and forbidden-field tests pass.
- [ ] Malformed, unsafe, unsupported, oversized, unknown-field, path, archive, and resource-limit tests pass.
- [ ] Name-only conflicts permit an explicitly entered valid unique display name or cancellation, canonical-repository conflicts always block, and storage, atomicity, idempotency, concurrency, and rollback tests pass.
- [ ] Repository reconnection requires normal authorization and leaves repository content and configuration unchanged.
- [ ] The approved GDPR contract passes: no completed service package; immediate passphrase, key, decrypted-content, and terminal temporary-data disposal; stranded encrypted data and attempt cleanup within 24 hours; minimal project-bound provenance; 30-day security logs; 35-day encrypted backups; verified rights and processor propagation; and no analytics, advertising, model training, identity tracking, or unrelated reuse.
- [ ] Required LiveView and desktop and mobile browser scenarios pass without exposing cross-user exchange or create-copy behavior.
- [ ] Approved canonical build, formatting, lint, static, security, production, and failure-log checks pass.

## Blocked Decisions

- None. The technical-design and verification-design decisions that previously blocked this slice are resolved in `design.md` Decisions and Tradeoffs and closed in its Open Questions.

## Progress Log

### 2026-07-28 - Technical and verification design resolved

- Completed: Resolved every blocked technical-design and verification-design decision as engineering choices grounded in the existing codebase — a deterministic JSON container with compress-then-encrypt, Argon2id memory-hard passphrase derivation (`argon2_elixir`), AES-256-GCM authenticated encryption with the envelope bound as additional authenticated data, transient passphrase and key handling, isolated intake with explicit size, ratio, count, and length limits and reject-or-ignore version compatibility, an atomic `Ecto.Multi` restore with constraint-backed identity and canonical-repository hard blocks and minimal provenance, and privacy-lifecycle wiring through the existing `Privacy.ProcessingInventory`, `Privacy.Retention` and `RetentionPruner`, `DeploymentPrivacyProfile`, and `Privacy.Rights`. Selected the canonical Slice 01 verification commands. Marked Task 1 complete and moved the slice from Blocked to Approved.
- Remaining: Implement Tasks 2–7 under the resolved design, then run the verification gate; create a separate child specification before any cross-user exchange or create-copy behavior.
- Failed checks: None; implementation has not started.
- Spec updates: Recorded the container, key-derivation, authenticated-encryption, transient-handling, intake-limit, compatibility, atomic-restore, provenance, and lifecycle-and-verification decisions in `design.md`; closed the four design open questions; removed the resolved Blocked Decisions section; and recorded that Task 3 introduces the `argon2_elixir` dependency.

### 2026-07-26 - Scope health checkpoint

- Completed: Approved the focused product agreement for same-project backup and restoration, including stable identity, visibility-bounded duplicate rejection, explicit name-only conflict recovery, canonical-repository hard blocks, the minimal current-state payload, user-controlled passphrase encryption, and the package-specific privacy lifecycle.
- Remaining: Resolve the technical and verification designs; implement Tasks 2–7 only after Task 1 is approved; and create a separate child specification before implementing cross-user exchange or create-copy behavior.
- Failed checks: Initial validation rejected `Approved` while `requirements.md` still duplicated technical-design questions; those questions now live only in `design.md`. Implementation has not started.
- Spec updates: Removed colleague package exchange, new copy identity, update or merge behavior, history, run data, generated material, comments, attachments, logs, repository source, environment-specific state, mutable repository metadata, global identity tracking, and unavailable-boundary lookup from the active slice; required the user-controlled passphrase contract; retained no completed service package; bounded transient, provenance, log, and backup lifecycles; prohibited secondary use; and kept deployment-specific evidence in the release gate.

### 2026-07-23 - Extracted from project onboarding

- Completed: Isolated the export and restore, secret exclusion, compatibility, conflict, repository reconnection, and privacy boundaries.
- Remaining: Approve the initial package scope, identity rules, format, threat model, lifecycle, architecture, and verification strategy.
- Failed checks: None; implementation has not started.
- Spec updates: Created a focused package specification and limited its first executable slice to a minimal safe round trip.
