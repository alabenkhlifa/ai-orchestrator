# Project Storage Selection

## Status

Approved

## Outcome

A user can explicitly choose on-device or SDD Orchestrator-hosted storage for each project's specifications, tasks, agent runs, and generated files during GitHub or local repository onboarding, while the linked repository remains unchanged and the selected authoritative mode stays visible after creation.

## Users

- Project owners choosing where SDD specifications, tasks, agent records, and generated files are stored.
- Privacy, operations, and support personnel governing the introduced project, storage, onboarding, and diagnostic records.

## Primary Workflow

1. During GitHub or local repository onboarding, the user reaches a dedicated step that explains which project work the choice covers and that the linked repository stays where it is.
2. Both storage choices remain visible; a choice whose prerequisite is missing explains what is required and provides the relevant setup action.
3. If either storage mode requires device setup or hosted sign-in, the product completes that prerequisite and returns to the same storage step with the selected repository and current onboarding state preserved.
4. The prerequisite result refreshes availability without selecting a storage mode or creating a project.
5. The user explicitly chooses whether to save the project work on the current device or in their SDD Orchestrator account after the chosen mode's prerequisites are available.
6. Project creation commits one explicit authoritative storage mode together with the project and repository connection or leaves no partial project.
7. The new project's dashboard and project catalog show the authoritative storage mode with the repository and current connection or device-availability state.
8. The same catalog may show on-device and hosted projects without merging them, changing their storage mode, or moving project data; if separately authoritative records share a stable project ID, it shows both as an identity conflict without choosing an authority.

## In Scope

- Per-project on-device or hosted storage selection for GitHub and local repositories.
- Plain-language storage-mode presentation, prerequisite status, and setup actions.
- Preservation of repository and onboarding state across device setup and hosted sign-in.
- Explicit selection with no silent default.
- One authoritative storage mode committed atomically with project creation.
- Storage-mode and availability presentation in project catalogs and on the new-project dashboard.
- Mixed on-device and hosted projects for one user.
- Non-mutating presentation of a later-visible same-project identity collision created under the visibility-bounded restore contract in `specs/06-project-portability/`.
- Device, hosted-identity, repository, worker, and agent boundary separation.
- GDPR data protection by design and by default for the records, logs, processors, and lifecycle introduced by this slice.

## Out of Scope

- Repository onboarding mechanics, defined in `specs/01-github-project-onboarding/` and `specs/02-local-project-onboarding/`.
- Passwordless identity mechanics, defined in `specs/03-hosted-passwordless-access/`.
- Identity merging, defined in `specs/04-github-identity-linking/`.
- Changing storage mode after project creation.
- Device-to-hosted or hosted-to-device transfer, authority handoff, conflict handling, synchronization, resynchronization, and full rehydration.
- Hosted-copy soft deletion, retention, cleanup, backup and processor propagation, legal-retention exceptions, and migration-specific rights handling.
- Migration and retained-copy analytics.
- Export and import packages, defined in `specs/06-project-portability/`.
- Collaboration invitation, role, membership, permission, and live-sharing workflows.
- User-initiated project deletion.
- Repository source transfer.
- Resolving, merging, synchronizing, deleting, or selecting authority between separately stored records that share a stable project ID.

Storage-mode migration and the resulting hosted-copy lifecycle require a separate child specification before implementation. That child must preserve the stable project and repository identities established here and define authority handoff, failure recovery, synchronization, retention, deletion, privacy, and proof without weakening this selection contract.

## Business Rules

- Storage mode is selected per project, not once for the user or workspace.
- The selection step must be titled `Where should your project work be saved?`.
- The selection step must explain: `Your project work includes specifications, tasks, agent runs, and generated files. Your linked repository stays where it is.`
- The on-device choice must be labeled `On this device` and explain: `Your project work stays on this device. It will not be available on another device or to collaborators unless you move or export it later.`
- The hosted choice must be labeled `In my SDD Orchestrator account` and explain: `Your project work is saved to your account so you can access it from other devices.`
- First-release storage-selection copy must not state or imply that collaboration is available; collaboration remains out of scope until its workflow is approved and implemented.
- Both choices must remain visible when a device or identity prerequisite is missing; an unavailable choice must identify the missing prerequisite and provide the relevant setup action instead of disappearing.
- Starting device setup must preserve the selected repository and current onboarding state.
- After device setup succeeds, is canceled, or fails, the product must return to the same storage step without losing the selected repository.
- Successful device setup must only re-evaluate availability. It must not silently select `On this device` or create a project.
- Canceled or failed device setup must leave `On this device` unavailable and must not create a project.
- Starting hosted sign-in from an accountless local-onboarding attempt must preserve the selected repository and current onboarding state.
- After hosted sign-in succeeds, is canceled, or fails, the product must return to the same storage step without losing the selected repository.
- Successful hosted sign-in must only re-evaluate hosted availability. It must not silently select `In my SDD Orchestrator account` or create a project.
- Canceled or failed hosted sign-in must leave hosted storage unavailable for that attempt and must not create a project or disclose a hosted identity.
- Project creation requires an explicit storage choice; neither mode is silently selected for the user.
- Project, repository connection, and authoritative storage mode must commit atomically or leave no partial project or storage state.
- After project creation succeeds, the new project's dashboard must show the selected authoritative storage mode with the linked repository and current connection status.
- Every catalog entry must show its storage mode and current device or connection availability.
- The same user may see on-device and hosted projects simultaneously.
- Catalog composition must not merge projects, change their storage mode, upload data, or synchronize data.
- Catalog composition treats each authorized destination record as separately authoritative even when two records carry the same stable project ID.
- If separately authoritative on-device and hosted records with the same stable project ID become visible in one session, each record must remain present with its storage mode and availability, and the catalog must identify the collision without choosing, merging, deleting, reassigning, uploading, or synchronizing either record.
- Collision detection is computed only from records already available to the current catalog session. It must not persist a cross-boundary ownership link, upload a device project identifier, or emit a collision analytics event.
- The catalog provides no collision-resolution action in this slice. Resolution requires a future specification.
- Repository source does not restrict project-data storage; GitHub and local repositories may use either mode.
- Repository location, project-data storage, local worker location, and AI-agent execution location are independent boundaries.
- On-device storage must not require an account and remains under the current device and operating-system trust boundary.
- Every on-device project is owned by `DeviceWorkspace`, including when the user is signed in during creation.
- `PersonalWorkspace` may include an on-device project in the signed-in user's combined catalog but must not acquire, reassign, upload, duplicate, or change that project or its storage mode.
- Signing in or out changes catalog composition and hosted access only; it does not change `DeviceWorkspace` ownership or the availability of on-device project data under the same operating-system boundary.
- Hosted storage persists independently from the current device and requires an authorized identity before data is exposed.
- A project and its project-data records belong to one explicit authoritative storage mode.
- Selecting a storage mode must not modify the linked repository or its stable connection identity.
- Personal data introduced by storage selection requires an approved purpose, lawful basis, minimum fields, access boundary, retention, deletion, rights behavior, processors, transfers, and required review before implementation.
- The hosted deployment operator is controller only for the personal data its deployment receives for hosted storage, prerequisite handoff, project registration, rights handling, and minimum operational security. Device project content and device-authoritative project records remain under the device and operating-system boundary unless the user explicitly selects hosted storage.
- Core hosted and transient handoff records may be processed only as necessary to provide the user-requested storage-selection and project-creation service. Minimum operational-security records may be processed only for the documented service-security purpose and approved legitimate-interest assessment.
- The hosted boundary must not retain local paths, source content, filenames, Git history, raw prerequisite proofs, device labels, operating-system usernames, stable hardware identifiers, or device-authoritative project content.
- Raw hosted-return and device-readiness proofs must be discarded immediately after verification. Expired, canceled, failed, or consumed onboarding attempts and their proof digests and minimum binding metadata must be deleted within 24 hours.
- Active hosted workspace, project, repository-connection, and hosted-storage records may be retained only while required by the active project or hosted service. Verified rights or service-termination workflows must delete applicable active and derived records, subject only to a separately approved legal obligation.
- Minimum operational-security logs must be deleted after 30 days. Encrypted rolling backups must expire within 35 days, and processor deletion must follow the deployment's approved contract.
- Access is limited to the current operating-system boundary for device-authoritative data, the authenticated authorized user for hosted project data, and approved operations personnel for necessary security, support, retention, deletion, and verified rights workflows. Coding agents receive no access from this slice.
- Applicable access, correction, erasure, restriction, objection, and portability requests must be handled through a verified workflow; a self-service rights screen is not required in this slice.
- This slice must not emit or retain product-analytics events, identifiers, or storage-choice metrics.
- Actual controller contact details, processors, hosting and backup regions, transfer safeguards, notices, incident paths, retention enforcement, and any required DPIA or legal review remain a public-release gate rather than an implementation blocker.
- Technical controls and tests provide compliance evidence but do not replace required privacy or legal approval.

## Acceptance Criteria

- [AC-01] Given a GitHub or local repository is selected, when the storage step opens, then it is titled `Where should your project work be saved?`, explains what project work includes and that the linked repository stays where it is, and presents `On this device` and `In my SDD Orchestrator account` with their availability and access consequences.
- [AC-02] Given one storage mode is missing a required device or identity prerequisite, when the storage step opens, then both modes remain visible and the unavailable mode explains the missing prerequisite with a relevant setup action.
- [AC-03] Given `On this device` requires setup, when device setup succeeds, is canceled, or fails, then the same storage step, selected repository, and onboarding state are restored; success refreshes availability without selecting a mode, while cancellation or failure leaves `On this device` unavailable and creates no project.
- [AC-04] Given the user has not selected an available storage mode, when project creation is evaluated, then creation is blocked without silently choosing a mode.
- [AC-05] Given on-device storage is chosen, when the project is created, then no account is required and project data remains under the device and operating-system boundary.
- [AC-06] Given hosted storage is chosen, when creation completes, then an authorized identity protects project data that persists independently from the current device.
- [AC-07] Given project creation commits, when its persisted state is inspected, then the project, repository connection, and exactly one authoritative storage mode exist together.
- [AC-08] Given project creation fails, when the operation ends, then no partial project, repository connection, or storage state remains and the linked repository is unchanged.
- [AC-09] Given project creation succeeds, when the new project's dashboard opens, then it shows the linked repository, selected authoritative storage mode, and current connection status.
- [AC-10] Given a catalog contains on-device and hosted projects, when it is shown, then each authorized destination record appears once with its storage mode and current device or connection availability; separately authoritative records sharing a stable project ID remain separate and are identified as an identity conflict.
- [AC-11] Given catalog entries share a repository or stable project ID, or the user signs in or out, when catalog composition changes, then no project is merged, reassigned, deleted, uploaded, synchronized, selected as authoritative, or changed to another storage mode, and no cross-boundary collision link or analytics event is persisted.
- [AC-12] Given the slice's records, logs, processors, and lifecycle are reviewed, when implementation approval is evaluated, then every personal-data category has the approved purpose, lawful basis, minimum fields, access, retention, deletion, rights behavior, processor and transfer treatment, and required review.
- [AC-13] Given storage selection or project creation is exercised, when analytics and logs are inspected, then no product-analytics event, identifier, or storage-choice metric has been emitted or retained, and approved operational logs contain no secrets or project content.
- [AC-14] Given an accountless local-onboarding user starts hosted sign-in, when sign-in succeeds, is canceled, or fails, then the same storage step, selected repository, and onboarding state are restored; success refreshes hosted availability without selecting it, while cancellation or failure leaves hosted storage unavailable, creates no project, and discloses no hosted identity.
- [AC-15] Given a signed-in user creates an on-device project, when ownership and catalog state are inspected or the user later signs out, then `DeviceWorkspace` remains the project owner, `PersonalWorkspace` has not acquired or changed it, and the project remains available under the same device and operating-system boundary.
- [AC-16] Given the hosted choice is shown in the first release, when the user reads its description, then it explains cross-device account access and does not state or imply that collaboration is currently available.
- [AC-17] Given the active-slice data inventory and lifecycle are inspected, when privacy verification runs, then the hosted boundary contains none of the prohibited device or source fields, raw prerequisite proofs have been discarded, terminal attempt and proof-binding records are deleted within 24 hours, security logs within 30 days, encrypted backups within 35 days, and no device-authoritative project content or product analytics is retained.

## Open Questions

- None.
