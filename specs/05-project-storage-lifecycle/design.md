# Project Storage Selection Design

## Context

Repository location does not determine where SDD project data should live. GitHub and local repository onboarding need one shared, explicit storage-selection contract that keeps device storage, hosted storage, repository access, worker location, and agent execution as separate boundaries.

Storage selection is independently implementable and verifiable. Changing storage mode later introduces transfer, synchronization, retained hosted copies, cleanup, and separate failure and privacy lifecycles, so that work is deferred to a child specification.

## Proposed Approach

Present storage mode as an explicit, plain-language project-creation step. Keep both modes visible, show why a prerequisite is missing, and provide the relevant setup action. Preserve repository and onboarding state when device setup or hosted sign-in temporarily leaves the step, then return after success, cancellation, or failure without selecting a mode for the user.

Represent personal and device ownership through one common logical `Workspace` schema with a `hosted` or `device` kind. Keep `PersonalWorkspace` and `DeviceWorkspace` as one-to-one profiles of that root in their authoritative persistence boundary. Backfill existing hosted personal workspaces into common hosted roots with the same IDs so existing hosted project and repository identities do not change. Create device roots and device-authoritative project records only in device persistence.

Persist the authoritative storage mode once on `Project` in the selected destination and enforce that it matches the owning workspace kind. Hosted projects add one `HostedProjectStorage` root in PostgreSQL. Device projects commit the project, local repository connection, and storage mode in one worker-owned local transaction and create no hosted project-data copy.

Dispatch one idempotent registration command to the selected destination. Hosted registration includes attempt consumption in one `Ecto.Multi`. Device registration commits locally first, then acknowledges the same idempotency key to the transient control-plane attempt; a lost acknowledgement is reconciled by asking the device adapter for the already-committed result. Do not introduce a distributed transaction across hosted and device persistence.

Use one shared selection and storage-preparation contract for GitHub and local repository onboarding. Keep source-specific authentication, worker setup, and repository selection in their owning specifications.

Compose only records already authorized and available in the current catalog session. If separately authoritative device and hosted records share a stable project ID after visibility-bounded restoration, render both with an identity-conflict state and their own storage and availability information. Do not create a cross-boundary link, choose authority, merge, upload, synchronize, or resolve the collision in this slice.

## Components Affected

- Shared storage-selection surface and onboarding handoff.
- Common logical workspace ownership schema and hosted or device persistence profiles.
- Project storage-mode domain and persistence boundary.
- Device readiness and hosted-identity prerequisite checks.
- Atomic project creation and prepared-storage abort behavior.
- Project catalog and post-creation dashboard storage presentation, including non-mutating same-ID collision state.
- Privacy, retention, rights, logging, processor, and security controls for introduced records.

## Data and Access Boundaries

- `Workspace`: the common logical project-ownership root with kind `hosted` or `device`; each root and its projects live in the selected authoritative persistence boundary, and existing hosted personal workspace IDs are preserved during hosted backfill.
- `StorageMode`: the `device` or `hosted` value selected explicitly for one project and constrained to match its owning workspace kind.
- `ProjectStorageState`: the logical authoritative boundary represented by `Project.storage_mode`, its owning `Workspace`, and adapter-specific state rather than a second mode-bearing row.
- `ProjectOnboardingAttempt`: short-lived resumable workflow state with an origin context, available personal and device prerequisite contexts, one selected target workspace reference, only source-approved repository metadata, storage choice, browser-flow binding, expiry, destination acknowledgement, and idempotency key.
- `DeviceStorageReceipt`: short-lived, single-use evidence bound to one onboarding attempt, device workspace, selected repository identity, issue time, expiry, and nonce; only the verified receipt digest and minimum binding metadata persist.
- `DeviceWorkspace`: the one-to-one device profile of a `device` workspace under the current operating-system user and filesystem permissions.
- `PersonalWorkspace`: the one-to-one hosted-identity profile of a `hosted` workspace; it may participate in a combined catalog without owning device projects.
- `Project`: the stable project identity associated with one repository connection, one owning workspace, and one authoritative storage mode in the selected destination.
- `HostedProjectStorage`: the one-to-one hosted storage root created only for a hosted project in the project-registration transaction.

Required boundaries:

- A project has exactly one explicit storage mode after successful creation.
- `Project.storage_mode` is the only persisted authoritative mode; no second storage-state row duplicates it.
- Each destination enforces that the project's storage mode matches its owning workspace kind.
- Existing hosted personal workspaces receive common hosted roots with the same IDs so current hosted project and repository foreign-key values remain stable.
- Device workspaces, projects, repository connections, and project content remain in device persistence; the hosted deployment receives no device-authoritative project copy.
- Device and hosted prerequisites are checked without hiding either choice or selecting for the user.
- Device readiness is bound to the onboarding attempt, device workspace, selected repository identity, nonce, and expiry, and cannot authorize another repository, project, workspace, or attempt.
- Hosted storage is not exposed without an authorized identity.
- Repository selection and onboarding state survive prerequisite setup and return.
- Hosted sign-in returns to the same accountless local-onboarding attempt, refreshes hosted availability after success, and exposes no hosted identity after cancellation or failure.
- Prerequisite return uses one browser-flow binding and one-time return proof; it cannot attach a personal or device context to another attempt.
- Selecting a mode sets exactly one target workspace of the matching kind without changing the origin workspace or implicitly linking the personal and device profiles.
- Project, repository connection, and storage state commit together at the selected destination or not at all.
- Hosted registration locks and revalidates the unexpired, unconsumed attempt and selected hosted workspace before writing.
- Hosted registration inserts one `HostedProjectStorage` row and consumes the attempt in one `Ecto.Multi`.
- Device registration validates and consumes one readiness receipt in one worker-owned local transaction with the device project and repository connection, then acknowledges the idempotency key to the transient control-plane attempt.
- Failed creation aborts prepared storage and preserves no partial project state.
- A retry with the same idempotency key returns the already-created destination project; if a device commit succeeded but acknowledgement failed, reconciliation consumes the attempt without creating a second project.
- No registration path attempts a distributed transaction between hosted PostgreSQL and device persistence.
- Repository source, project-data storage, worker location, and agent execution remain independent.
- A device-mode project belongs to `DeviceWorkspace` even when created while the user is signed in.
- `PersonalWorkspace` can compose a view of device projects available on the current device but cannot acquire, reassign, upload, duplicate, or change them.
- Catalog composition does not change project identity, ownership, storage mode, or data location.
- Separately authoritative records sharing a stable project ID remain separate catalog entries. Collision detection uses only records already present in the current composition and persists no cross-boundary ownership or resolution link.
- Project source content, local paths, raw prerequisite proofs, device labels, stable hardware identifiers, credentials, and secrets do not enter hosted selection records, logs, or analytics.
- Introduced personal data follows an approved purpose, access, retention, deletion, rights, processor, transfer, and review contract.

## Interfaces

- Storage-selection interface: ask `Where should your project work be saved?`, explain that project work includes specifications, tasks, agent runs, and generated files while the linked repository stays where it is, present `On this device` and `In my SDD Orchestrator account` with their approved consequences, describe hosted storage as cross-device account access without claiming current collaboration, keep both modes visible, expose missing prerequisites with setup actions, and require an explicit available choice.
- Workspace interface: resolve the common logical hosted or device ownership schema in its authoritative persistence boundary, preserve existing personal workspace IDs during hosted backfill, and expose only the profile authorized for the current operation.
- Onboarding-state interface: accept a stable selected-repository reference from either onboarding source, preserve the origin workspace and browser-flow binding, attach only successfully proven personal or device prerequisite contexts, set a matching target workspace after explicit selection, and restore the same attempt after success, cancellation, or failure.
- Device-readiness interface: verify the worker-supplied proof once, persist only its digest and minimum attempt, device-workspace, repository, nonce, issue, and expiry binding, refresh device availability, and never select a mode or create a project as a setup side effect.
- Hosted-identity interface: start passwordless sign-in with a one-time return proof bound to the preserved accountless local-onboarding attempt and browser flow, return to that same storage step after success, cancellation, or failure, attach the proven hosted workspace only after success, expose no hosted identity after an unsuccessful result, and never select hosted storage or create a project as a sign-in side effect.
- Storage-adapter interface: expose availability, prepare, idempotent commit, abort, and reconcile operations. The hosted adapter contributes to one `Ecto.Multi`; the device adapter invokes the source-owned worker transaction and returns a destination receipt containing only the stable project ID, idempotency key, and success state required to acknowledge or reconcile the transient attempt.
- Project-registration interface: generate or preserve one stable project ID and idempotency key, revalidate the selected target and mode, dispatch to exactly one destination, return the same project for a committed retry, and never create project records in the non-selected destination.
- Storage-state presentation interface: show the authoritative mode with repository and connection or device-availability state on the post-creation dashboard and in the catalog.
- Combined-catalog interface: compose device projects available through the current `DeviceWorkspace` with projects authorized through `PersonalWorkspace` without creating an ownership link, changing storage, or making device data available from another device; when available records share a stable project ID, render each separately with its storage mode, availability, and an identity-conflict state without a resolution action.
- Privacy interface: enforce the approved active-slice data inventory, access, retention, deletion, rights, processor, transfer, log, and no-analytics rules.

## Decisions and Tradeoffs

### Focused Storage-Selection Foundation

- Choice: Keep this specification focused on selecting and establishing the initial storage mode. Move later storage-mode changes and their retained-copy lifecycle to a child specification.
- Reason: Selection and migration have independently valuable outcomes, different failure paths, different personal-data lifecycles, and separate verification gates.
- Consequence: This specification establishes stable identities and boundary contracts that the child must preserve. Migration, synchronization, soft deletion, retention, cleanup, and rehydration cannot be implemented from this agreement.

### Per-Project Storage Choice

- Choice: Let each project independently use device or hosted storage regardless of repository source.
- Reason: Storage, repository, worker, and agent locations solve different user needs.
- Consequence: Catalog, dashboard, authorization, and creation logic preserve one explicit storage state for every project.

### Common Workspace Ownership Schema

- Choice: Use one logical `Workspace` schema with kind `hosted` or `device`, with `PersonalWorkspace` and `DeviceWorkspace` as one-to-one profiles in their authoritative hosted or device stores.
- Reason: Projects, repository connections, naming boundaries, onboarding attempts, and catalog queries need one enforceable ownership key without treating authentication as ownership of device data.
- Consequence: Backfill each existing personal workspace as a hosted root with the same ID, then point hosted projects and repository connections at that root. Device roots and device projects remain local. Each store constrains project storage mode to its workspace kind, while catalog composition joins read results without copying ownership records.

### One Persisted Authoritative Mode

- Choice: Keep the authoritative mode only on `Project`; treat `ProjectStorageState` as the logical combination of project mode, owning workspace, and adapter-specific state.
- Reason: A second mode-bearing row could diverge from project ownership and make authority ambiguous.
- Consequence: Hosted projects have one `HostedProjectStorage` detail row in PostgreSQL, while device projects and connections exist only in device persistence. Destination constraints and adapter tests enforce the allowed shapes.

### Device Ownership Is Independent Of Sign-In

- Choice: Keep every on-device project owned by `DeviceWorkspace`, including projects created while the user is signed in.
- Reason: Authentication may change which projects the catalog can show, but it must not silently change the selected device storage and operating-system trust boundary.
- Consequence: `PersonalWorkspace` may compose device projects into the current-device catalog but cannot own, upload, reassign, duplicate, or change them. Signing out removes hosted access without removing device-project access under the same operating-system user.

### Later-Visible Identity Collisions Stay Separate

- Choice: When currently available device and hosted records share a stable project ID, show both authoritative records as an identity conflict without choosing, merging, deleting, uploading, synchronizing, or resolving them.
- Reason: Visibility-bounded backup restoration cannot reliably discover unavailable devices or signed-out identities, while catalog composition must not turn later visibility into an implicit migration or authority handoff.
- Consequence: Detect the collision only across records already available to the current catalog session, persist no cross-boundary collision link or analytics event, and defer resolution to a future specification.

### Explicit Choice With Visible Prerequisites

- Choice: Keep both modes visible, explain missing prerequisites, and require an explicit available selection with no default.
- Reason: Users need to understand the available storage boundaries without a missing device or identity silently deciding for them.
- Consequence: Device setup and hosted sign-in must return to resumable onboarding state after success, cancellation, or failure and may refresh availability after success but cannot select or create. An unsuccessful hosted sign-in exposes no hosted identity.

### Describe Only Available Hosted Behavior

- Choice: Describe hosted storage as enabling access from other signed-in devices and do not promise collaboration in first-release selection copy.
- Reason: Collaboration invitation, membership, permission, and live-sharing workflows are not part of this slice or the first-release storage-selection behavior.
- Consequence: Future collaboration work may extend the copy only after its product contract and implementation are approved; this slice proves cross-device access without implying unavailable behavior.

### Destination-Atomic And Idempotent Registration

- Choice: Commit project identity, repository connection, storage mode, and adapter-specific state atomically at exactly one destination. Use one `Ecto.Multi` for hosted registration and one worker-owned local transaction for device registration.
- Reason: A project without a usable explicit storage boundary is invalid.
- Consequence: Hosted registration consumes the attempt in its transaction. Device registration acknowledges afterward with the same idempotency key; lost acknowledgement is reconciled against the committed local result. Failed preparation invokes adapter abort or reconciliation, and no distributed transaction or duplicate project is allowed.

### Bound And Minimized Prerequisite Proof

- Choice: Bind hosted return and device readiness to the same expiring onboarding attempt and browser flow. Persist only one-time proof digests and minimum binding metadata.
- Reason: An unbound receipt or return token could authorize the wrong repository, workspace, or attempt, while raw proof retention would add unnecessary security data.
- Consequence: Successful prerequisite setup refreshes availability only. Cancellation, failure, expiry, mismatch, replay, or attempted cross-workspace use fails closed without attaching a context, selecting a mode, or creating a project.

### Shared Contract, Source-Owned Integration

- Choice: Define one storage-selection and preparation contract here while GitHub and local onboarding retain ownership of authentication, worker setup, repository selection, and source-specific navigation.
- Reason: The storage outcome is shared, but each repository source has a different trust boundary and prerequisite workflow.
- Consequence: The shared surface and domain proof can be implemented once, while each onboarding specification must own and prove its end-to-end integration before release.

### GDPR By Design And Default

- Choice: Require an approved processing and lifecycle contract for every record and path introduced by storage selection and creation.
- Reason: Project identity, workspace ownership, repository metadata, device readiness, logs, and processors can contain personal or security-relevant data.
- Consequence: Technical checks provide evidence but do not replace accountable privacy or legal approval. Product analytics and storage-choice metrics are prohibited in this slice.

### Approved Development Privacy Contract

- Choice: Reuse the approved Slice 01 development contract for hosted and transient control-plane data and extend it with a strict device-authoritative boundary.
- Purpose and basis: The hosted deployment operator is controller for only the personal data its deployment receives. Process core hosted and transient handoff records only as necessary to provide the user-requested storage-selection and project-creation service. Process minimum operational-security records only for the documented service-security purpose and approved legitimate-interest assessment. Do not reuse either category for analytics, advertising, model training, or unrelated product improvement.
- Minimum hosted fields: common hosted workspace ID and kind; existing personal-workspace relation; project ID, name, storage mode, lifecycle state, timestamps, hosted repository metadata approved by the source specification, and hosted storage root and state; transient attempt ID, origin and target references, source-approved repository metadata, selected mode, status, idempotency key, proof digests, issue, expiry, consumption, and acknowledgement times; and minimum structured security event type, time, outcome, and non-secret correlation ID.
- Device boundary: Device workspace, device project and connection records, specifications, tasks, runs, generated files, local paths, filenames, remote URLs, Git history, source content, operating-system username, device label, stable hardware identifier, and raw return or readiness proofs do not persist in hosted storage. The hosted boundary receives only the minimum verified handoff or acknowledgement fields required when the user invokes hosted sign-in or a hosted registration handoff.
- Lifecycle: Discard raw return and readiness proofs immediately after verification. Make expired, canceled, failed, or consumed attempts and proof bindings unusable immediately and delete them within 24 hours. Retain active hosted workspace, project, repository-connection, and hosted-storage records only while the active project or hosted service requires them. Delete operational-security logs after 30 days. Expire encrypted rolling backups within 35 days and enforce processor deletion under the deployment contract.
- Access and rights: Device-authoritative data stays under the current operating-system boundary. Restrict hosted data to the authenticated authorized user and approved operations personnel for necessary security, support, lifecycle, and verified rights workflows. Coding agents receive no access from this slice. Support applicable access, correction, erasure, restriction, objection, and portability through a verified operator workflow; self-service rights screens are not required.
- Release consequence: Implementation and local verification may proceed under this contract. A public hosted deployment remains blocked until its actual controller contact, processors, hosting and backup regions, transfer safeguards, notices, incident path, retention enforcement, and any required DPIA or legal review are recorded.

### Canonical Verification Toolchain

- Choice: Reuse the established Phoenix toolchain: ExUnit with the Ecto sandbox for domain, constraint, transaction, concurrency, lifecycle, and adapter-contract proof; LiveView tests for the selection workflow; Playwright plus axe for responsive browser and accessibility proof; and the existing static, security, production-build, and release commands.
- Reason: The shared storage boundary needs deterministic proof across database, workflow, browser, privacy, and production packaging without depending on a live provider or worker in ordinary CI.
- Consequence: The gate uses `mix check`, the explicit Mix quality and security commands, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release`. Source-specific live GitHub, passwordless-delivery, and local-worker smoke tests remain owned by their specifications and coordinated release gates.

## Risks

- A silent default can store project work under a boundary the user did not choose. Require an explicit available mode.
- Prerequisite setup can lose repository context or create a project prematurely. Use resumable attempt-bound state and keep setup non-creating.
- A stale or reusable device receipt can authorize the wrong project boundary. Bind readiness to the current device, workspace, repository selection, and attempt with expiry and one-time consumption.
- A workspace refactor can change stable project ownership or orphan current hosted rows. Backfill hosted roots with existing personal workspace IDs and prove foreign-key and rollback integrity before switching hosted reads.
- A control-plane acknowledgement can fail after a device project commits. Reconcile with the destination idempotency key and stable project ID rather than creating a duplicate or rolling back committed device data.
- Partial creation can leave an unusable project or orphaned storage state. Commit atomically and abort prepared storage on failure.
- Catalog composition can be mistaken for migration or identity merging. Use stable project identity and make composition non-mutating.
- A later-visible same-ID record can be mistaken for one synchronized project. Render each authoritative record separately with its storage boundary and a non-mutating identity-conflict state.
- Hosted and device records can collect unnecessary data. Approve minimum fields and lifecycle before implementation and prohibit source content, secrets, and product analytics.
- Source-specific integrations can drift from the shared contract. Require task-level integration and browser proof for both GitHub and local onboarding.

## Open Questions

- None.
