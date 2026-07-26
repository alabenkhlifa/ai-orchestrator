# Project Backup And Restoration Design

## Context

Users need a controlled way to back up one project and restore the same stable project after loss or in a replacement environment. A backup package crosses storage and trust boundaries and can carry sensitive project content, malformed data, unsafe paths, leaked credentials, or an identity that already exists. Cross-user exchange and creating a new copy have different authority, identity, provenance, and privacy requirements and are not part of this agreement.

## Proposed Approach

Define an allowlisted, versioned backup manifest with integrity metadata, one stable project identity, and three decrypted content categories: stable project metadata, canonical repository identity, and current specifications. Export those categories from one consistent authorized snapshot after secret filtering, require the user to set and confirm a recovery passphrase, and encrypt the package without persisting the passphrase or derived key. Restore through isolated temporary processing after transient passphrase-based decryption, validate structural, safety, compatibility, and destination-authorization rules, check identity conflicts only in the selected destination and catalogs already accessible to the restore session, reject an existing stable identity or canonical repository conflict, allow an explicit valid display-name replacement for a name-only conflict, then create the same project atomically in the selected storage mode. Re-establish repository authorization separately.

## Components Affected

- Project backup and consistent-snapshot service.
- Package manifest, schema versions, integrity, and compatibility registry.
- Secret and sensitive-field filtering, passphrase handling, key derivation, and package encryption.
- Upload or local-file intake and isolated temporary processing.
- Restore authority, validation, conflict, and result interfaces.
- Project identity, naming, storage, and repository reconnection.
- Cleanup, audit, privacy, and data-subject-rights workflows.

## Data and Access Boundaries

- `Project`: the stable project identity and approved project data restored only when that identity does not already exist in the selected destination or current accessible catalog.
- `ProjectPackage`: the transient versioned encrypted backup representation, non-secret encryption parameters, manifest, stable project identity, and approved content; the service retains no completed copy after delivery.
- `PackageSection`: one of the three initial decrypted content categories—project identity, canonical repository identity, or current specifications—with its version and integrity metadata.
- `ImportAttempt`: isolated transient intake, validation, authority, conflict, confirmation, and cleanup state for one restore request, deleted immediately after a terminal outcome and no later than 24 hours after creation if stranded.
- `PackageProvenance`: only the package schema version and restoration timestamp associated with the restored project.

Required boundaries:

- Backup reads only authorized data for one project from one consistent snapshot.
- Secret filtering occurs before serialization and is verified after package creation.
- The user sets and confirms one recovery passphrase for each package after acknowledging that it cannot be retrieved, reset, bypassed, or recovered.
- The package payload is encrypted before delivery. The recovery passphrase and derived encryption key exist only transiently for encryption or decryption and do not persist in the package, service, device database, logs, diagnostics, analytics, exports, or backups.
- The package may carry only the non-secret encryption parameters required to derive a transient key and verify authenticated decryption.
- Package-envelope metadata is limited to what schema versioning, encryption, integrity, size, and compatibility require.
- The project section contains only stable project ID and current display name. Destination workspace, selected storage mode, lifecycle state, source connection record IDs, and other environment-specific state are established during restoration rather than copied.
- The repository section contains only provider kind and the source onboarding contract's canonical stable identifier. For GitHub this is the provider's numeric repository ID; for a local source it is the approved canonical identifier. It contains no local path, remote or clone URL, owner or display name, visibility, installation, connection status, validation time, credential, or other mutable access metadata.
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
- Project creation and an explicitly resolved display-name conflict commit atomically with the packaged stable project and repository identities.
- Repository credentials never cross the package boundary; reconnection uses normal provider or worker flows.
- Reconnection does not modify repository content or configuration.
- Package, temporary, log, backup, provenance, and restored project data remain personal or confidential project data unless proven otherwise and follow the approved lifecycle.
- The service retains no completed package after successful delivery. A downloaded package remains under the user's control outside the service lifecycle.
- Raw passphrases, derived keys, and decrypted temporary content are discarded immediately after their active operation and never enter service persistence, backups, logs, diagnostics, analytics, caches, or indexes.
- Terminal encrypted generation files, restore uploads, parsing data, and attempts are deleted immediately; a cleanup worker removes stranded encrypted temporary data and attempts within 24 hours of creation.
- Persistent provenance contains no package hash, filename, source account, workspace, device, exporter identity, network address, or source storage mode and is deleted with the restored project.
- Operational-security logs contain only event type, time, outcome, and non-secret correlation ID, contain no package or project content or repository identifier, and expire after 30 days.
- Encrypted rolling backups expire within 35 days. Verified deletion and rights handling covers derived records, processors, and backup expiry.
- Coding agents and model providers receive no package or temporary-data access, and the slice emits no analytics or other secondary-use data.

## Interfaces

- Backup interface: select one authorized project, show the three included content categories and the excluded history, run, artifact, comment, attachment, log, and source categories, require and confirm a recovery passphrase and the unrecoverable-loss warning, snapshot the project, filter secrets, encrypt and serialize it, and return version and integrity information.
- Package schema interface: define the project, repository, and current-specifications sections, their exact fields and document payloads, stable identity, non-secret encryption parameters, versions, compatibility, limits, and unknown-field behavior.
- Restore intake interface: isolate the package, require the recovery passphrase, limit resources, establish the selected storage destination, and begin decryption and validation without persistent project mutation.
- Restore-authority interface: treat successful package decryption as control of backup contents and separately verify the normal device or hosted-identity authorization required by the selected destination.
- Validation interface: check integrity, format, versions, size, paths, attachments, content types, stable identity, and forbidden secret categories.
- Conflict interface: derive the duplicate-check scope from the selected destination and catalogs already accessible in the current restore session, reject same-identity and canonical-repository conflicts in that scope, allow a new user-entered display name only for a name-only conflict, apply the destination's normal name validation and case-insensitive uniqueness rules, and permit cancellation without mutation.
- Restore commit interface: reject an existing stable identity or create the project and related data atomically with the packaged identity in the chosen mode.
- Repository reconnection interface: require normal authorization and validation independently from package contents.
- Cleanup and rights interface: discard passphrases, keys, and decrypted content immediately; remove terminal encrypted temporary data and attempts immediately and stranded copies within 24 hours; retain no completed service package; expire logs within 30 days and encrypted backups within 35 days; delete provenance with the project; and propagate verified rights and deletion to derived records and processors.

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

- Choice: Process core package and restoration data only to provide the requested service, process minimum security records under the documented legitimate-interest assessment, and prohibit analytics, advertising, model training, identity tracking, and unrelated reuse.
- Service-held lifecycle: Retain no completed backup copy. Discard raw passphrases, derived keys, and decrypted temporary content immediately after use. Delete terminal encrypted temporary files and attempts immediately and stranded copies within 24 hours. Retain only schema version and restoration time as project-bound provenance. Delete security logs after 30 days and expire encrypted rolling backups within 35 days.
- Access and rights: Limit active data to the authorized user and destination boundary plus approved personnel for necessary security, support, lifecycle, and verified rights work. Exclude coding agents and model providers. Apply verified access, correction, erasure, restriction, objection, and portability workflows to applicable service-held records, derived copies, processors, and backup expiry.
- Consequence: A user-downloaded package remains under the user's control and cannot be deleted by the service. Public deployment still requires actual controller, processor, region, transfer, notice, incident, retention-enforcement, and required DPIA or legal evidence, but those facts do not block implementation or local verification of this approved contract.

## Risks

- Secret filtering can miss a new field. Use an allowlisted schema, negative secret tests, and version review.
- A serializer can accidentally follow associations or copy environment-specific fields. Build each section from an explicit field map and prove excluded-field absence against golden decrypted payloads.
- Archives can contain path traversal, decompression bombs, unsafe links, or executable content. Isolate parsing, enforce limits, and never execute package contents.
- Compatibility rules can silently drop important data. Make version behavior explicit and user-visible before restoration.
- A weak passphrase can permit offline guessing against a copied package. Require approved passphrase guidance and a memory-hard derivation design without retaining the passphrase or derived key.
- A lost passphrase makes the backup permanently unrestorable. Require explicit confirmation and clear support boundaries before package creation.
- Successful decryption can be mistaken for destination authorization. Require the normal device or hosted-identity prerequisite independently.
- Duplicate identity or repository links can corrupt ownership. Preflight stable identity, name, and canonical repository constraints.
- Visibility-bounded discovery can miss a project on an unavailable boundary. Keep later-visible records separate, expose the collision without mutation, and require a future explicit resolution contract.
- An automatic or weakly validated conflict rename can hide a collision. Require explicit user input and the destination's normal name validation before the atomic commit.
- A restore flow can become an unapproved migration or copy mechanism. Preserve the packaged identity, reject existing identity, and do not deactivate a source or allocate a copy identity.
- Temporary package copies can outlive their purpose. Enforce short retention across storage, logs, backups, and processors.
- Package provenance can become unnecessary identity tracking. Minimize it and apply an approved data contract.
- A completed package or abandoned upload can remain in service storage after its purpose ends. Delete terminal data immediately, enforce the 24-hour stranded-data ceiling, and prove cleanup independently of the request process.
- Support or observability tooling can capture decrypted content or repository identifiers. Use fixed structured security fields, redact by default, and scan logs, diagnostics, caches, indexes, and backups.

## Open Questions

- Which authenticated-encryption, memory-hard passphrase-derivation, transient-processing, signing, integrity, and resource-limit mechanisms satisfy the approved recovery contract?
- Which manifest format, compression, compatibility, and version-migration rules apply?
- Which resource, file-type, attachment, path, and extraction limits are required?
- Which golden fixtures, property tests, compatibility suites, security tests, and browser scenarios prove the backup contract?
