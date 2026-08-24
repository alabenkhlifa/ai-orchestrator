# Project Backup And Restoration Tasks

## Status

Verified

All implementation tasks and the complete local verification gate pass. `capability:project-portability` is ready. Public release readiness remains separately gated on deployment-specific controller, processor, region, transfer, notice, incident, retention-enforcement, and accountable privacy or legal evidence.

## Active Slice

Deliver passphrase-encrypted backup and restoration of one minimal project package containing stable project ID and display name, non-secret canonical repository identity, and current specification identity and `requirements.md`, `design.md`, and `tasks.md` content, while preserving the stable project identity, rejecting an existing same-project identity, and providing version, integrity, secret exclusion, validation, and atomic restore behavior.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 2`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 17`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 2`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 22`.
- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 26`.
- `capability:portable-local-repository-identity` — provider `specs/02-local-project-onboarding#Task 9` — required before `Task 25`.

Provides:

- `capability:project-portability` — ready after `Task 7`.
- `capability:local-repository-worker-validation` — ready after `Task 21`.
- `capability:hosted-local-repository-binding` — ready after `Task 26`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Existing task labels are preserved; newly split tasks use the next unused labels and are listed by dependency order rather than numeric order. The hosted local-worker foundation and hosted reconnection adapter are Tasks 26 and 27, while Task 21 is narrowed to the device adapter and shared exact worker-validation boundary.

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
- Portable local repository-identity readiness, a source-side legacy-upgrade handoff before package generation, and exact target-worker reconnection without source workspace identity.
- An explicit minimal and revocable hosted-project-to-device-worker binding after separate personal-workspace and device-workspace authorization and exact validation.
- User-entered display-name recovery for a name-only conflict and blocking canonical-repository conflicts.
- Approved package, temporary-data, provenance, log, backup, processor, rights, no-reuse, security, compatibility, and responsive browser proof.

Excluded:

- Cross-user sharing, package exchange, ownership transfer, and creating a copy with a new identity.
- Updating, merging, replacing, or restoring over an existing project.
- Repository source, credentials, sessions, worker device data beyond the approved opaque binding, agent data, collaboration memberships, and arbitrary executable artifacts.
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

- [x] Task 25 - Enforce portable local identity before package generation.
  - Size: Standard
  - Purpose: Prevent a legacy workspace-scoped local fingerprint from being packaged as if a replacement worker could validate it.
  - Owned surfaces: Portable local canonical-identifier recognition in snapshot and package validation, local backup readiness, legacy-identity rejection before encryption, actionable source-side `Locate repository` upgrade handoff in the backup interface, retry after upgrade, versioned-identifier allowlist proof, and no package, project, connection, or repository mutation on blocked backup.
  - Owns: AC-26
  - Depends on: Task 6
  - Proof: Focused snapshot, validation, backup-service, LiveView, and desktop and mobile browser tests cover portable success, legacy blocking, upgrade handoff, retry after exact source upgrade, malformed identity rejection, no encrypted artifact on failure, and unchanged project and repository state.
  - Delivered: `BackupSnapshot` and `PackageValidator` accept only the strict Slice 02 versioned portable identifier for local repositories. Legacy device projects stop before encryption with an explicit source-side `Locate repository` action, malformed identities fail closed without a backup form, exact source upgrade updates both device canonical-identity fields atomically, and a subsequent retry exports the portable identifier. The device dashboard exposes backup only when ready; blocked attempts create no package or persistent mutation.

- [x] Task 26 - Establish the hosted local-worker binding foundation.
  - Size: Standard
  - Purpose: Represent one approved hosted-project-to-worker link without reusing GitHub connection fields or making device project data hosted-authoritative.
  - Owned surfaces: `capability:hosted-local-repository-binding`, `HostedLocalRepositoryBinding`, hosted migration and schema, project and worker references, one-binding-per-project constraint, exact project-provider validation, minimum project ID, worker ID, and last-validation-time fields, personal-workspace project access, selected device-workspace worker authorization, idempotent same-binding result, atomic replacement contract, explicit disconnect, worker-revocation deletion, project-erasure cascade, service-termination handling, temporary-unavailability derivation, processing-inventory registration, and credential, path, duplicate workspace, duplicate repository-identity, device-label, and compatibility-field exclusion.
  - Owns: entity:HostedLocalRepositoryBinding
  - Depends on: Task 13, Task 25
  - Proof: Focused migration, constraint, authorization, field-minimization, access, idempotency, replacement, disconnect, worker-revocation, project-erasure, service-termination, unavailable-state, inventory, and forbidden-field tests prove one revocable hosted binding without device project data or repository mutation.
  - Delivered: Added the three-field project-keyed `HostedLocalRepositoryBinding`, scoped dual-workspace persistence boundary, portable local-project and exact-identifier checks, active reachable worker authorization, idempotent retention, atomic replacement, scoped disconnect, derived temporary-unavailability state, project and worker deletion cascades, database-enforced deletion on worker revocation, service-termination cleanup, project and worker associations, and the approved processing-inventory record without paths, credentials, duplicate workspace or repository identities, device labels, compatibility fields, or device project data.

- [x] Task 21 - Integrate explicit device local-repository reconnection.
  - Size: Standard
  - Purpose: Reuse normal worker validation for a device-authoritative restored project without treating package control as local repository authority.
  - Owned surfaces: `capability:local-repository-worker-validation`, shared exact local-worker validation boundary, device reconnection action, existing device-workspace worker authorization and portable repository-validation reuse, project-held identifier handoff, exact device-store canonical local repository identity binding without source workspace identity, success, unavailable, malformed, legacy, mismatch, and failed-authorization results, no hosted binding, packaged path, or credential acceptance, and repository content, branch, remote, setting, and Git-configuration non-mutation.
  - Owns: AC-22
  - Depends on: Task 13, Task 25
  - Proof: Focused shared worker-contract and device-store tests cover unavailable, failed, and successful validation, exact portable match, canonical identity mismatch, malformed and legacy identifiers, source-workspace independence, absence of hosted records, packaged paths, and credentials, and fixture-level proof that repository content and configuration remain unchanged.
  - Delivered: Added a shared minimized `LocalRepositoryValidation` boundary that parses only portable identifiers, authenticates the current worker credential, reuses device-workspace authorization and worker reachability, and invokes a worker-local exact matcher without receiving a path. Added `LocalRepositoryReconnection` for restored device projects, with exact request rebinding, idempotent success, device-store canonical-identity enforcement, actionable malformed, legacy, mismatch, authorization, worker, repository, and destination failures, no hosted binding, and no repository or Git-configuration mutation.

- [x] Task 27 - Integrate explicit hosted local-repository reconnection.
  - Size: Standard
  - Purpose: Connect a restored hosted local-repository project only through separate project and device authority plus exact worker proof.
  - Owned surfaces: Hosted local reconnection action, owning `PersonalWorkspace` authorization, explicit current `DeviceWorkspace` selection, active paired-worker authorization, Task 21 exact worker-validation consumer, project-held portable identifier handoff, `HostedLocalRepositoryBinding` insertion, idempotent retry, exact atomic worker replacement, explicit disconnect, connected, temporarily unavailable, revoked, malformed, legacy, mismatch, failed-authorization, and unavailable results, no implicit account-device association, no packaged connection, path, credential, or source workspace acceptance, and repository content and configuration non-mutation.
  - Owns: AC-27
  - Depends on: Task 21, Task 26
  - Proof: Focused hosted reconnection, dual-authority, active-worker, binding, idempotency, replacement, disconnect, revocation, unavailability, malformed, legacy, mismatch, cross-workspace denial, forbidden-field, and unchanged-Git-fixture tests prove the exact minimal binding and preserve the previous binding on every failed replacement.
  - Delivered: Added `HostedLocalRepositoryReconnection` as the narrow consumer of the restored-project request, Task 21 shared worker proof, and Task 26 transactional binding foundation. It requires the owning personal workspace, explicitly selected device workspace, current active reachable worker credential, and exact portable match; creates, refreshes, or replaces only the minimized binding; exposes a worker-free derived connection state; supports scoped idempotent disconnect; removes the binding on revocation; and preserves the prior binding and repository on every invalid, unavailable, unauthorized, malformed, legacy, mismatch, repository, or worker failure.

- [x] Task 15 - Build restore conflict recovery and completion interface.
  - Size: Standard
  - Purpose: Present identity and repository hard blocks, name-only recovery, cancellation, and successful completion clearly.
  - Owned surfaces: Same-identity blocking state, name-only conflict form and inline validation, canonical-repository blocking state and precedence, cancellation, successful restored-project result, unconnected-repository explanation and explicit reconnection action, responsive accessibility behavior, and absence of cross-user sharing or create-copy claims.
  - Owns: AC-18
  - Depends on: Task 14, Task 20, Task 21, Task 27
  - Proof: Focused LiveView plus desktop and mobile browser scenarios cover same-identity rejection, valid and invalid replacement names, repeat conflict, repository conflict with no bypass, cancellation, completion, reconnection boundary copy, keyboard and focus behavior, and prohibited sharing or copy claims.
  - Delivered: Extended the restore LiveView from validation into an explicit second-step conflict check and atomic restore, with transient passphrase re-entry; same-identity and repository hard blocks; repository-conflict precedence; name-only recovery with inline blank and repeat validation; terminal cancellation cleanup; stable-identity completion; and destination-specific GitHub or local-worker reconnection actions. Added focus events, narrow-mobile full-width controls, accessible status and alert states, and copy that excludes sharing, create-copy, alternate-repository, and relink claims.

- [x] Task 16 - Enforce transient package and attempt cleanup.
  - Size: Standard
  - Purpose: Remove service-held package material after its active operation and recover stranded encrypted state.
  - Owned surfaces: No completed service-package retention, immediate passphrase, derived-key, and decrypted-content disposal verification, immediate terminal encrypted-generation and restore-upload cleanup, 24-hour stranded encrypted-temporary and `ImportAttempt` retention rule, idempotent `Privacy.Retention.prune_all/1` integration, supervised `RetentionPruner` execution, cleanup reconciliation, and no temporary data in backups, caches, or indexes.
  - Owns: AC-16
  - Depends on: Task 4
  - Proof: Focused terminal, stranded, time-boundary, idempotency, advisory-lock, restart, reconciliation, and negative persistence tests prove immediate disposal and the 24-hour cleanup ceiling without deleting active attempts.
  - Delivered: Extended the shared retention pass with exact 24-hour hosted and device `ImportAttempt` rules, including expiry fallback, idempotent deletion counts, an unavailable-device no-op that reconciles on the next pass, and device-store atomic scan, delete, and sync behavior. Preserved immediate terminal intake deletion, the supervised hourly pruner, and its PostgreSQL advisory lock; confirmed the attempt schema contains only encrypted temporary payload and lifecycle fields and no secret, decrypted-content, filename, path, or package-hash field.

- [x] Task 17 - Enforce the project-bound provenance lifecycle.
  - Size: Standard
  - Purpose: Minimize persistent restoration provenance and tie it to the restored project's deletion lifecycle.
  - Owned surfaces: `capability:project-storage-governance` consumer, minimal schema-version and restoration-time `PackageProvenance`, project-bound provenance access, project-deletion cascade, service-termination handling, derived-record deletion propagation, and no package hash, filename, source account, workspace, device, exporter, network, or source-mode field.
  - Owns: AC-19
  - Depends on: Task 16, Task 19
  - Proof: Focused provenance-field, access, hosted and device project-erasure, service-termination, cascade, and derived-record tests prove minimal retention without a source-identity link.
  - Delivered: Added one project-authorized provenance boundary for hosted and device storage; hosted reads join through the owning personal workspace, while device reads require the current device workspace and exact device project. Hosted database cascades and account erasure remove provenance with the project; device project deletion now removes and syncs provenance with specification aggregates; hosted service termination is idempotent. Registered the exact three-field record and its dual storage lifecycle without any source-identity field.

- [x] Task 22 - Propagate verified portability rights.
  - Size: Standard
  - Purpose: Apply verified rights actions across the project, its restored specifications, attempts, provenance, derived records, processors, and backup expiry.
  - Owned surfaces: `capability:project-specification-governance` consumer, `Privacy.Rights` integration, verified access, correction, erasure, restriction, objection, and portability behavior, project and specification authorization, `ImportAttempt`, `HostedLocalRepositoryBinding`, and `PackageProvenance` coverage, derived-record and processor propagation, backup-expiry handoff, and cross-project non-disclosure.
  - Owns: AC-23
  - Depends on: Task 17, Task 27
  - Proof: Focused rights, authorization, cross-project isolation, attempt, hosted local-worker binding, provenance, restored-specification, derived-record, processor, and backup-propagation tests prove complete handling without disclosing another project or identity.
  - Delivered: Extended the verified operator boundary with minimized account-level import-attempt metadata, project-authorized hosted and device portability exports, exact hosted binding and provenance output, hosted revision history and device current restored specifications, hosted and device project-name correction, shared specification revision correction, and project erasure through the existing lifecycle cascade. Erasure returns explicit primary-store, derived-record, processor, and 35-day recovery-only backup handoffs; restriction and objection return an explicit verified-operator assessment requirement with the same propagation scope instead of claiming an automatic legal decision.

- [x] Task 18 - Enforce minimized operational-security logging.
  - Size: Standard
  - Purpose: Record only the minimum security event needed to operate backup and restoration safely.
  - Owned surfaces: Fixed structured security-log event type, time, outcome, and non-secret correlation identifier, package, project-content, repository-identifier, hosted binding, worker, device-workspace, filename, path, passphrase, and decrypted-field redaction, 30-day log-expiry configuration, audit minimization, and log, diagnostic, and error-path scans.
  - Owns: AC-20
  - Depends on: Task 16, Task 27
  - Proof: Focused structured-log schema, redaction, failure-path, correlation, 30-day expiry, audit-minimization, diagnostic, and secret-exposure checks pass.
  - Delivered: Added one fixed portability security-event boundary with only event type, UTC occurrence time, coarse outcome, and a generated non-secret correlation identifier. Backup generation, restore intake and validation, terminal cleanup, hosted and device restore commits, and GitHub, device-local, and hosted-local reconnection and disconnection paths emit through that boundary without inspecting or serializing package data, project content, repository identities, bindings, workers, workspaces, filenames, paths, passphrases, decrypted fields, or error details. The deployment privacy profile is the single source for the 30-day operational-log expiry.

- [x] Task 23 - Enforce encrypted-backup expiry.
  - Size: Standard
  - Purpose: Bound recovery copies without weakening verified deletion propagation.
  - Owned surfaces: 35-day encrypted rolling-backup expiry configuration, `DeploymentPrivacyProfile` evidence, approved recovery-only restoration boundary, deletion-propagation handoff, processor configuration, and release-gate evidence classification.
  - Owns: AC-24
  - Depends on: Task 17, Task 22
  - Proof: Focused deployment-profile, expiry-boundary, recovery authorization, deletion-propagation, processor-configuration, and release-gate checks prove the 35-day ceiling without claiming deployment evidence that is not locally available.
  - Delivered: Added one structured encrypted-backup lifecycle contract and deployment-evidence check. It requires encryption, expiry at or below 35 days, recovery-only restoration, mandatory deletion propagation, and non-blank processor, agreement, region, transfer, retention-enforcement, recovery-authorization, and privacy-review evidence. Verified rights handoffs now consume the same fixed lifecycle contract. Missing or invalid deployment evidence blocks only the explicit public-release readiness check; implementation and local verification remain independently testable.

- [x] Task 24 - Prohibit portability secondary use and agent access.
  - Size: Standard
  - Purpose: Prevent package and restoration data from becoming analytics, training, identity-tracking, or agent input.
  - Owned surfaces: No analytics, advertising, model training, identity tracking, or unrelated improvement, no coding-agent or model-provider access, hosted local-worker binding exclusion from secondary use, genuinely anonymous aggregate boundary, and negative telemetry, cache, index, export, diagnostic, and content-routing scans.
  - Owns: AC-25
  - Depends on: Task 18, Task 23
  - Proof: Focused negative secondary-use, agent-access, model-provider, telemetry, analytics-identifier, cache, index, export, diagnostic, and content-routing checks pass.
  - Delivered: Added a fail-closed portability data-use policy that permits only explicit backup, restore, repository-routing, security, lifecycle, and verified-rights purposes and recipients. Analytics, advertising, model training, identity tracking, unrelated product improvement, coding agents, and model providers are rejected for every package and restoration data class. The processing inventory now records the encrypted package, import attempt, and transient restore operation alongside provenance, binding, and minimal security records. Source-dependency and database scans prove there is no portability analytics, telemetry, cache, agent, model-provider, content-index, or analytics-table route; any future analytics proposal remains prohibited until it can meet an aggregate and genuinely anonymous boundary without stable or pseudonymous identifiers.

- [x] Task 7 - Complete the backup privacy and security review.
  - Size: Standard
  - Purpose: Confirm the complete portability data flow follows the approved privacy and security contract before publishing the capability.
  - Owned surfaces: Active processing inventory including `HostedLocalRepositoryBinding`, approved service and security purposes and lawful bases, authorized-user, explicitly bound worker, and operations access controls, processor and transfer configuration, audit minimization, consolidated privacy and security review, release-gate classification, and `capability:project-portability` readiness write-back.
  - Owns: AC-12
  - Depends on: Task 6, Task 15, Task 22, Task 24
  - Proof: Focused data-inventory, purpose and basis, necessity, access, processor, transfer, audit-minimization, cross-task lifecycle, required privacy, and security reviews pass before capability readiness is recorded.
  - Delivered: Added the consolidated portability privacy review across every active processing record, lawful basis, minimized field set, approved access boundary, immediate through 35-day lifecycle controls, prohibited agent and model-provider access, and deployment-evidence classification. Removed unreachable restore and reconnection branches identified by static analysis and documented the existing Ecto transaction opaque-type boundary narrowly. Local implementation and verification are complete; incomplete deployment facts remain only in the public release gate.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Every active acceptance criterion and data entity has one clear primary task owner.
- [x] Golden decrypted-payload, deterministic snapshot, explicit field-map, excluded-category, and supported-version compatibility fixtures prove the exact project, canonical repository, and current-specifications allowlist.
- [x] Stable project identity is preserved, and existing same-identity restoration is rejected without overwrite, merge, update, rename, or partial mutation.
- [x] Duplicate discovery checks only the selected destination and catalogs already accessible in the restore session; no signed-out or unavailable-device query, global registry, or background identity-presence signal occurs, and later-visible same-ID records remain separate and unchanged.
- [x] Passphrase-based package control and normal destination-authorization checks pass for every signed-in and accountless restore path.
- [x] Every backup is encrypted with its confirmed user-set recovery passphrase; every restore requires the correct passphrase; passphrase-loss confirmation, missing and incorrect input, transient key disposal, and unrecoverable-support-boundary tests pass.
- [x] Secret-exclusion, passphrase and derived-key non-persistence, allowlist, authenticated encryption, integrity, tampering, and forbidden-field tests pass.
- [x] Malformed, unsafe, unsupported, oversized, unknown-field, path, archive, and resource-limit tests pass.
- [x] Name-only conflicts permit an explicitly entered valid unique display name or cancellation, canonical-repository conflicts always block, and storage, atomicity, idempotency, concurrency, and rollback tests pass.
- [x] Repository reconnection requires normal authorization and leaves repository content and configuration unchanged; device projects create no hosted binding, while hosted local-repository projects require separate personal-workspace and device-workspace authority and persist only the approved revocable binding after exact worker validation.
- [x] Local backup accepts only the portable versioned canonical identifier, blocks legacy workspace-scoped fingerprints before encryption, and provides the source-side upgrade handoff without mutation.
- [x] The approved GDPR contract passes: no completed service package; immediate passphrase, key, decrypted-content, and terminal temporary-data disposal; stranded encrypted data and attempt cleanup within 24 hours; minimal project-bound provenance; 30-day security logs; 35-day encrypted backups; verified rights and processor propagation; and no analytics, advertising, model training, identity tracking, or unrelated reuse.
- [x] Required LiveView and desktop and mobile browser scenarios pass without exposing cross-user exchange or create-copy behavior.
- [x] Approved canonical build, formatting, lint, static, security, production, and failure-log checks pass.

## Blocked Decisions

- None. The explicit hosted local-worker binding and both required worker capabilities are approved and available; Task 26 is executable.

## Progress Log

See [progress.md](progress.md).
