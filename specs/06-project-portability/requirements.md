# Project Backup And Restoration

## Status

Approved

## Outcome

A project owner can export a passphrase-encrypted, versioned backup package and restore that same project with its stable identity into an available storage mode, without exposing accepted secrets, overwriting an existing project, weakening repository uniqueness, or modifying repository content.

## Users

- Project owners backing up a project or restoring it after loss or in a replacement environment.
- Support and operations personnel diagnosing compatible backup or restore failures without accessing project secrets.

## Primary Workflow

1. The user selects one authorized project and requests a backup.
2. The product shows that the backup includes the stable project identity and display name, the non-secret canonical repository identity, and every current specification's `requirements.md`, `design.md`, and `tasks.md` content; it also shows the excluded categories.
3. The user sets and confirms a recovery passphrase after being told that SDD Orchestrator cannot retrieve, reset, or bypass it.
4. The product creates a passphrase-encrypted, versioned, integrity-protected package containing the project's stable identity without storing the passphrase.
5. The user selects a package for restoration, enters its recovery passphrase, and chooses an available project-data storage mode.
6. The product decrypts the package transiently and validates format, version, integrity, size, content safety, compatibility, and destination authorization before mutation.
7. The product checks the stable project identity, name, repository, and selected storage boundary for conflicts using only the selected destination and catalogs already accessible in the current restore session.
8. If the same stable project identity already exists in that checked scope, restoration is rejected without changing either project; the product does not contact signed-out accounts or unavailable devices to attempt a global check.
9. If only the display name conflicts, the user may enter a different valid, available display name or cancel; the product never renames automatically.
10. If the canonical repository identity is already linked to a different project in the destination workspace, restoration is blocked without offering a different repository or changing either connection.
11. Otherwise, the product restores the project atomically with the same stable identity and the packaged or explicitly chosen display name, without modifying a repository.
12. Any required repository reconnection remains an explicit action under the normal provider or worker authorization flow.

## In Scope

- Explicit backup of one authorized project through a documented versioned package.
- An initial decrypted-payload allowlist containing only stable project identity and display name, non-secret canonical repository identity, and current specification identity and `requirements.md`, `design.md`, and `tasks.md` content.
- Consumption of the shared project-specification current-snapshot and destination-restore interfaces without defining a second specification identity or document store.
- User-set recovery passphrase, package encryption, passphrase-loss warning, and required passphrase entry during restoration.
- Restoration of that same project with its stable project identity preserved.
- Package integrity, compatibility, size, content, and path-safety validation.
- Secret and credential exclusion.
- Restoration into an available on-device or hosted storage mode under its normal prerequisites.
- Same-project duplicate rejection, explicit display-name conflict recovery, and blocking canonical-repository conflicts.
- Visibility-bounded duplicate checks without a global project-identity registry or queries to unavailable trust boundaries.
- Explicit repository reconnection without repository mutation.
- Approved GDPR purpose, access, retention, deletion, rights, processor, transfer, log, backup, provenance, and no-reuse boundaries.
- Actionable validation, compatibility, authorization, and conflict failures.

## Out of Scope

- Cross-user package sharing, exchange, or project transfer.
- Creating a copy with a new project identity.
- Merging into, updating, replacing, or recovering over an existing project.
- Direct storage-mode migration, defined in `specs/05-project-storage-lifecycle/`.
- Repository hosting migration or Git source transfer unless explicitly approved in this specification.
- Authentication, repository, session, worker, or agent credentials.
- Collaboration membership or permission transfer.
- Executing imported artifacts or repository code during validation.
- Project and specification revision history, agent runs, generated artifacts, comments, attachments, audit or security logs, and repository source.
- Global same-project discovery, background device or account lookup, and resolution of a same-ID collision discovered after restoration.

Cross-user exchange and create-copy behavior require a separate child specification. That specification must define recipient authority, new project identity, provenance, duplicate behavior, permissions, privacy, and trust-boundary controls without weakening this specification's same-project restore and no-overwrite rules.

## Business Rules

- Backup and restoration are explicit user actions and are not a substitute for direct storage-mode migration.
- A backup represents one existing project and carries that project's stable identity.
- Restoration preserves the packaged stable identity; it must not allocate a new identity or silently turn the backup into a copy.
- Same-identity preflight checks only the selected destination and project catalogs already accessible to the current restore session.
- Duplicate preflight must not sign the user into another account, contact a signed-out account, wake or query an unavailable device, upload a device project identifier, create a global identity registry, or emit background identity-presence telemetry.
- If the same stable project identity exists in the checked scope, restoration is rejected without overwrite, merge, update, or partial mutation.
- Absence from the checked scope is not a claim that the project does not exist on an unavailable device or behind a signed-out identity.
- If another authoritative record with the same stable project ID becomes accessible after restoration, neither record is changed, deleted, selected as authoritative, merged, uploaded, or synchronized. The combined catalog keeps the records separate and presents an identity conflict under `specs/05-project-storage-lifecycle/`.
- Resolution of a later-visible same-ID collision requires a future specification; this slice provides no automatic or manual resolution action.
- Every backup package is encrypted with a recovery passphrase set and confirmed by the user at backup time.
- The recovery passphrase is required for every restoration, including signed-in and accountless paths.
- A missing or incorrect passphrase must not expose decrypted package content or create persistent project data.
- The recovery passphrase and any derived encryption key must not be stored in the package, hosted service, device database, logs, analytics, diagnostics, exports, or backups. Only non-secret encryption parameters required to process the encrypted package may be included.
- SDD Orchestrator cannot retrieve, reset, bypass, or recover a lost passphrase. The user must see and confirm this consequence before backup creation.
- Successful package decryption proves control of the backup contents but does not replace the selected storage mode's normal device or hosted-identity authorization.
- Every package has a declared schema version and integrity protection.
- Apart from the minimum package-envelope metadata required for versioning, encryption, integrity, size, and compatibility, the initial decrypted payload contains only:
  - the stable project ID and current display name;
  - the repository provider kind and the source onboarding contract's canonical stable repository identifier, such as GitHub's numeric repository ID or the local source's approved canonical identifier; and
  - for each current specification, its stable logical identifier, current display title, and current `requirements.md`, `design.md`, and `tasks.md` content.
- Current specification data must come from `capability:project-specification-store`. Backup and restoration must not infer specifications from repository files, scan the filesystem, or create a second authoritative specification store.
- Project storage mode, workspace or account identity, lifecycle state, onboarding and connection record IDs, connection state, installation ID, last-validation time, local path, repository owner or display name, remote or clone URL, visibility, and other mutable repository display or access metadata are not part of the initial decrypted payload.
- Separate project or specification revision history, agent runs, run output, generated artifacts, comments, attachments, audit or security logs, analytics, and repository source are excluded from the initial package.
- Current `tasks.md` content is included as a current specification document even when that document contains its own progress log; excluded history means separately retained prior revisions and historical records.
- Data absent from the initial allowlist is excluded rather than serialized for forward compatibility.
- Packages must not contain authentication credentials, GitHub or repository credentials, session secrets, magic-link material, worker pairing credentials, agent-provider secrets, recovery passphrases, derived encryption keys, or other accepted secrets.
- Collaboration memberships, roles, invitations, and permissions are excluded.
- The backup interface must state that repository source is not included. Source inclusion requires a separate future specification and threat model.
- Restore intake requires successful passphrase-based decryption and validates format, version, integrity, size, path safety, attachment types, content limits, and destination authorization before creating or changing records.
- Package validation must not execute imported code, scripts, hooks, or artifacts.
- Unsupported, corrupt, tampered, oversized, unauthorized, or unsafe packages are rejected without partial records.
- A packaged display name is a mutable label, not project identity. If it conflicts under the destination workspace's existing case-insensitive uniqueness rules, the user may explicitly enter another valid, available display name or cancel.
- Display-name conflict recovery must not allocate a new project identity, alter the package, change the canonical repository identity, or select a name automatically.
- For example, if packaged name `Payments` conflicts with existing name `payments`, the user may continue with an available name such as `Payments restored`; if that name also conflicts, restoration remains blocked until the user enters an available name or cancels.
- Repository identity is not a mutable conflict label. If the packaged canonical repository identity is already linked to a different project in the destination workspace, restoration is blocked.
- A repository conflict must not offer silent relinking, unlink the existing project, accept a different repository, or weaken the workspace's canonical repository uniqueness constraint.
- When both name and repository conflicts exist, the repository conflict blocks restoration regardless of any proposed display name.
- Repository connections and authorization are not transferable; reconnection requires explicit user selection and normal provider or worker validation.
- Restoring or reconnecting must not modify repository files, branches, remotes, settings, or Git configuration.
- The selected storage mode must satisfy its normal device or hosted identity prerequisites before restoration commits.
- Restoration commits atomically or leaves no partial project, package record, attachment, or repository connection.
- Restored specification identities and current document sets must be prepared through the shared specification-store destination transaction seam so project and specification state commit together or not at all.
- The hosted deployment operator is controller only for the personal data its deployment receives while generating, delivering, validating, or restoring a package, handling verified rights, or providing minimum operational security. Device-only processing remains under the device and operating-system boundary.
- Core package and restoration processing is limited to providing the user-requested backup and restoration service and uses the approved service-performance basis. Minimum operational-security processing uses the documented legitimate-interest basis and approved balancing assessment.
- Package data, restored project data, provenance, logs, and encrypted or otherwise linkable identifiers remain personal or confidential data; encryption does not make them anonymous.
- The service must not retain a completed backup package after successful delivery. A downloaded package is under the user's control, and the service cannot retrieve or delete copies the user keeps outside the service.
- Raw passphrases and derived keys exist only transiently for the active cryptographic operation and are discarded immediately afterward. Decrypted temporary content is discarded immediately after the active validation or commit path ends and never enters service backups, logs, diagnostics, analytics, caches, or indexes.
- Encrypted generation files, restore uploads, extraction or parsing files, and `ImportAttempt` records are deleted immediately after success, cancellation, or failure. A cleanup worker must delete any stranded encrypted temporary data or attempt record within 24 hours of creation.
- Persistent `PackageProvenance` contains only the package schema version and restoration timestamp associated with the restored project. It must not retain a package hash, filename, source account, workspace, device, exporter identity, network address, or original storage mode.
- `PackageProvenance` and restored project records are retained only while the active project or service requires them and are deleted through verified project erasure or service-termination workflows, subject only to a separately approved legal obligation.
- Derived records, caches, indexes, and processor copies follow the same deletion request. Encrypted rolling backups expire within 35 days and cannot be restored outside the approved recovery and deletion-propagation process.
- Minimum operational-security logs contain only event type, time, outcome, and a non-secret correlation identifier; they contain no package name, project or specification content, passphrase material, repository identifier, filename, path, or decrypted field and are deleted after 30 days.
- Access is limited to the authorized user and destination boundary for the active operation, plus approved operations personnel when necessary for security, support, lifecycle enforcement, or verified rights handling. Coding agents and model providers receive no package or temporary-data access from this slice.
- Verified access, correction, erasure, restriction, objection, and portability workflows cover service-held package attempts, provenance, restored records, logs where applicable, processors, and backup-expiry handling. A self-service rights screen is not required in this slice.
- Backup and restoration data must not be reused for analytics, advertising, model training, unrelated product improvement, or identity-presence tracking.
- Actual controller contact details, processors, hosting and backup regions, transfer safeguards, notices, incident paths, retention enforcement, and any required DPIA or final legal review remain a public-release gate rather than an implementation or local-verification blocker.
- Technical controls and tests provide compliance evidence but do not replace required privacy or legal approval.

## Acceptance Criteria

- [AC-01] Given an authorized backup is requested, when the package is created and its decrypted payload is inspected, then it has the minimum required envelope metadata and contains only the stable project ID and display name, non-secret provider and canonical repository identity, and each current specification's logical identity, title, and current `requirements.md`, `design.md`, and `tasks.md` content; it contains no separately retained history, agent run, generated artifact, comment, attachment, audit or security log, analytics, repository source, local path, mutable repository access metadata, workspace identity, storage mode, or lifecycle state.
- [AC-02] Given exported package contents are inspected, when forbidden secret categories are searched, then no accepted credential, token, session secret, pairing secret, provider key, or encryption key is present.
- [AC-03] Given a package includes a field or section outside the approved schema, when validation runs, then the explicit compatibility rule rejects or ignores it without silently changing the meaning of the restored project.
- [AC-04] Given a package is corrupt, tampered, unsupported, oversized, unauthorized, or unsafe, when restoration is attempted, then no project or partial persistent data is created.
- [AC-05] Given a compatible package, successful passphrase-based decryption, authorized hosted storage, and no conflict, when restoration commits, then exactly one hosted project and its current specifications are created atomically with the packaged stable identities.
- [AC-06] Given the packaged stable project identity already exists in the selected destination or a project catalog accessible to the current restore session, when restoration is attempted, then it is rejected without overwriting, merging, updating, renaming, or changing either project.
- [AC-07] Given the packaged project name conflicts case-insensitively with a different project and no other conflict exists, when restoration is evaluated, then the user may enter another valid, available display name or cancel; continuing preserves the packaged stable project and repository identities, while no automatic name is selected and no record is created before commit.
- [AC-08] Given the package references a canonical repository already linked to a different project in the destination workspace, when restoration is evaluated, then restoration is blocked without relinking, unlinking, substituting another repository, or changing either project, even if the user supplies an available display name.
- [AC-09] Given repository authorization is absent, when project data is restored, then the project remains unconnected and no stale or packaged credential is accepted.
- [AC-10] Given explicit GitHub repository reconnection succeeds through normal provider authorization, when repository state is inspected, then repository files, branches, remotes, settings, and Git configuration remain unchanged.
- [AC-11] Given restoration fails after temporary intake or extraction, when cleanup runs, then temporary files and processing records are removed under the approved lifecycle and no partial project remains.
- [AC-12] Given the slice's package, temporary, provenance, log, backup, processor, and restored-record data flows are reviewed, when implementation approval is evaluated, then each personal-data category follows the approved service or security purpose and lawful basis, minimum fields, access, retention, deletion, rights, processor, transfer, no-reuse, and required-review contract.
- [AC-13] Given a user starts backup, when the interface presents package scope and recovery-passphrase creation, then it identifies the three included logical content categories, states that history, runs, artifacts, comments, attachments, logs, and repository source are excluded, requires matching passphrase confirmation and the unrecoverable-loss acknowledgement, and returns an encrypted package or actionable failure without implying cross-user sharing or create-copy behavior.
- [AC-14] Given a user creates or restores a backup, when encryption and recovery behavior are exercised, then the user must set and confirm a recovery passphrase after acknowledging that it cannot be recovered, every restoration requires the correct passphrase, missing or incorrect input exposes no decrypted content and creates no persistent project data, and neither the passphrase nor a derived encryption key is stored by the package, service, device persistence, logs, diagnostics, analytics, exports, or backups.
- [AC-15] Given a signed-out account or unavailable device may contain the packaged stable project identity, when duplicate preflight runs, then it checks only the selected destination and catalogs already accessible to the current restore session and performs no global registry lookup, background identity-presence reporting, sign-in, device wake-up, or unavailable-boundary query; if a same-ID record becomes accessible later, both authoritative records remain separate and unchanged without automatic merge, upload, synchronization, or authority selection.
- [AC-16] Given package generation or restoration reaches success, cancellation, failure, or abandonment, when transient-data lifecycle enforcement runs, then the service retains no completed package, passphrases, derived keys, and decrypted temporary content are discarded immediately after use, terminal encrypted temporary data and attempts are deleted immediately, and stranded encrypted copies and attempts are deleted within 24 hours.
- [AC-17] Given a user starts restoration, when the package is selected, then the interface requires the recovery passphrase and one available destination storage mode, performs that destination's normal authorization step, and presents validation progress and actionable compatibility, safety, passphrase, and authorization results before any project mutation.
- [AC-18] Given restoration reaches an identity, name, or repository conflict or completes successfully, when the interface presents the result, then it blocks same-identity and canonical-repository conflicts, permits an explicitly entered valid replacement name only for a name-only conflict, supports cancellation without mutation, and presents completion without implying cross-user sharing or create-copy behavior.
- [AC-19] Given provenance or restored project data reaches project deletion or service termination, when the approved lifecycle runs, then persistent provenance contains only package schema version and restoration time, is deleted with the project, and creates no retained source-identity link.
- [AC-20] Given operational-security logs are written for backup or restoration, when logging and expiry controls run, then each record contains only event type, time, outcome, and a non-secret correlation identifier, contains no package or project content or repository identifier, and expires within 30 days.
- [AC-21] Given a compatible package, successful passphrase-based decryption, an authorized device destination, and no conflict, when restoration commits, then exactly one device-authoritative project and its current specifications are created atomically with the packaged stable identities and no hosted authoritative copy.
- [AC-22] Given explicit local-repository reconnection succeeds through the normal worker validation flow, when repository state is inspected, then repository files, branches, remotes, settings, and Git configuration remain unchanged.
- [AC-23] Given service-held portability data is subject to verified access, correction, erasure, restriction, objection, or portability action, when the approved rights workflow runs, then applicable project, specification, attempt, provenance, derived, processor, and backup-expiry actions propagate without disclosing another project or identity.
- [AC-24] Given portability data enters encrypted rolling backups, when lifecycle enforcement runs, then those copies expire within 35 days and cannot be restored outside the approved recovery and deletion-propagation process.
- [AC-25] Given analytics, advertising, model training, unrelated product improvement, identity tracking, or coding-agent or model-provider access is attempted for portability data, when policy enforcement runs, then the use is denied and no linkable package, project, repository, device, workspace, network, or content identifier is emitted.

## Open Questions

- None.
