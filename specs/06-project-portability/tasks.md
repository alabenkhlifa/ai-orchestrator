# Project Backup And Restoration Tasks

## Status

Blocked

The product, package, cryptographic, privacy, and verification agreements remain approved. Tasks 8, 2, 9, 3, 6, 4, 10, 14, 5, 11, 12, 19, 13, and 20 are complete. Task 21 is the next implementation task and is blocked on the local canonical-identity portability decision recorded below.

## Active Slice

Deliver passphrase-encrypted backup and restoration of one minimal project package containing stable project ID and display name, non-secret canonical repository identity, and current specification identity and `requirements.md`, `design.md`, and `tasks.md` content, while preserving the stable project identity, rejecting an existing same-project identity, and providing version, integrity, secret exclusion, validation, and atomic restore behavior.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 2`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 17`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 2`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 22`.

Provides:

- `capability:project-portability` — ready after `Task 7`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Existing task labels are preserved; newly split tasks use the next unused labels and are listed by dependency order rather than numeric order.

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
  - Size: Standard
  - Purpose: Define exactly what crosses the backup boundary, who may restore it, and how the data is governed before coding starts.
  - Owned surfaces: Active package scope, stable-identity semantics, passphrase and destination-authorization contract, conflict policy, package and compatibility contract, threat model, privacy data contract, and canonical verification commands.
  - Owns: none (agreement gate)
  - Depends on: none
  - Proof: Requirements, design, package schema, identity and authority model, threat model, data contract, capability dependencies, task ownership, sequence, and canonical test commands have no unresolved agreement decision.

- [x] Task 8 - Implement the deterministic package format and codec.
  - Size: Standard
  - Purpose: Establish one versioned package representation that can be proved independently of project persistence.
  - Owned surfaces: `ProjectPackage`, `PackageSection`, cleartext envelope field map, format and payload schema versions, deterministic JSON encoding with sorted keys, fixed project, repository, and specifications section order, DEFLATE compression and bounded decompression seam, single-file framing, and golden codec fixtures.
  - Owns: entity:ProjectPackage, entity:PackageSection
  - Depends on: Task 1
  - Proof: Focused codec tests prove byte-stable plaintext fixtures, exact envelope and section versions, deterministic ordering, round-trip serialization, malformed framing rejection, and bounded decompression without reading project persistence.

- [x] Task 2 - Implement the authorized current-project snapshot and allowlisted payload.
  - Size: Standard
  - Purpose: Produce one deterministic, versioned package from authorized current project data while preserving the stable project identity.
  - Owned surfaces: Backup authorization at snapshot time, read-only `SpecificationStore.current_snapshot` capability consumer, explicit project ID and display-name mapping, provider and canonical-repository-identity mapping, current specification identity, title, and three-document mapping, excluded-association boundary, stable identity, snapshot consistency, and package-codec handoff without a second specification store.
  - Owns: AC-01
  - Depends on: Task 8
  - Proof: Focused capability-contract, golden decrypted-payload, authorization, field-map, excluded-field, and concurrent-update tests cover every approved and forbidden field, every current specification document, and stable-identity values without duplicate persistence.

- [x] Task 9 - Enforce the payload allowlist and secret-exclusion boundary.
  - Size: Standard
  - Purpose: Fail closed when a mapped payload includes any unapproved or secret-bearing field.
  - Owned surfaces: Allowlist enforcement, forbidden-field and excluded-category detection, repository-source absence, credential and secret filtering, association traversal denial, negative package inspection, and regression fixtures for newly added source fields.
  - Owns: AC-02
  - Depends on: Task 2
  - Proof: Focused negative secret, repository-source, excluded-category, association, persistence, and source-schema drift tests prove that every forbidden category is absent before encryption.

- [x] Task 3 - Implement passphrase derivation and authenticated package encryption.
  - Size: Standard
  - Purpose: Encrypt every approved payload with the user-set recovery passphrase and reject corruption or tampering without exposing plaintext.
  - Owned surfaces: Passphrase handling, Argon2id dependency and configured parameters, random salt, transient 32-byte key derivation, AES-256-GCM encryption and decryption, random nonce, envelope additional authenticated data, authentication tag, opaque failure, passphrase and key disposal, and encrypted-package fixtures.
  - Owns: AC-14
  - Depends on: Task 9
  - Proof: Focused correct, missing, and incorrect passphrase tests, authenticated-envelope and ciphertext mutation tests, unique salt and nonce checks, transient-secret persistence and log scans, and golden encrypted-package round trips pass.

- [x] Task 6 - Build the backup creation and download interface.
  - Size: Standard
  - Purpose: Let an authorized user understand the package boundary, acknowledge passphrase loss, and receive one encrypted backup.
  - Owned surfaces: Backup action and LiveView, three included content categories, explicit excluded categories, passphrase creation and confirmation, unrecoverable-loss acknowledgement, encrypted download delivery, actionable generation failure, cancellation, responsive accessibility behavior, and absence of sharing or create-copy claims.
  - Owns: AC-13
  - Depends on: Task 3
  - Proof: Focused LiveView plus desktop and mobile browser scenarios cover scope copy, matching and mismatched passphrases, required loss acknowledgement, successful encrypted download, generation failure, cancellation, keyboard and focus behavior, and prohibited sharing or copy language.

- [x] Task 4 - Implement encrypted restore intake and terminal cleanup.
  - Size: Standard
  - Purpose: Isolate one restore request, establish destination authority, and remove transient state on every terminal path.
  - Owned surfaces: `ImportAttempt`, encrypted upload-at-rest, restore state transitions, required passphrase handoff to the Task 3 decryption boundary, selected destination binding, destination-authorization verification, cancellation and failure state, opaque errors, immediate terminal upload and attempt cleanup, and absence of persistent project mutation.
  - Owns: AC-11, entity:ImportAttempt
  - Depends on: Task 3
  - Proof: Focused intake state, encrypted-at-rest, destination-authorization, cancellation, failure, cleanup, and fault-injection tests prove immediate terminal deletion, opaque passphrase failure, and no decrypted-content exposure or persistent project data.

- [x] Task 10 - Implement package compatibility and safety validation.
  - Size: Standard
  - Purpose: Reject unsupported, malformed, oversized, or unsafe decrypted content before conflict checks or persistence.
  - Owned surfaces: Format and payload-version compatibility, supported-major unknown-field handling, strict duplicate-key and non-finite-number rejection, encrypted and decompressed size ceilings, expansion-ratio limit, specification count and document-size limits, field-length limits, content and attachment denial, single-file path-safety invariant, resource limits, and actionable validation result.
  - Owns: AC-03, AC-04
  - Depends on: Task 4
  - Proof: Focused compatibility, parser, property, and resource-limit tests cover supported and unsupported versions, additive unknown fields, duplicate keys, non-finite numbers, malformed sections, oversized input, decompression bombs, prohibited attachments, excessive counts and lengths, cancellation, and validation without persistent project state.

- [x] Task 14 - Build the restore intake and validation interface.
  - Size: Standard
  - Purpose: Let a user select a package, prove package control, authorize a destination, and understand validation without mutation.
  - Owned surfaces: Restore entry and LiveView, package selection, passphrase entry, destination storage selection, destination setup or sign-in handoff, validation progress, compatible result, missing and incorrect passphrase result, authorization failure, unsafe and unsupported result, cancellation, and responsive accessibility behavior.
  - Owns: AC-17
  - Depends on: Task 10
  - Proof: Focused LiveView plus desktop and mobile browser scenarios cover every destination mode, required passphrase, destination authorization, validation progress, compatible package, incorrect passphrase, unsupported and unsafe package, cancellation, keyboard and focus behavior, and no persistent project mutation.

- [x] Task 5 - Implement visibility-bounded stable-identity preflight.
  - Size: Standard
  - Purpose: Detect the packaged project identity only within boundaries already accessible to the restore session.
  - Owned surfaces: Packaged stable-identity validation, selected-destination and current-accessible-catalog scope derivation, duplicate query contract, same-identity rejection, no global registry or unavailable-boundary query, no identity-presence telemetry, and later-visible collision handoff to the combined-catalog contract without record mutation.
  - Owns: AC-06, AC-15
  - Depends on: Task 10
  - Proof: Focused domain and adapter tests cover same identity in each accessible boundary, signed-out and unavailable boundaries, absence of global lookup or reporting, and later-visible collision handoff while both records remain separate and unchanged.

- [x] Task 11 - Implement display-name and canonical-repository conflict decisions.
  - Size: Standard
  - Purpose: Permit an explicit display-label change only when no stable-identity or repository conflict blocks restoration.
  - Owned surfaces: Case-insensitive display-name conflict detection, user-supplied replacement-name validation, repeat name conflicts, cancellation without mutation, canonical-repository conflict detection, repository conflict precedence, no relink, unlink, substitution, or automatic rename, and structured conflict results.
  - Owns: AC-07, AC-08
  - Depends on: Task 5
  - Proof: Focused domain and constraint tests cover valid and invalid replacement names, repeat collisions, cancellation, repository conflicts with and without name conflicts, conflict precedence, and no identity, connection, or package mutation.

- [x] Task 12 - Implement the hosted atomic restoration adapter.
  - Size: Standard
  - Purpose: Create the packaged project and current specifications exactly once in authorized hosted storage.
  - Owned surfaces: `Project`, `PackageProvenance`, hosted storage prerequisites, `SpecificationStore.prepare_restore` hosted contribution, one `Ecto.Multi`, stable project, repository, and specification identities, approved display name, database identity and canonical-repository constraints, minimal provenance insertion, rollback, idempotency, retry, and no duplicate specification persistence.
  - Owns: AC-05, entity:Project, entity:PackageProvenance
  - Depends on: Task 11
  - Proof: Focused hosted transaction, constraint, concurrency, replay, retry, and fault-injection tests prove exactly one restored project and current specification set, identity preservation, minimal provenance, atomic rollback, and no partial or duplicate state.

- [x] Task 19 - Implement the device-authoritative atomic restoration adapter.
  - Size: Standard
  - Purpose: Create the packaged project and current specifications exactly once on an authorized device without a hosted authoritative copy.
  - Owned surfaces: Device storage prerequisites, `SpecificationStore.prepare_restore` device contribution, worker-owned local transaction, stable project, repository, and specification identities, approved display name, device identity and canonical-repository constraints, minimal local provenance, acknowledgement, rollback, idempotency, retry, and no hosted authoritative or duplicate specification persistence.
  - Owns: AC-21
  - Depends on: Task 12
  - Proof: Focused device transaction, persistence, restart, constraint, concurrency, replay, lost-acknowledgement, retry, and fault-injection tests prove exactly one device-authoritative project and current specification set, identity preservation, rollback, no partial state, and no hosted authoritative copy.

- [x] Task 13 - Preserve the unconnected restored-repository boundary.
  - Size: Standard
  - Purpose: Keep every restored canonical repository identity disconnected until a separate normal authorization flow succeeds.
  - Owned surfaces: Hosted and device unconnected restored-repository state, absence of packaged credentials and connection records, no automatic reconnection, explicit reconnection action contract, and safe missing-authorization result.
  - Owns: AC-09
  - Depends on: Task 19
  - Proof: Focused hosted and device state tests cover missing authorization, absence of packaged or stale credentials and connections, no automatic network or worker action, and one explicit reconnection action.

- [x] Task 20 - Integrate explicit GitHub repository reconnection.
  - Size: Standard
  - Purpose: Reuse normal GitHub provider authorization without treating package control as repository authority.
  - Owned surfaces: GitHub reconnection action, existing provider authorization and validation reuse, canonical GitHub repository identity binding, success and failure handoff, no packaged credential acceptance, and repository content, branch, remote, setting, and Git-configuration non-mutation.
  - Owns: AC-10
  - Depends on: Task 13
  - Proof: Focused GitHub provider-contract tests cover missing, failed, and successful authorization, canonical identity mismatch, absence of stale credentials, and fixture-level proof that repository content and configuration remain unchanged.

- [ ] Task 21 - Integrate explicit local-repository reconnection.
  - Size: Standard
  - Status: Blocked on an approved portable local canonical-identity mechanism.
  - Purpose: Reuse normal worker validation without treating package control as local repository authority.
  - Owned surfaces: Local reconnection action, existing worker authorization and repository-validation reuse, canonical local repository identity binding, success and failure handoff, no packaged path or credential acceptance, and repository content, branch, remote, setting, and Git-configuration non-mutation.
  - Owns: AC-22
  - Depends on: Task 13
  - Proof: Focused worker-contract tests cover unavailable, failed, and successful validation, canonical identity mismatch, absence of packaged paths and credentials, and fixture-level proof that repository content and configuration remain unchanged.

- [ ] Task 15 - Build restore conflict recovery and completion interface.
  - Size: Standard
  - Purpose: Present identity and repository hard blocks, name-only recovery, cancellation, and successful completion clearly.
  - Owned surfaces: Same-identity blocking state, name-only conflict form and inline validation, canonical-repository blocking state and precedence, cancellation, successful restored-project result, unconnected-repository explanation and explicit reconnection action, responsive accessibility behavior, and absence of cross-user sharing or create-copy claims.
  - Owns: AC-18
  - Depends on: Task 14, Task 20, Task 21
  - Proof: Focused LiveView plus desktop and mobile browser scenarios cover same-identity rejection, valid and invalid replacement names, repeat conflict, repository conflict with no bypass, cancellation, completion, reconnection boundary copy, keyboard and focus behavior, and prohibited sharing or copy claims.

- [ ] Task 16 - Enforce transient package and attempt cleanup.
  - Size: Standard
  - Purpose: Remove service-held package material after its active operation and recover stranded encrypted state.
  - Owned surfaces: No completed service-package retention, immediate passphrase, derived-key, and decrypted-content disposal verification, immediate terminal encrypted-generation and restore-upload cleanup, 24-hour stranded encrypted-temporary and `ImportAttempt` retention rule, idempotent `Privacy.Retention.prune_all/1` integration, supervised `RetentionPruner` execution, cleanup reconciliation, and no temporary data in backups, caches, or indexes.
  - Owns: AC-16
  - Depends on: Task 4
  - Proof: Focused terminal, stranded, time-boundary, idempotency, advisory-lock, restart, reconciliation, and negative persistence tests prove immediate disposal and the 24-hour cleanup ceiling without deleting active attempts.

- [ ] Task 17 - Enforce the project-bound provenance lifecycle.
  - Size: Standard
  - Status: Blocked until `capability:project-storage-governance` and Task 16 are complete.
  - Purpose: Minimize persistent restoration provenance and tie it to the restored project's deletion lifecycle.
  - Owned surfaces: `capability:project-storage-governance` consumer, minimal schema-version and restoration-time `PackageProvenance`, project-bound provenance access, project-deletion cascade, service-termination handling, derived-record deletion propagation, and no package hash, filename, source account, workspace, device, exporter, network, or source-mode field.
  - Owns: AC-19
  - Depends on: Task 16, Task 19
  - Proof: Focused provenance-field, access, hosted and device project-erasure, service-termination, cascade, and derived-record tests prove minimal retention without a source-identity link.

- [ ] Task 22 - Propagate verified portability rights.
  - Size: Standard
  - Status: Blocked until `capability:project-specification-governance` and Task 17 are complete.
  - Purpose: Apply verified rights actions across the project, its restored specifications, attempts, provenance, derived records, processors, and backup expiry.
  - Owned surfaces: `capability:project-specification-governance` consumer, `Privacy.Rights` integration, verified access, correction, erasure, restriction, objection, and portability behavior, project and specification authorization, `ImportAttempt` and `PackageProvenance` coverage, derived-record and processor propagation, backup-expiry handoff, and cross-project non-disclosure.
  - Owns: AC-23
  - Depends on: Task 17
  - Proof: Focused rights, authorization, cross-project isolation, attempt, provenance, restored-specification, derived-record, processor, and backup-propagation tests prove complete handling without disclosing another project or identity.

- [ ] Task 18 - Enforce minimized operational-security logging.
  - Size: Standard
  - Purpose: Record only the minimum security event needed to operate backup and restoration safely.
  - Owned surfaces: Fixed structured security-log event type, time, outcome, and non-secret correlation identifier, package, project-content, repository-identifier, filename, path, passphrase, and decrypted-field redaction, 30-day log-expiry configuration, audit minimization, and log, diagnostic, and error-path scans.
  - Owns: AC-20
  - Depends on: Task 16
  - Proof: Focused structured-log schema, redaction, failure-path, correlation, 30-day expiry, audit-minimization, diagnostic, and secret-exposure checks pass.

- [ ] Task 23 - Enforce encrypted-backup expiry.
  - Size: Standard
  - Purpose: Bound recovery copies without weakening verified deletion propagation.
  - Owned surfaces: 35-day encrypted rolling-backup expiry configuration, `DeploymentPrivacyProfile` evidence, approved recovery-only restoration boundary, deletion-propagation handoff, processor configuration, and release-gate evidence classification.
  - Owns: AC-24
  - Depends on: Task 17, Task 22
  - Proof: Focused deployment-profile, expiry-boundary, recovery authorization, deletion-propagation, processor-configuration, and release-gate checks prove the 35-day ceiling without claiming deployment evidence that is not locally available.

- [ ] Task 24 - Prohibit portability secondary use and agent access.
  - Size: Standard
  - Purpose: Prevent package and restoration data from becoming analytics, training, identity-tracking, or agent input.
  - Owned surfaces: No analytics, advertising, model training, identity tracking, or unrelated improvement, no coding-agent or model-provider access, genuinely anonymous aggregate boundary, and negative telemetry, cache, index, export, diagnostic, and content-routing scans.
  - Owns: AC-25
  - Depends on: Task 18, Task 23
  - Proof: Focused negative secondary-use, agent-access, model-provider, telemetry, analytics-identifier, cache, index, export, diagnostic, and content-routing checks pass.

- [ ] Task 7 - Complete the backup privacy and security review.
  - Size: Standard
  - Status: Blocked until both governance capabilities and all preceding implementation tasks are complete.
  - Purpose: Confirm the complete portability data flow follows the approved privacy and security contract before publishing the capability.
  - Owned surfaces: Active processing inventory, approved service and security purposes and lawful bases, authorized-user and operations access controls, processor and transfer configuration, audit minimization, consolidated privacy and security review, release-gate classification, and `capability:project-portability` readiness write-back.
  - Owns: AC-12
  - Depends on: Task 6, Task 15, Task 22, Task 24
  - Proof: Focused data-inventory, purpose and basis, necessity, access, processor, transfer, audit-minimization, cross-task lifecycle, required privacy, and security reviews pass before capability readiness is recorded.

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

- Technical design and data handling: Slice 02's implemented local repository fingerprint is HMAC-keyed by the source device-workspace salt, but this slice excludes source workspace identity and environment-specific connection state from the package. A different authorized destination therefore cannot reproduce the packaged fingerprint through normal worker validation. Before Task 21, approve a non-reversible canonical-identity mechanism that supports exact post-restore validation and defines cross-workspace linkability plus legacy-fingerprint handling. This blocks technical-design readiness and active-slice implementation; it does not invalidate Tasks 1–20 or change the release-only deployment evidence.

## Progress Log

### 2026-07-28 - Task 21 blocked: local canonical identity is not portable

- Completed: Task 21 preflight traced the packaged local repository identity to Slice 02's worker validation and confirmed that its HMAC key is the source device-workspace salt. The package correctly excludes that workspace identity, local paths, and connection metadata, so a target worker cannot reproduce the exact packaged fingerprint after restoration.
- Remaining: Approve and specify a non-reversible portable local canonical-identity mechanism, including cross-workspace linkability and legacy-fingerprint behavior, through `update-spec`; then resume Task 21.
- Failed checks: No implementation check failed. The approved contracts are internally incomplete at the local reconnection seam, so application changes stopped before mutation.
- Spec updates: Marked the slice and Task 21 blocked, recorded the technical-design question, and preserved all completed task and capability state.

### 2026-07-28 - Task 20 complete: explicit GitHub repository reconnection

- Completed: Added `GitHubReconnection` on top of the current account credential, GitHub identity, installation-access check, and metadata-read accessible-repository listing. The action rebinds only when the current provider result contains the exact packaged numeric repository ID; creates a normal hosted `RepositoryConnection` or atomically marks the exact device identity connected; is idempotent after success; and returns distinct authorization-required, provider-unavailable, canonical-mismatch, invalid-request, and unavailable-destination outcomes without accepting packaged or stale credentials. The device-store operation validates the provider and canonical ID before changing status.
- Remaining: Integrate explicit local-repository reconnection through worker validation in Task 21.
- Failed checks: None. Final proof passes: 67 focused GitHub reconnection, unconnected-boundary, provider discovery, hosted connection, registration, and device constraint tests, including a Git fixture proving content, HEAD, branches, remotes, status, and local configuration remain unchanged; `git diff --check`; `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix credo --strict`; `mix deps.audit`; and `mix sobelow --config`.
- Spec updates: Marked Task 20 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 13 complete: unconnected restored-repository boundary

- Completed: Added a read-only `RepositoryReconnection` handoff that is available only for project-bound restored provenance and returns one minimized explicit request for either normal GitHub authorization or normal local-worker validation. Hosted restoration creates no `RepositoryConnection`; device restoration persists a disconnected status; package control never becomes repository authority; and the handoff accepts no credential or path, contacts no provider or worker, performs no automatic reconnection, and mutates no project or connection state.
- Remaining: Integrate the explicit GitHub and local-repository reconnection actions in Tasks 20 and 21.
- Failed checks: None. Final proof passes: 27 focused reconnection-boundary, hosted and device restore, and package-policy tests, `git diff --check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 13 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 19 complete: device-authoritative atomic restoration

- Completed: Extended the device project value with its owning device workspace and provider-neutral canonical repository identity; added device-local minimal provenance access; and implemented `DeviceRestore` through one worker-owned `DeviceTransaction` containing project, provenance, and shared specification-store contributions. The serialized DETS adapter validates authority and contribution shape, gives repository conflict precedence, checks global device specification identities, constructs every object before one persistence call, returns exact replays, recovers a simulated lost acknowledgement, survives worker-store restart, and leaves hosted project, provenance, and specification tables empty. The shared deterministic specification-revision derivation now lives in one restore-package boundary used by both adapters.
- Remaining: Preserve the unconnected restored-repository boundary in Task 13.
- Failed checks: The first device regression run showed that direct device registration historically establishes its workspace implicitly; the additive repository fields initially assumed a workspace already existed. Registration now preserves that contract by fetching or creating the workspace inside the serialized store operation. Strict Credo also requested alias ordering. Final proof passes: 100 focused device restore, hosted restore, snapshot, conflict, device-store, worker, and specification-transaction tests; the device restore suite passed ten repeated concurrency runs; `git diff --check`; `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix credo --strict`; `mix deps.audit`; `mix sobelow --config`; the Slice 06 validator; and the global dependency graph.
- Spec updates: Marked Task 19 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 12 complete: hosted atomic restoration

- Completed: Added project-level canonical repository identity fields and a workspace-scoped database uniqueness constraint shared by normal registration and restoration; backfilled existing hosted registrations; added the minimal project-keyed `PackageProvenance`; and implemented `HostedRestore` as one `Ecto.Multi` covering the caller-supplied stable project ID, explicit display name, canonical repository identity, hosted storage root, payload schema version and restoration time, and the shared specification-store restore contribution. Restored projects have no repository connection. Exact committed retries reconcile the same aggregate, while different same-ID records, stale name or repository preflight races, specification identity collisions, and injected failures return structured errors with full rollback.
- Remaining: Implement the device-authoritative atomic restoration adapter in Task 19.
- Failed checks: The first broader regression run showed that requiring repository identity in the generic registration changeset broke the specification-store provider's caller-owned transaction fixtures; the repository pair remains optional at that generic seam while the public registration path supplies it and the restore changeset requires it. Strict Credo also requested alias ordering. Final proof passes: 136 focused hosted restore, conflict, snapshot, specification-transaction, registration, and identity-linking tests including 5 properties; the hosted restore suite also passed ten repeated concurrency runs; `git diff --check`; `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix credo --strict`; `mix deps.audit`; `mix sobelow --config`; the Slice 06 validator; and the global dependency graph.
- Spec updates: Marked Task 12 complete and recorded deterministic UUIDv5-shaped revision identities derived from the packaged project and specification IDs as the idempotent bridge to the shared specification-store contribution; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 11 complete: restore conflict decisions

- Completed: Added a non-persistent `RestoreDecision` value and a `RestoreConflicts` evaluator with explicit precedence for stable identity, canonical repository identity, and then case-insensitive display name. The evaluator preserves packaged project and repository identities, blocks repository collisions even when a replacement name is supplied, permits one explicit validated and available replacement only for a name-only conflict, rejects repeat name collisions and unrequested renames, and uses the destination's existing hosted or device uniqueness rules without relinking, unlinking, substituting, auto-renaming, or mutating records.
- Remaining: Implement the hosted atomic restoration adapter in Task 12.
- Failed checks: None. Final proof passes: 47 focused conflict, preflight, hosted constraint, and device constraint tests, `git diff --check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 11 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 5 complete: visibility-bounded stable-identity preflight

- Completed: Added a read-only `RestorePreflight` boundary that validates the packaged stable project ID, always checks the selected authorized destination, checks only additional hosted or device authorities already held by the current restore session, rechecks device availability without contacting a worker, skips unavailable non-selected device catalogs, blocks an unavailable selected device destination, deduplicates authority checks, and returns a structured same-identity conflict without overwrite, merge, update, rename, telemetry, synchronization, or authority selection. Confirmed the existing combined-catalog handoff keeps later-visible same-ID entries separate and conflict-marked.
- Remaining: Implement display-name and canonical-repository conflict decisions in Task 11.
- Failed checks: None. Final proof passes: 12 focused preflight and combined-catalog tests, `git diff --check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 5 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 14 complete: restore intake and package validation interface

- Completed: Added a dedicated restore entry from signed-in and accountless project surfaces; required explicit hosted or connected-device destination selection with setup handoffs; accepted one bounded `.sddbackup` upload and a transient passphrase; ran isolated validation with progress, compatible, missing or incorrect passphrase, unsafe, unsupported, authorization, and cancellation states; retained only the encrypted attempt identifier after successful validation; and kept project persistence untouched. The controls provide keyboard activation, focused actionable errors, mobile-width actions, and accessible desktop and mobile rendering.
- Remaining: Implement visibility-bounded stable-identity preflight in Task 5.
- Failed checks: The first browser runs exposed reused-device worker and LiveView join timing races in test setup; the helper now pairs through the existing event, waits for the joined LiveView, and waits for acknowledged storage selection. Strict Credo requested reducing upload-reader nesting, and Sobelow identified LiveView's framework-generated temporary upload path as a low-confidence traversal finding; the reader was extracted and the trusted framework boundary was documented. Final proof passes: 26 focused LiveView and navigation tests, the restore round-trip Playwright scenario in desktop Chromium and mobile Chromium, `git diff --check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, `mix sobelow --config`, the Slice 06 validator, and the global dependency graph.
- Spec updates: Marked Task 14 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 10 complete: package compatibility and safety validation

- Completed: Added strict duplicate-preserving JSON decoding, non-finite-number rejection, supported-major additive-field normalization, explicit prohibited attachment, filesystem, repository-source, credential, and executable-key rejection, encrypted and decompressed size ceilings, compression expansion-ratio enforcement, bounded Argon2 parameter validation before derivation, specification-count, document-size, field-length, provider, stable-identity, and duplicate-specification checks, and structured malformed, unsupported, oversized, unsafe, or opaque passphrase results. Restore intake now runs this validator before exposing a transient package to later preflight work.
- Remaining: Build the restore intake and validation interface for hosted and device destinations in Task 14.
- Failed checks: Strict Credo identified seven initial complexity and nesting opportunities in the validator and strict decoder; validation was split into focused shape, limit, recursive conversion, and list helpers. One test exposed a missing required encryption field being classified as unsupported rather than malformed; the version branch was narrowed. Final proof passes: the combined codec, encryption, intake, and validator suites (28 tests, including 1 property), `git diff --check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 10 complete and recorded the approved configuration-tunable resource ceilings; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 4 complete: encrypted restore intake and terminal cleanup

- Completed: Added the transient `ImportAttempt` boundary with explicit hosted or device destination ownership, 24-hour expiry, uploaded and validating states, Cloak field encryption for hosted uploads, an additional local-vault seal for device-store uploads, separately verified destination authorization, opaque passphrase and package failure, transient decryption handoff, and idempotent immediate deletion on failure, cancellation, and completion. Accountless device intake remains in the device store and creates no hosted attempt or project record.
- Remaining: Implement strict package compatibility, safety, and bounded-resource validation in Task 10.
- Failed checks: Strict Credo requested replacing a one-clause device-cleanup `with` with `case`; corrected. Final proof passes: the combined restore-intake and encryption suites (12 tests), `git diff --check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 4 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 6 complete: backup creation and encrypted download

- Completed: Added authorized hosted and device backup routes from each project dashboard; presented the three included logical content categories and all required excluded categories; required matching recovery-passphrase creation plus explicit unrecoverable-loss acknowledgement; generated the current authorized package; emitted encrypted bytes directly to a browser-owned download without retaining the package or passphrase in LiveView assigns; returned focused actionable validation and generation failures; and provided cancel, keyboard, responsive, accessibility, and no-sharing-or-create-copy behavior.
- Remaining: Implement encrypted restore intake, destination authorization, terminal cleanup, and its isolated attempt lifecycle in Task 4.
- Failed checks: The first browser run found a stale reused development worker and the second exposed an onboarding disclosure timing race in test setup; the browser helper now pairs the configured stand-in through the existing LiveView boundary and waits for disclosure confirmation. Strict Credo requested replacing a one-clause `with` with `case`; corrected. Final proof passes: 24 focused LiveView and dashboard tests, the Task 6 Playwright scenario in desktop Chromium and mobile Chromium, `git diff --check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 6 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 3 complete: passphrase derivation and authenticated encryption

- Completed: Added `argon2_elixir` and configured Argon2id time cost 3, 64 MiB memory, and parallelism 1 defaults; derived transient 32-byte raw keys from per-package 16-byte salts; encrypted compressed payloads with AES-256-GCM, random 12-byte nonces, and 16-byte tags; authenticated every cleartext version, compression, KDF, salt, nonce, and length field as additional data; returned one opaque restore failure; and added a deterministic encrypted golden fixture through fixed test-only material.
- Remaining: Build the backup creation and encrypted-download interface in Task 6, while restore intake can now consume the same cryptographic boundary in Task 4.
- Failed checks: Initial compilation required pinned bitstring sizes in the implementation and test helper; both were corrected. Final proof passes: the codec and encryption suites (12 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 3 complete and recorded the resolved dependency version and raw-key mechanism; requirements, design, ownership, dependencies, and capability edges are unchanged.
- Local engineering decision: `argon2_elixir` 4.1.3 returns `:raw_hash` as hexadecimal text, so the boundary decodes it to the approved 32-byte AES key and never exposes either representation.

### 2026-07-28 - Task 9 complete: payload allowlist and secret exclusion

- Completed: Added a fail-closed `PayloadPolicy` with exact project, repository, and specification field maps, explicit source-schema drift proof, no association traversal, and high-confidence private-key, GitHub, model-provider, AWS, bearer, token, password, passphrase, client-secret, and API-key signature rejection before encryption. Inert command- and path-looking document prose remains data and is never executed.
- Remaining: Implement Argon2id derivation and authenticated package encryption in Task 3.
- Failed checks: Strict Credo initially identified a redundant final `with` clause; it was simplified. Final proof passes: the combined snapshot and payload-policy suites (8 tests), `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 9 complete; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 2 complete: authorized allowlisted project snapshot

- Completed: Added an authorized hosted and device `BackupSnapshot` mapper that reads current specification heads only through `SpecificationStore.current_snapshot/2`, preserves stable project and specification identities, maps only project id and name, provider and canonical repository identity, and each specification title and three current documents, then hands the versioned sections to the deterministic codec. Device snapshots create no hosted copy.
- Remaining: Enforce the payload and secret-exclusion boundary in Task 9, then continue encryption and the dependency-ordered backup and restoration workflow.
- Failed checks: None. Final proof passes: the focused hosted and device snapshot suite (4 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 2 complete and removed its delivered capability blocker; requirements, design, ownership, dependencies, and capability edges are unchanged.

### 2026-07-28 - Task 8 complete: deterministic package codec

- Completed: Added the versioned `ProjectPackage` and `PackageSection` value boundaries plus a deterministic codec with recursively sorted JSON keys, fixed project, repository, and specifications section order, versioned cleartext envelope, zlib DEFLATE compression, bounded streaming decompression, exact body-length framing, and committed golden payload and single-file package fixtures. The codec reads no project persistence and leaves encryption to Task 3.
- Remaining: Deliver `capability:project-specification-store` through Slice 09 Task 8, then resume Task 2 and the remaining dependency-ordered portability work.
- Failed checks: Initial compilation rejected remote calls in guards and strict Credo found one redundant final `with` clause; both were corrected. Final proof passes: `MIX_ENV=test mix test test/sdd_orchestrator/portability/package_codec_test.exs` (6 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 8 complete and the slice `Blocked` because Task 2 is now the next incomplete task and its specification-store capability is not yet available.

### 2026-07-28 - Specification-store provider task refined

- Completed: Updated the `capability:project-specification-store` edge to its refined provider `specs/09-project-specification-storage#Task 8`; the capability contract and Slice 06 consumer boundary are unchanged.
- Remaining: Implement ready Task 8; complete the specification-store provider before Task 2 and specification-store governance before Task 22; finish the remaining dependency-ordered tasks and verification gate.
- Failed checks: None in this specification; its individual validator and the global capability graph pass.
- Spec updates: Changed only the provider task reference and current blocker wording; task sizing, ownership, acceptance criteria, design, and approved behavior remain unchanged.

### 2026-07-28 - Task-size and execution sequence refined

- Completed: Applied the Task Size Gate, preserved every existing task label, split the six unfinished broad tasks into twenty-three standard implementation tasks with focused proof, and moved package-format work ahead of the unavailable provider capabilities.
- Remaining: Implement ready Task 8; complete the authority and specification-store provider tasks before Task 2; complete project-storage governance before Task 17 and specification-store governance before Task 22; finish the remaining dependency-ordered tasks and verification gate.
- Failed checks: None; implementation has not started.
- Spec updates: Changed task status from `Blocked` to `Not Started` because Task 8 is executable, moved governance capability consumption to its earliest consumer, split UI, validation, conflict, hosted and device restore, GitHub and local reconnection, cleanup, rights, logging, backup, secondary-use, and review ownership, and added AC-17 through AC-25 without changing approved behavior.

### 2026-07-28 - Cross-specification prerequisites corrected

- Completed: Replaced the implicit dependency on Slice 07's later-owned `SpecificationRevision` with the focused `capability:project-specification-store`, recorded the separate project-storage authority prerequisite, and kept portability as the owner of package, cryptographic, intake, conflict, and restore workflow behavior.
- Remaining: Complete the authority and specification-store provider tasks, return this slice to `Not Started`, complete both governance providers before Task 7, implement Tasks 2–7, and run the verification gate.
- Failed checks: None; implementation has not started.
- Spec updates: Changed task status from `Not Started` to `Blocked`, added task-level capability dependencies, made Task 2 and Task 5 explicit consumers of the shared specification store, and prohibited duplicate specification persistence.

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
