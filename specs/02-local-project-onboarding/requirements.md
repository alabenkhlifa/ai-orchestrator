# Local Project Onboarding

## Status

Approved

## Outcome

A user can choose `Work without GitHub`, connect a Git repository on their computer through a paired local worker, and create a project without requiring a GitHub account or uploading repository source.

## Users

- BA, PO, and PM users working with a repository available on their computer.
- Developers and technical contributors using local or non-GitHub repositories.

## Primary Workflow

1. The user selects `Work without GitHub` from the shared entry surface.
2. The product explains the available project-data storage modes defined by `specs/05-project-storage-lifecycle/`.
3. The product detects whether a local worker is paired to the current personal or device workspace.
4. If no compatible macOS worker is paired, the product guides the user to copy the pairing code from the worker app's menu bar and paste it into the product, and covers installing the app for someone who does not have it yet, without requiring terminal commands.
5. The paired worker opens the operating system's folder picker, then shows the selected repository name and location and validates that it is a Git repository.
6. Before approved onboarding metadata leaves the device for the first time, the product explains in plain language what remains local, what is shared, and the recovery limit for accountless device-workspace data, then requires confirmation.
7. The worker returns only the minimum approved connection and compatibility metadata.
8. The product applies the shared repository-uniqueness and project-naming rules.
9. The project and local repository connection are created atomically, then the product opens the new project's dashboard with its repository, storage mode, and connection status without starting an agent.

## In Scope

- The `Work without GitHub` entry action.
- Accountless on-device project onboarding.
- Local worker discovery, installation guidance, pairing, revocation, and reconnect states needed for onboarding.
- Local Git repository selection and validation.
- Minimum repository identity and connection metadata exchange.
- Versioned portable local repository identity generation, exact matching, and source-side upgrade from the legacy workspace-scoped fingerprint.
- First-connection privacy disclosure, confirmation, and accountless data-loss warning.
- Project creation using the shared naming and repository-uniqueness rules.
- Direct post-creation handoff to the new project's dashboard.
- Persistent project visibility when the worker or repository becomes unavailable.
- Integration boundaries for hosted passwordless access and project storage selection.
- Actionable failure states for non-technical users.

## Out of Scope

- GitHub repository onboarding, defined in `specs/01-github-project-onboarding/`.
- Passwordless hosted identity internals, defined in `specs/03-hosted-passwordless-access/`.
- Identity merging, defined in `specs/04-github-identity-linking/`.
- Storage migration and retention internals, defined in `specs/05-project-storage-lifecycle/`.
- Project export and import, defined in `specs/06-project-portability/`.
- Remote workers hosted in the cloud or on devices such as a Raspberry Pi.
- Windows and Linux local-worker support in the first executable slice.
- Agent installation, model-provider setup, or deciding where an AI agent executes.
- Uploading, browsing, editing, or executing repository source from the control plane during onboarding.
- Additional isolation between people sharing the same operating-system user profile and filesystem permissions.

## Business Rules

- Selecting `Work without GitHub` means the repository is local to the user's computer; it does not require the AI agent to run locally.
- A GitHub account is not required for the local path.
- The first usable release must not be made available until both `Work without GitHub` and `Login with GitHub` can complete their specified onboarding paths.
- Neither primary action may be disabled, hidden, presented as a placeholder, or lead to a dead or incomplete path in that release.
- Accountless on-device projects are owned by the current operating-system user and filesystem permission boundary.
- SDD Orchestrator does not add a second local multi-user isolation layer inside that boundary.
- A local worker must be explicitly paired to the current personal or device workspace before it can register a repository.
- The first executable local-worker slice supports macOS. Windows support is deferred next, followed by Linux.
- Worker installation, pairing, reconnection, and update guidance must not require terminal commands from the user.
- The product cannot detect whether the worker app is installed on the user's machine. Pairing guidance must therefore address someone who already has the app first, and present installation as the alternative branch rather than as the assumption.
- Pairing guidance must say where the code is and how to get it: the worker app's icon in the macOS menu bar, whose status line copies the code to the clipboard when clicked.
- Every surface that asks for a pairing code shows the same guidance for obtaining that code, so the instructions cannot drift apart between surfaces. A surface adds its own step only for what it uniquely offers, such as the field the code is pasted into.
- Pairing credentials must be attempt-bound, replaceable, revocable, and protected from client payloads, logs, analytics, and project data.
- A worker paired to one workspace cannot register or operate on a project owned by another workspace.
- Repository selection must use the operating system's folder picker. The product may show the selected name and location afterward but must not require manual path entry.
- A selected path must be validated as a Git repository before project creation.
- During onboarding, local filesystem paths, remote URLs, filenames, Git history, and source code must not leave the device.
- Only the minimum approved connection and compatibility metadata may leave the device during onboarding. The exact fields and internal identifiers are a technical-design decision constrained by this boundary.
- A new local repository connection receives a versioned, non-reversible canonical identifier whose validation material permits a worker to prove the same repository after an explicit same-project backup transfer without carrying a path, credential, source workspace identity, or raw Git object ID.
- Independently onboarding the same repository in another workspace must create a different canonical identifier. Cross-workspace equality becomes visible only when an existing identifier is deliberately transferred through the same-project portability workflow.
- Within one workspace, duplicate detection must compare the selected repository against that workspace's existing canonical identifiers through worker validation before allocating a new identifier.
- A legacy workspace-scoped repository fingerprint is not portable. Before a local project using that format can be backed up for replacement-environment reconnection, the user must explicitly locate the source repository and pass exact worker validation; a successful match atomically upgrades only the connection identity, while a mismatch or unavailable source leaves the project unchanged and backup blocked.
- Before approved onboarding metadata leaves the device for the first time, the product must explain in plain language what remains local, what is shared, and that accountless project history cannot be recovered without a previous export. The user must confirm before the connection continues.
- The disclosure must remain available after confirmation. It must not require confirmation on every connection unless the disclosed data handling changes.
- Linking must not modify repository files, branches, remotes, hooks, or Git configuration.
- Local projects use the same workspace-scoped, case-insensitive naming and one-project-per-repository rules as GitHub projects.
- Successful project creation must open the new project's dashboard rather than return to the entry surface, repository selection, or project catalog.
- The new project's dashboard must show the linked repository, selected storage mode, and current connection status.
- A worker or repository becoming unavailable changes connection state without deleting or hiding the project.
- Reinstalling or replacing the worker under the same operating-system user must leave existing projects visible and require explicit pairing of the replacement before filesystem access resumes.
- When a repository is moved or renamed, the project must remain visible and provide a `Locate repository` action.
- `Locate repository` may restore the existing connection only when the selected repository matches its canonical identity. A non-matching repository must be treated as a different repository and must not replace the existing connection.
- Matching a portable canonical identifier must not require the source workspace identity. Matching or upgrading an identifier must not modify repository files, branches, remotes, hooks, settings, or Git configuration.
- Authentication later may combine on-device and authorized hosted projects in one catalog, but must not upload, reassign, duplicate, or change the storage mode of on-device projects.
- Every project in a combined catalog must show its storage mode and current device availability.
- Different stable projects must remain separate catalog entries even when they link to the same repository. A shared repository alone must not merge or deduplicate them.
- One stable project that has been explicitly migrated or resynchronized must appear once in the catalog with its authoritative storage mode.
- Combined-catalog presentation must not automatically merge projects, link identities, upload data, synchronize data, or change a project's storage mode.
- Signing out removes hosted access but leaves on-device projects available through `Work without GitHub`.
- If accountless device-workspace data is lost, reconnecting the repository must not claim to restore the lost SDD project history. Without a previous export, the repository can only start new project history.
- Recovery of lost accountless project history requires importing a previous export through `specs/06-project-portability/`.
- Personal metadata that leaves the device requires an approved GDPR purpose, lawful basis, minimum fields, access boundary, retention, deletion, rights behavior, processors, transfers, and review.

## Acceptance Criteria

- [AC-01] Given a user selects `Work without GitHub`, when onboarding starts, then no GitHub authentication is requested.
- [AC-02] Given a candidate first usable release, when either primary action is selected, then its specified onboarding path is available through completion without a disabled, placeholder, or dead action.
- [AC-03] Given no compatible worker is paired on macOS, when the local path continues, then the user receives graphical installation and pairing guidance without requiring terminal commands.
- [AC-04] Given a valid pairing attempt, when pairing succeeds, then the worker is bound only to the current workspace with protected replaceable credentials.
- [AC-05] Given a paired worker is available, when the user chooses a repository, then the operating system's folder picker opens and the product shows the selected repository name and location without requiring manual path entry.
- [AC-06] Given a path is not a Git repository, when validation runs, then project creation is blocked and no source content is uploaded.
- [AC-07] Given approved onboarding metadata would leave the device for the first time, when the connection is presented, then the user sees what remains local, what is shared, and the accountless data-loss warning before deciding whether to continue.
- [AC-08] Given the user does not confirm the first-connection disclosure, when onboarding stops, then no repository or device metadata is sent.
- [AC-09] Given the user previously confirmed the disclosure and the disclosed data handling has not changed, when a later connection occurs, then confirmation is not required again and the disclosure remains accessible.
- [AC-10] Given a valid local Git repository, when the user confirms the connection, then the worker returns only minimum approved connection and compatibility metadata while local paths, remote URLs, filenames, Git history, and source code remain on the device.
- [AC-11] Given a repository is linked for the first time, when worker validation succeeds, then the connection receives a versioned non-reversible canonical identifier that contains no path, credential, workspace identity, or raw Git object ID.
- [AC-12] Given the same repository is selected again in one workspace, when duplicate validation runs against that workspace's existing canonical identifiers, then the existing connection is found without allocating a second identity.
- [AC-13] Given the same repository is independently onboarded in another workspace without an existing identifier being supplied, when creation succeeds, then it receives a different canonical identifier and no global repository-equality signal is emitted.
- [AC-14] Given an unlinked local repository and an available project name, when creation succeeds, then one project and one repository connection are created atomically.
- [AC-15] Given local project creation commits successfully, when onboarding completes, then the new project's dashboard opens and shows the linked repository, selected storage mode, and current connection status.
- [AC-16] Given the same canonical local repository is already linked in the workspace, when creation is attempted again, then it is blocked without creating a duplicate.
- [AC-17] Given linking completes, when local repository state is inspected, then files, branches, remotes, hooks, and Git configuration are unchanged.
- [AC-18] Given the worker later becomes unavailable, when the catalog is shown, then the project remains visible with an unavailable or authorization-required connection state.
- [AC-19] Given the worker is reinstalled or replaced under the same operating-system user, when the user returns, then existing projects remain visible and filesystem access resumes only after the replacement worker is explicitly paired.
- [AC-20] Given a linked repository is moved or renamed, when the project is opened, then it remains visible with a `Locate repository` action.
- [AC-21] Given `Locate repository` is used, when the selected repository matches the existing canonical identity, then the connection is restored; when it does not match, then the existing connection is preserved and the selection is treated as a different repository.
- [AC-22] Given a project still uses a legacy workspace-scoped fingerprint, when the user explicitly locates the source repository and exact worker validation succeeds, then the connection is atomically upgraded to the portable identifier without changing project identity or repository state; when validation fails or the source is unavailable, the legacy connection remains unchanged and cross-device backup remains blocked.
- [AC-23] Given a portable canonical identifier arrives through the same-project restoration workflow, when a paired target worker validates a selected repository against it, then an exact match can reconnect without the source workspace identity and a mismatch cannot replace the packaged identity.
- [AC-24] Given an accountless device user later authenticates, when the combined catalog is shown, then on-device projects remain local and identify their storage and availability state.
- [AC-25] Given distinct on-device and hosted projects link to the same repository, when the combined catalog is shown, then both remain separate entries with their own storage mode and device availability.
- [AC-26] Given one stable project has been explicitly migrated or resynchronized, when the combined catalog is shown, then it appears once with its authoritative storage mode.
- [AC-27] Given catalog entries refer to the same repository, when the catalog is composed, then no project merge, identity link, upload, synchronization, or storage-mode change occurs automatically.
- [AC-28] Given the authenticated user signs out, when `Work without GitHub` is opened under the same operating-system boundary, then on-device projects remain available.
- [AC-29] Given accountless device-workspace data is lost without a previous export, when the repository is connected again, then the product warns that prior project history cannot be restored and starts new project history rather than claiming recovery.
- [AC-30] Given accountless device-workspace data is lost and a previous export exists, when the user chooses to recover the project, then recovery continues through the import workflow defined by `specs/06-project-portability/`.
- [AC-31] Given pairing fails, when the operation ends, then no partial connection, credential, or source upload remains.
- [AC-32] Given repository validation fails, when the operation ends, then no partial project, connection, or source upload remains.
- [AC-33] Given any surface asks the user for a pairing code, when its guidance is read, then that guidance is the one shared guidance, it tells someone who already has the worker app how to copy the code from its menu bar, and it offers installation as the alternative rather than assuming the app is missing.

## Open Questions

- None.
