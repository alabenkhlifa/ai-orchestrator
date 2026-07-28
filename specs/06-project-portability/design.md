# Project Backup And Restoration Design

## Context

Users need a controlled way to back up one project and restore the same stable project after loss or in a replacement environment. A backup package crosses storage and trust boundaries and can carry sensitive project content, malformed data, unsafe paths, leaked credentials, or an identity that already exists. Cross-user exchange and creating a new copy have different authority, identity, provenance, and privacy requirements and are not part of this agreement.

The project-storage authority and shared project-specification store are external prerequisites. This slice consumes their current-snapshot and destination-transaction contracts; it does not own project storage selection, specification identity, revision persistence, or authoritative document storage.

## Proposed Approach

Define an allowlisted, versioned backup manifest with integrity metadata, one stable project identity, and three decrypted content categories: stable project metadata, canonical repository identity, and current specifications. Read current specifications through the shared specification-store snapshot instead of repository or filesystem discovery. Export the three categories from one consistent authorized snapshot after secret filtering, require the user to set and confirm a recovery passphrase, and encrypt the package without persisting the passphrase or derived key. Restore through isolated temporary processing after transient passphrase-based decryption, validate structural, safety, compatibility, and destination-authorization rules, check identity conflicts only in the selected destination and catalogs already accessible to the restore session, reject an existing stable identity or canonical repository conflict, allow an explicit valid display-name replacement for a name-only conflict, then create the same project and its specifications atomically through the project-storage and specification-store destination seams. Re-establish repository authorization separately. A device-authoritative local project reconnects inside its device workspace. A hosted local-repository project reconnects only when the current action separately authorizes the owning personal workspace and one available device workspace, the selected active worker proves the project-held portable identifier, and the control plane persists one minimal revocable hosted-to-worker binding.

## Components Affected

- Project backup and consistent-snapshot service.
- Shared project-storage authority and project-specification snapshot and restore capability consumers.
- Package manifest, schema versions, integrity, and compatibility registry.
- Secret and sensitive-field filtering, passphrase handling, key derivation, and package encryption.
- Upload or local-file intake and isolated temporary processing.
- Restore authority, validation, conflict, and result interfaces.
- Project identity, naming, storage, and repository reconnection.
- Hosted local-repository worker binding, authorization, status, and lifecycle.
- Cleanup, audit, privacy, and data-subject-rights workflows.

## Data and Access Boundaries

- `Project`: the stable project identity and approved project data restored only when that identity does not already exist in the selected destination or current accessible catalog.
- `ProjectPackage`: the transient versioned encrypted backup representation, non-secret encryption parameters, manifest, stable project identity, and approved content; the service retains no completed copy after delivery.
- `PackageSection`: one of the three initial decrypted content categories—project identity, canonical repository identity, or current specifications—with its version and integrity metadata.
- `ImportAttempt`: isolated transient intake, validation, authority, conflict, confirmation, and cleanup state for one restore request, deleted immediately after a terminal outcome and no later than 24 hours after creation if stranded.
- `PackageProvenance`: only the package schema version and restoration timestamp associated with the restored project.
- `HostedLocalRepositoryBinding`: a hosted control-plane record linking one restored hosted local-repository project to one explicitly selected paired worker after exact validation. It contains only project ID, worker ID, and last successful validation time; project ownership, device-workspace authority, and canonical repository identity remain authoritative on their existing records.

Required boundaries:

- Backup reads only authorized data for one project from one consistent snapshot.
- Current specification identity, title, and documents come only from `capability:project-specification-store`; this slice creates no second specification schema, revision store, or authoritative document copy.
- Secret filtering occurs before serialization and is verified after package creation.
- The user sets and confirms one recovery passphrase for each package after acknowledging that it cannot be retrieved, reset, bypassed, or recovered.
- The package payload is encrypted before delivery. The recovery passphrase and derived encryption key exist only transiently for encryption or decryption and do not persist in the package, service, device database, logs, diagnostics, analytics, exports, or backups.
- The package may carry only the non-secret encryption parameters required to derive a transient key and verify authenticated decryption.
- Package-envelope metadata is limited to what schema versioning, encryption, integrity, size, and compatibility require.
- The project section contains only stable project ID and current display name. Destination workspace, selected storage mode, lifecycle state, source connection record IDs, and other environment-specific state are established during restoration rather than copied.
- The repository section contains only provider kind and the source onboarding contract's canonical stable identifier. For GitHub this is the provider's numeric repository ID; for a local source it is the versioned portable identifier from `capability:portable-local-repository-identity`, including its non-secret validation salt inside the opaque identifier. It contains no local path, remote or clone URL, owner or display name, visibility, installation, connection status, validation time, credential, workspace identity, or other mutable access metadata.
- The specifications section contains each current specification's stable logical identifier, current display title, and current `requirements.md`, `design.md`, and `tasks.md` content without a repository or filesystem path.
- Separate project and specification revisions, runs and run output, generated artifacts, comments, attachments, audit and security logs, analytics, and repository source do not cross the package boundary.
- A progress log already present inside current `tasks.md` content remains part of that current document; no separate historical record or prior document revision is added.
- The package preserves one stable project identity and cannot request a new copy identity.
- Every restore path requires successful passphrase-based decryption plus normal authorization for the selected device or hosted storage boundary before package content can create project records.
- Missing or incorrect passphrase input fails without exposing decrypted package content or leaving persistent project data.
- Imported files remain isolated until every validation, authority, duplicate, and conflict check passes.
- Same-identity discovery reads only the selected destination and catalogs already authorized and available in the current restore session.
- Discovery creates no global project registry or cross-boundary collision link and does not contact signed-out identities, unavailable devices, or background identity-presence services.
- Validation never executes package content.
- Temporary data has an approved short lifecycle and cannot appear in ordinary project access.
- An existing same-project identity causes rejection without update, merge, overwrite, or rename.
- A later-visible same-ID record does not retroactively mutate either authoritative record. Combined-catalog composition keeps them separate under the storage-selection contract and persists no cross-boundary ownership or collision link.
- A case-insensitive display-name conflict may change only the restored project's mutable display label after explicit user input and normal name validation.
- A canonical repository identity already linked to another destination project blocks restoration; the conflict flow cannot relink, unlink, substitute, or weaken repository uniqueness.
- Project creation, restored current specifications, and an explicitly resolved display-name conflict commit atomically with the packaged stable project, specification, and repository identities through destination-local provider transactions.
- Repository credentials never cross the package boundary; reconnection uses normal provider or worker flows.
- A legacy workspace-scoped local fingerprint is not packaged as portable identity. Backup stops before generation and hands the user to explicit source-side `Locate repository` validation and atomic upgrade.
- Local reconnection supplies the packaged portable identifier to the authorized target worker. The worker parses its validation salt, recomputes the root-commit digest locally, and connects only on an exact constant-time match; the source workspace identity is unnecessary.
- A device-authoritative project records reconnection only inside its owning device store. It creates no hosted project-to-worker binding.
- A hosted local-repository project remains authoritative in its `PersonalWorkspace`. Reconnection additionally requires a currently available `DeviceWorkspace`, an active paired worker authorized only for that device workspace, and explicit user selection; neither package decryption nor either workspace authority implies the other.
- `HostedLocalRepositoryBinding` has one unique row per hosted project and references the selected `LocalWorker`. It does not duplicate personal or device workspace IDs, the canonical repository identifier, a repository path, credential, device label, connection payload, or compatibility metadata.
- The hosted binding is inserted or replaced only after the selected worker proves the exact portable identifier held by the project. The same successful retry is idempotent; a failed replacement preserves the old binding. Explicit disconnect and project erasure delete the row, worker revocation deletes bindings to that worker, and service termination removes it through the hosted lifecycle.
- Worker reachability is derived from the current `LocalWorker` state and heartbeat. Temporary unavailability does not mutate or delete the binding; revocation makes the binding unusable and removes it. A replacement worker must pass the same explicit authorization and exact validation before an atomic worker-reference replacement.
- Independent local onboarding generates a fresh identifier. The same identifier becomes cross-workspace linkable only where the user deliberately transfers it inside an encrypted same-project package; no global local-repository equality registry or query is added.
- Reconnection does not modify repository content or configuration.
- Package, temporary, log, backup, provenance, and restored project data remain personal or confidential project data unless proven otherwise and follow the approved lifecycle.
- The service retains no completed package after successful delivery. A downloaded package remains under the user's control outside the service lifecycle.
- Raw passphrases, derived keys, and decrypted temporary content are discarded immediately after their active operation and never enter service persistence, backups, logs, diagnostics, analytics, caches, or indexes.
- Terminal encrypted generation files, restore uploads, parsing data, and attempts are deleted immediately; a cleanup worker removes stranded encrypted temporary data and attempts within 24 hours of creation.
- Persistent provenance contains no package hash, filename, source account, workspace, device, exporter identity, network address, or source storage mode and is deleted with the restored project.
- Hosted local-worker bindings are linkable personal data processed only to route the explicit hosted project's local repository operations. Access is limited to the owning personal workspace, the bound worker for authorized operations, and approved personnel for necessary security, support, lifecycle, or verified-rights work.
- Hosted local-worker bindings are deleted on explicit disconnect, worker revocation, replacement of the obsolete worker reference, project erasure, or service termination. Derived copies and processors follow the same deletion action, and encrypted backup copies follow the 35-day expiry.
- Operational-security logs contain only event type, time, outcome, and non-secret correlation ID, contain no package or project content or repository identifier, and expire after 30 days.
- Encrypted rolling backups expire within 35 days. Verified deletion and rights handling covers derived records, processors, and backup expiry.
- Coding agents and model providers receive no package or temporary-data access, and the slice emits no analytics or other secondary-use data.

## Interfaces

- Backup interface: select one authorized project, show the three included content categories and the excluded history, run, artifact, comment, attachment, log, and source categories, require and confirm a recovery passphrase and the unrecoverable-loss warning, snapshot the project, filter secrets, encrypt and serialize it, and return version and integrity information.
- Specification-store consumer interface: request one authorized consistent current-project snapshot for export and contribute validated stable specification identities and current document sets to the destination-local project-creation transaction during restoration.
- Package schema interface: define the project, repository, and current-specifications sections, their exact fields and document payloads, stable identity, non-secret encryption parameters, versions, compatibility, limits, and unknown-field behavior.
- Restore intake interface: isolate the package, require the recovery passphrase, limit resources, establish the selected storage destination, and begin decryption and validation without persistent project mutation.
- Restore-authority interface: treat successful package decryption as control of backup contents and separately verify the normal device or hosted-identity authorization required by the selected destination.
- Validation interface: check integrity, format, versions, size, paths, attachments, content types, stable identity, and forbidden secret categories.
- Conflict interface: derive the duplicate-check scope from the selected destination and catalogs already accessible in the current restore session, reject same-identity and canonical-repository conflicts in that scope, allow a new user-entered display name only for a name-only conflict, apply the destination's normal name validation and case-insensitive uniqueness rules, and permit cancellation without mutation.
- Restore commit interface: reject an existing stable identity or create the project and shared-store specification data atomically with the packaged identities in the chosen mode.
- Repository reconnection interface: require normal authorization and validation independently from package contents; route device-authoritative local projects only through their device store and hosted local-repository projects only through the separately authorized personal-workspace and device-workspace binding flow.
- Hosted local-worker binding interface: authorize the hosted project owner and selected device workspace independently, select one active worker already paired to that device workspace, pass only the project ID and project-held portable identifier to the worker validation request, insert or atomically replace the minimum binding after exact success, support explicit disconnect, and derive unavailable or revoked results without accepting package credentials, paths, or source connection data.
- Local identity readiness interface: accept only the versioned portable identifier for package generation and validation, return an actionable source-side upgrade requirement for a legacy identifier, and consume the Slice 02 capability without owning worker identity generation or migration.
- Cleanup and rights interface: discard passphrases, keys, and decrypted content immediately; remove terminal encrypted temporary data and attempts immediately and stranded copies within 24 hours; retain no completed service package; delete hosted local-worker bindings on disconnect, worker revocation, project erasure, or service termination; expire logs within 30 days and encrypted backups within 35 days; delete provenance with the project; and propagate verified rights and deletion to derived records and processors.

## Decisions and Tradeoffs

### Focused Same-Project Backup And Restoration

- Choice: Limit this specification to backing up and restoring the same project. Defer cross-user exchange and create-copy behavior to a child specification.
- Reason: Same-project recovery preserves identity, while sharing or copying creates a new ownership and trust relationship that needs separate authority, provenance, permissions, privacy, and conflict decisions.
- Consequence: This slice cannot transfer a project to another user, allocate a new project identity, or present package exchange as collaboration. A future child specification must preserve this slice's no-overwrite boundary.

### Preserve Stable Identity And Reject Existing Projects

- Choice: Carry the project's stable identity in the package, restore with that identity, and reject restoration when that identity already exists in the selected destination or current accessible catalog.
- Reason: A backup represents recovery of one project, not creation of a similar project or an update channel.
- Consequence: Restore cannot silently rename, merge, overwrite, update, or allocate a new identity. Display-name recovery and canonical-repository conflicts follow the separate approved conflict decision below, and duplicate discovery follows the visibility-bounded decision below.

### Visibility-Bounded Duplicate Discovery

- Choice: Check the selected destination and only project catalogs already accessible in the current restore session. Do not contact signed-out accounts or unavailable devices and do not create a global stable-project registry or background identity-presence signal.
- Reason: Device-authoritative project identity must not be uploaded or tracked merely to improve duplicate discovery, and an offline or unauthorized boundary cannot provide reliable absence evidence.
- Consequence: Restoration may succeed while an unavailable boundary holds the same project ID. If that record later becomes accessible, both authoritative records remain unchanged and the combined catalog presents them separately as an identity conflict under `specs/05-project-storage-lifecycle/`. Collision resolution is deferred to a future specification.

### Resolve Only Display-Name Conflicts

- Choice: Let the user enter a different valid display name when that is the only conflict. Always block when the packaged canonical repository identity is already linked to another destination project.
- Reason: The project name is an editable human-facing label, while the stable project ID and canonical repository identity define the restored project and its uniqueness boundary.
- Consequence: Name recovery uses the destination's normal case-insensitive validation and never chooses a name automatically. It preserves the packaged stable project and repository identities. A repository conflict cannot be resolved by renaming, relinking, unlinking, or selecting a different repository.

### Separate Backup From Direct Migration

- Choice: Treat backup and restoration as explicit package operations and storage-mode changes as lifecycle operations on the same live project.
- Reason: A package can be retained offline and restored after loss, while direct migration requires authority handoff and lifecycle coordination between active storage boundaries.
- Consequence: This specification neither deactivates a source project nor moves an active project's authoritative storage mode.

### Allowlisted Versioned Package

- Choice: Apart from minimum envelope metadata, export only stable project ID and display name, provider and canonical repository identity, and each current specification's logical identity, title, and current `requirements.md`, `design.md`, and `tasks.md` content under a declared schema version.
- Reason: This is the minimum current state needed to restore the same SDD project while keeping environment-specific ownership, connection, storage, execution, history, and source data outside the package.
- Consequence: History, runs, generated artifacts, comments, attachments, audit or security logs, analytics, repository source, mutable repository metadata, storage mode, lifecycle state, and workspace identity are excluded. Adding any of them requires a later approved package-version or child-specification decision.

### Shared Specification Store Is A Required Provider

- Choice: Consume `capability:project-specification-store` for the current snapshot and destination-local restoration transaction.
- Reason: Specification identity and persistence are shared domain foundations needed by both portability and guided delivery; backup must not become their accidental owner.
- Consequence: Slice 06 remains blocked until the provider task is complete. Package behavior stays owned here, while specification schemas, revisions, storage adapters, authorization seams, and authoritative copies stay owned by Slice 09.

### Portable Local Repository Identity Is A Required Provider

- Choice: Consume `capability:portable-local-repository-identity` from Slice 02. Package only its versioned identifier, block local backup while the source project still holds a legacy workspace-scoped fingerprint, and reconnect by supplying the packaged identifier to normal authorized worker validation.
- Reason: Slice 02 owns local worker identity generation, duplicate detection, and source-side migration. Reusing that contract lets a target worker prove the same repository without adding source workspace identity, path, credential, or raw Git object IDs to the package.
- Consequence: Independent onboarding remains unlinkable because it generates a fresh salt, while an encrypted backup deliberately carries the existing same-project identifier. Slice 06 owns the backup-readiness handoff, package validation, and reconnection result. The provider capability is ready from completed Slice 02 Task 9.

### Explicit Hosted Local-Worker Binding

- Choice: Represent a restored hosted local-repository connection with a separate provider-neutral `HostedLocalRepositoryBinding` in the hosted control-plane database. The row contains only `project_id`, `worker_id`, and `last_validated_at`, is unique by project, and derives the personal workspace, device workspace, and canonical repository identity from the existing `Project` and `LocalWorker` records. Creation requires explicit current authority over the project and device workspace plus exact portable-identifier validation by an active worker. Disconnect and worker revocation delete the row; project erasure cascades; replacement updates the worker only after the replacement proves the same project-held identity; temporary unavailability is derived and non-mutating.
- Reason: The hosted project needs a durable routing target after reconnection, but reusing the GitHub-specific numeric `RepositoryConnection`, copying workspace or repository identity fields, or treating package control as worker authority would weaken type, authorization, and privacy boundaries.
- Consequence: The user-approved binding deliberately creates a minimal personal-workspace-to-device-worker link for the connected project's service purpose. It contains no path, credential, device label, compatibility metadata, source workspace identity, or duplicate repository identifier; remains separately revocable; participates in verified rights, project erasure, service termination, processor deletion, and backup expiry; and never turns the device workspace or repository source into hosted authoritative project data.

### No Accepted Secrets

- Choice: Exclude all authentication, repository, session, worker, agent-provider, and encryption secrets.
- Reason: Backup files leave the normal credential boundary and may be copied, lost, or retained.
- Consequence: Restored projects require explicit repository and provider reconnection.

### User-Controlled Passphrase Encryption

- Choice: Encrypt every backup with a user-set recovery passphrase and require that passphrase for every restoration. Persist neither the passphrase nor a derived encryption key in the package, service, device persistence, logs, diagnostics, analytics, exports, or backups.
- Reason: Signed-in and accountless backups can leave the normal application boundary; file possession alone does not provide sufficient confidentiality or restore control.
- Consequence: The user must confirm that SDD Orchestrator cannot retrieve, reset, bypass, or recover a lost passphrase. Successful decryption proves control of the package contents but does not replace destination authorization. The authenticated-encryption, key-derivation, transient-processing, and resource-limit mechanisms remain engineering decisions.

### Validate Before Mutation

- Choice: Isolate and fully validate a package, authority, identity, and conflicts before any persistent project change.
- Reason: Malformed, malicious, unauthorized, or conflicting packages must not create partial state or execute content.
- Consequence: Restoration needs resource limits, temporary storage, cleanup, and an atomic commit.

### Approved Backup Privacy Contract

- Choice: Process core package, restoration, and explicit hosted local-worker binding data only to provide the requested service, process minimum security records under the documented legitimate-interest assessment, and prohibit analytics, advertising, model training, identity tracking, and unrelated reuse.
- Service-held lifecycle: Retain no completed backup copy. Discard raw passphrases, derived keys, and decrypted temporary content immediately after use. Delete terminal encrypted temporary files and attempts immediately and stranded copies within 24 hours. Retain only schema version and restoration time as project-bound provenance. Retain a hosted local-worker binding only while the project remains explicitly connected to that worker, removing it on disconnect, revocation, replacement, project erasure, or service termination. Delete security logs after 30 days and expire encrypted rolling backups within 35 days.
- Access and rights: Limit active data to the authorized user and destination boundary, the explicitly bound worker for authorized local operations, plus approved personnel for necessary security, support, lifecycle, and verified rights work. Exclude coding agents and model providers. Apply verified access, correction, erasure, restriction, objection, and portability workflows to applicable service-held records, hosted local-worker bindings, derived copies, processors, and backup expiry.
- Consequence: A user-downloaded package remains under the user's control and cannot be deleted by the service. Public deployment still requires actual controller, processor, region, transfer, notice, incident, retention-enforcement, and required DPIA or legal evidence, but those facts do not block implementation or local verification of this approved contract.

### Package Container And Deterministic Payload

- Choice: Package one file as a non-secret cleartext envelope header followed by the authenticated-encryption ciphertext of a compressed, canonically serialized JSON payload. Serialize the project, repository, and current-specifications sections in fixed order with sorted keys via Jason, and compress the plaintext payload with `:zlib` (DEFLATE) before encryption, guarded by a decompressed-size ceiling and a maximum expansion ratio enforced at restore.
- Reason: A structured JSON document rather than a filesystem archive makes the payload deterministic for golden fixtures and removes tar and zip path-traversal, symlink, and archive-member classes. Compressing before encryption keeps ciphertext opaque while bounding size.
- Consequence: There is no archive-extraction step; intake is one package file. Decompression is bounded to defeat decompression bombs, and deterministic ordering enables byte-stable golden decrypted-payload fixtures. The envelope header stays cleartext but is authenticated by the encryption decision below.

### Memory-Hard Passphrase Derivation (Argon2id)

- Choice: Derive the 32-byte package key from the recovery passphrase with Argon2id, using a per-package 16-byte random salt and documented default cost parameters (time cost 3, memory 64 MiB, parallelism 1) that are tunable through application configuration. Store only the non-secret salt and cost parameters in the cleartext envelope. This adds the `argon2_elixir` dependency, introduced by Task 3.
- Reason: The approved contract requires a memory-hard derivation resistant to offline guessing against a copied package; Argon2id is the current standard, and the codebase has no key-derivation dependency yet. The cost parameters must travel with the package so any restore can reproduce the key.
- Consequence: Restore reproduces the key from the passphrase plus the envelope salt and parameters, and neither the passphrase nor the derived key is stored. `mix deps.audit` and `mix sobelow` continue to gate the added dependency, and parameter tuning is configuration rather than a design blocker.

### Authenticated Package Encryption (AES-256-GCM)

- Choice: Encrypt the compressed payload with AES-256-GCM via Erlang `:crypto`, using a per-package 12-byte random nonce and a 128-bit authentication tag, and bind the cleartext envelope header (format version, payload schema version, key-derivation identifier, salt, cost parameters, and nonce) as additional authenticated data.
- Reason: AES-256-GCM matches the existing `SddOrchestrator.Vault` cipher, keeping one authenticated-encryption primitive across the codebase. Binding the envelope as additional authenticated data detects tampering or downgrade of the version and derivation parameters, and the GCM tag provides integrity without a separate signature because backups are user-held rather than publisher-signed.
- Consequence: Any corruption, truncation, or tampering of the ciphertext or envelope fails authenticated decryption before parsing, satisfying integrity and compatibility rejection. No separate signing key or HMAC is introduced.

### Transient Passphrase And Key Handling

- Choice: Keep the passphrase and derived key only as local values for the single encrypt or decrypt operation, never placing them in persisted structs, logs, diagnostics, analytics, or return values, following the established magic-link transient-secret pattern, and use `Plug.Crypto` constant-time comparison for any equality check. A missing or incorrect passphrase, or a failed authentication tag, returns an opaque error that exposes no plaintext.
- Reason: Confidentiality depends on never persisting the secret material, and constant-time handling avoids side channels.
- Consequence: Restore reports only success or an opaque failure, and decrypted content and key material never enter persistence, logs, or telemetry.

### Isolated Intake, Limits, And Compatibility

- Choice: Hold the encrypted upload and validation state in `ImportAttempt`, encrypted at rest through the existing Cloak `Encrypted.Binary` type for its brief lifetime, and validate before any persistent project change with configuration-tunable limits: maximum encrypted package size, maximum decompressed payload size, maximum expansion ratio, maximum specification count and document size, and maximum field lengths, parsed by a strict JSON reader that rejects duplicate keys and non-finite numbers. Version the format and the payload schema separately: reject an unsupported major version, and within a supported major ignore unknown additive fields while recording a log line, without changing restored meaning.
- Reason: The package crosses a trust boundary and must not create partial state, execute content, or be exhausted by malformed or oversized input, and explicit version rules make compatibility observable and satisfy the reject-or-ignore criterion.
- Consequence: Validation is pure data parsing with no code execution, data absent from the allowlist is excluded rather than serialized so forward compatibility holds, and unknown additive fields never silently alter the restored project.

### Atomic Restore And Minimal Provenance

- Choice: Run conflict preflight and creation inside one Ecto `Multi` transaction — stable-identity existence check across the selected destination and session-accessible catalogs, canonical-repository uniqueness, and case-insensitive display-name uniqueness — then create the `Project` and a `PackageProvenance` holding only the package schema version and restoration timestamp, backed by database unique constraints on the stable project identity and canonical repository identity. Reuse the Slice 05 storage-selection prerequisites for the destination, and leave repository reconnection to the normal provider or worker flow.
- Reason: A single transaction with database constraints guarantees atomicity and enforces the same-identity and repository hard blocks even under concurrency, and minimal provenance avoids unnecessary identity tracking.
- Consequence: Any failure rolls back with no partial project, provenance, or attempt record; provenance carries no package hash, filename, source account, workspace, device, exporter identity, network address, or source storage mode; and repository content and configuration are never modified.

### Backup Lifecycle And Verification Wiring

- Choice: Register the slice's package, temporary, hosted local-worker binding, provenance, log, and restored-record categories in `Privacy.ProcessingInventory` and `DataProcessingRecord`, add the immediate-terminal and 24-hour stranded `ImportAttempt` and encrypted-temporary cleanup as new rules in `Privacy.Retention.prune_all/1` under the existing supervised `RetentionPruner`, keep 30-day operational-security-log and 35-day encrypted-backup expiry as deployment-infrastructure enforcement recorded in `DeploymentPrivacyProfile`, and extend the `Privacy.Rights` workflows to cover `ImportAttempt`, `HostedLocalRepositoryBinding`, and `PackageProvenance`. Prove the slice with the established Slice 01 toolchain: `mix test` with `stream_data` property tests and committed golden decrypted-payload and encrypted-package fixtures, the `mix check` gate plus `mix dialyzer`, `mix deps.audit`, and `mix sobelow --config`, the `npm --prefix assets run test:e2e` desktop and mobile browser scenarios, and the `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` production proofs.
- Reason: The privacy lifecycle must reuse the existing idempotent, advisory-locked retention and inventory machinery rather than a parallel mechanism, and verification must use the canonical project checks already established.
- Consequence: The 30-day log and 35-day backup expiry stay deployment-infrastructure concerns in the release gate, consistent with the existing retention module, and no new scheduler or verification toolchain is introduced.

## Risks

- Secret filtering can miss a new field. Use an allowlisted schema, negative secret tests, and version review.
- A serializer can accidentally follow associations or copy environment-specific fields. Build each section from an explicit field map and prove excluded-field absence against golden decrypted payloads.
- Archives can contain path traversal, decompression bombs, unsafe links, or executable content. Isolate parsing, enforce limits, and never execute package contents.
- Compatibility rules can silently drop important data. Make version behavior explicit and user-visible before restoration.
- A weak passphrase can permit offline guessing against a copied package. Require approved passphrase guidance and a memory-hard derivation design without retaining the passphrase or derived key.
- A lost passphrase makes the backup permanently unrestorable. Require explicit confirmation and clear support boundaries before package creation.
- Successful decryption can be mistaken for destination authorization. Require the normal device or hosted-identity prerequisite independently.
- Duplicate identity or repository links can corrupt ownership. Preflight stable identity, name, and canonical repository constraints.
- Treating a legacy workspace-scoped fingerprint as portable would create an unprovable reconnection claim. Block package generation until exact source-side validation upgrades the identifier.
- A portable identifier can link the source and restored same-project records. Limit that link to the user-requested encrypted package and authorized project records, and prohibit analytics, global lookup, and unrelated reuse.
- A hosted local-worker binding can silently correlate an account with a device or outlive authorization. Create it only after explicit dual-boundary authorization and exact validation, minimize it to project and worker references plus validation time, and delete it on disconnect, revocation, replacement, project erasure, or service termination.
- Visibility-bounded discovery can miss a project on an unavailable boundary. Keep later-visible records separate, expose the collision without mutation, and require a future explicit resolution contract.
- An automatic or weakly validated conflict rename can hide a collision. Require explicit user input and the destination's normal name validation before the atomic commit.
- A restore flow can become an unapproved migration or copy mechanism. Preserve the packaged identity, reject existing identity, and do not deactivate a source or allocate a copy identity.
- Temporary package copies can outlive their purpose. Enforce short retention across storage, logs, backups, and processors.
- Package provenance can become unnecessary identity tracking. Minimize it and apply an approved data contract.
- A completed package or abandoned upload can remain in service storage after its purpose ends. Delete terminal data immediately, enforce the 24-hour stranded-data ceiling, and prove cleanup independently of the request process.
- Support or observability tooling can capture decrypted content or repository identifiers. Use fixed structured security fields, redact by default, and scan logs, diagnostics, caches, indexes, and backups.

## Open Questions

- None. The hosted local-worker binding, portable local repository identity, legacy source-side upgrade, container, key-derivation, authenticated-encryption, transient-handling, intake-limit, compatibility, atomic-restore, provenance, lifecycle, and verification mechanisms are resolved in Decisions and Tradeoffs above. Argon2id cost parameters and the concrete size, count, and length limits are configuration values with documented defaults, not open design questions.
