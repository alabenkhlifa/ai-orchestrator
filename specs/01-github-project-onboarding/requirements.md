# GitHub Project Onboarding

## Status

Approved

## Outcome

A BA, PO, PM, developer, or other project contributor can sign in with GitHub, find any repository available through their granted access, choose where its project work is saved, and create one SDD Orchestrator project linked to that repository without modifying it or starting an AI agent.

## Users

- Business analysts, product owners, and product managers organizing specification work.
- Developers and technical contributors linking repositories to the SDD workflow.

## Primary Workflow

1. SDD Orchestrator evaluates whether the current client has a valid protected GitHub-backed application session.
2. A valid session restores the personal workspace and opens the project catalog without showing the entry surface or requiring GitHub authentication again.
3. Without a valid session, the entry surface presents `Login with GitHub` and `Work without GitHub` as distinct primary actions.
4. The user selects `Login with GitHub` and completes GitHub authentication.
5. SDD Orchestrator creates or restores the user's personal workspace and protected session.
6. When the restored workspace already contains projects, the product opens its project catalog and exposes an `Add project` action instead of forcing repository selection.
7. When the restored workspace is empty, or the user selects `Add project`, the product checks whether `Orchestra-workflow` has an installation accessible to the authenticated user.
8. When no accessible installation exists, the product shows a dedicated `Grant repository access` screen with a `Continue to GitHub` action that opens the public GitHub App installation flow.
9. When GitHub reports that organization approval is pending, the grant screen shows `Waiting for organization approval` and provides `Check again` without creating a project or repository connection.
10. After GitHub returns or the product confirms a valid repository-access grant, the repository picker opens directly, loads every repository returned under the granted access, and supports search.
11. The user selects one repository and continues to a dedicated storage step using the shared wording and behavior from `specs/05-project-storage-lifecycle/`.
12. If `On this device` requires setup, the product guides device setup and returns to the same storage step with the selected repository and current onboarding state preserved.
13. The user explicitly chooses `On this device` or `In my SDD Orchestrator account` after reviewing what the choice affects.
14. The product derives the default project name from the repository name, allocates the lowest available numeric suffix when needed, and lets the user review and edit the name before final confirmation.
15. The user confirms the repository, project name, and storage choice.
16. The project, repository connection, and selected storage mode are created atomically under the personal workspace.
17. After creation succeeds, the product opens the new project's dashboard and shows its repository, storage mode, and connection status without changing repository content or starting an agent.

## In Scope

- The GitHub action on the two-action entry surface.
- Session-aware entry routing, GitHub authentication, session restoration, and sign-out.
- Personal workspace creation and restoration.
- Existing-workspace catalog routing and the `Add project` handoff to repository selection.
- The GitHub App repository-access check, dedicated grant screen, GitHub installation handoff, and validated return to repository selection.
- Retrieval, search, loading, empty, and failure states for every repository returned by GitHub under the granted access.
- Explicit selection of one GitHub repository.
- The shared plain-language project-data storage choice before final confirmation.
- Responsive light and dark onboarding presentation, keyboard operation, visible focus, and non-color status cues.
- Atomic project and repository-connection creation.
- Direct post-creation handoff to the new project's dashboard.
- One repository per project and one project per repository within a personal workspace.
- Repository-derived default names, case-insensitive workspace uniqueness, lowest-available numeric suffixes, and editing during or after onboarding.
- Persistent project visibility with a disconnected status when GitHub access is lost.
- Actionable errors for non-technical users.
- GDPR data contracts and security controls for identity, session, repository, project, and operational-security data introduced by this feature.

## Out of Scope

- The `Work without GitHub` workflow and local worker behavior, defined in `specs/02-local-project-onboarding/`.
- Passwordless hosted access, defined in `specs/03-hosted-passwordless-access/`.
- Automatic identity merging, conflict recovery, unlinking, and re-linking, defined in `specs/04-github-identity-linking/`.
- Project storage migration, retention, resynchronization, and analytics lifecycle, defined in `specs/05-project-storage-lifecycle/`.
- Project export and import, defined in `specs/06-project-portability/`.
- Collaboration workflows, AI-provider setup, specification workflows, and agent execution.
- Linking multiple repositories to one project or creating multiple projects for the same repository in one personal workspace.
- Product analytics for this onboarding slice.

## Business Rules

- The entry surface must show exactly two primary actions: `Login with GitHub` and `Work without GitHub`.
- The entry surface is the unauthenticated chooser and must not be shown when the current client has a valid protected GitHub-backed application session.
- A valid GitHub-backed application session must restore the personal workspace and route directly to the project catalog without requiring GitHub authentication again.
- An invalid, expired, or revoked session must not expose the project catalog and must return the client to the entry surface.
- Signing out must end the protected hosted session and return the client to the entry surface without deleting on-device project data.
- The first usable release must not be made available until both `Login with GitHub` and `Work without GitHub` can complete their specified onboarding paths.
- Neither primary action may be disabled, hidden, presented as a placeholder, or lead to a dead or incomplete path in that release.
- The onboarding experience must support light and dark themes, use the operating-system preference on first load, and provide a manual theme control.
- A manual theme choice must be stored only on the current device and must not be uploaded, synchronized, or attached to a hosted identity or workspace.
- When the current device has no stored manual choice, the product must use its current operating-system theme preference.
- Signing in or out must not replace the current device's manual theme choice.
- Theme, connection, warning, and failure meaning must never depend on color alone; meaningful states require text and an icon or equivalent non-color cue.
- GitHub sign-in must restore one stable personal workspace for the authenticated GitHub identity.
- GitHub authorization and repository-access consent must identify the registered public GitHub App as `Orchestra-workflow` and use its public installation page at `https://github.com/apps/orchestra-workflow`.
- For this onboarding scope, `Orchestra-workflow` is configured with the GitHub repository permission `Metadata: read-only`; no other repository permission is approved or assumed.
- GitHub onboarding must not require repository write access or modify repository content, configuration, or settings.
- Fresh GitHub authentication that restores a non-empty workspace must open the project catalog rather than force the user to create another project.
- Fresh GitHub authentication that creates or restores an empty workspace must continue to the repository-access check without requiring another application action.
- The project catalog must expose an `Add project` action that opens the repository-access check without creating or linking anything by itself.
- When the authenticated user has no accessible `Orchestra-workflow` installation, the product must show a dedicated `Grant repository access` screen before repository selection.
- The grant screen must explain that GitHub controls repository access and provide a `Continue to GitHub` action to the public `Orchestra-workflow` installation flow.
- When organization approval is pending, the grant screen must show `Waiting for organization approval`, provide `Check again`, and prevent project or repository-connection creation.
- `Check again` must re-evaluate the current GitHub access state and must not treat a pending request as granted access.
- After GitHub returns a valid grant associated with the authenticated user, the product must open the repository picker directly without requiring the user to restart onboarding.
- The repository picker must show every repository returned by GitHub under the user's granted access; visibility must not link a repository automatically.
- The repository picker must use an accessible single-selection list that supports keyboard selection and shows the repository owner, name, visibility, and organization when that approved metadata is available.
- Search with no matches, no authorized repositories, retrieval failure, and organization-restricted access are distinct states with relevant recovery actions.
- After repository selection and before final confirmation, onboarding must show the storage-selection step defined by `specs/05-project-storage-lifecycle/`, including `Where should your project work be saved?`, its plain-language choices, and the explanation that the linked repository stays where it is.
- The storage step must keep device and hosted choices visible when a prerequisite is missing, explain why an unavailable mode cannot yet be selected, and provide its relevant setup action.
- Device setup must preserve the selected GitHub repository and current onboarding state, then return to the same storage step after success, cancellation, or failure.
- Successful device setup must refresh availability without selecting `On this device`; canceled or failed setup must leave it unavailable, preserve the repository selection, and create no project.
- Project creation must not continue until the user explicitly selects one storage mode, and the final confirmation must show the selected mode.
- A project is created only after the user explicitly selects and confirms a repository.
- A project must be linked to exactly one repository.
- A repository can be linked to at most one project in the same personal workspace.
- Different users may link the same repository independently in their separate personal workspaces.
- The default project name is the repository name.
- Default-name derivation must preserve the repository name's display spelling and case; case-insensitive comparison is used only to enforce uniqueness.
- A project name is human-facing display text, not a slug, URL segment, repository identifier, filesystem path, or database key.
- Project names may contain spaces and Unicode characters and must not be converted to lowercase, transliterated, or rewritten as slugs for display.
- Project names are unique by case-insensitive comparison within one personal workspace, not globally.
- When the default name is occupied, the product appends the lowest available positive integer suffix: `-1`, then `-2`, and so on.
- A user may edit a project name during onboarding and at any later time; every saved name follows the same uniqueness rule.
- Project identity and repository identity remain stable when the display name changes.
- Repository uniqueness and project-name uniqueness are independent rules; renaming cannot allow a duplicate repository link.
- Project creation and repository linking must commit atomically or leave no partial project or connection.
- Successful project creation must open the new project's dashboard rather than return to the entry surface, repository picker, or project catalog.
- The new project's dashboard must show the linked repository, selected storage mode, and current connection status.
- Linking must not modify repository files, branches, settings, issues, or pull requests.
- When GitHub access is lost, the project remains visible and its connection becomes disconnected.
- Authentication credentials, repository credentials, and session secrets must never be displayed after acceptance or exposed in client payloads, logs, analytics, or project data.
- The operator of each hosted SDD Orchestrator deployment is the controller for the identity, session, workspace, selected repository metadata, project, and operational-security data that deployment receives.
- Core personal data may be processed only as necessary to provide the user-requested hosted service; minimum operational-security data may be processed only for the documented service-security purpose and legitimate-interest assessment.
- GitHub governs its own platform processing. Hosting, database, backup, and logging services used on behalf of a hosted deployment must be recorded and governed as processors where applicable.
- Applicable access, correction, erasure, restriction, objection, and portability requests must be handled through a verified workflow without requiring a self-service screen in this slice.
- This slice must not emit or retain product-analytics events, identifiers, or onboarding metrics.
- Minimum operational and security logs are governed personal data, not analytics, and must follow the approved processing and retention contract.
- Implementation and local verification may proceed under this approved data contract without selecting a production hosting provider.
- A public hosted deployment must not be released until its controller identity and contact, processor list, hosting regions, transfer safeguards, privacy notice, incident path, retention enforcement, and required privacy or legal review are recorded.

## Acceptance Criteria

- [AC-01] Given the current client has no valid protected session, when SDD Orchestrator opens, then the entry surface shows `Login with GitHub` and `Work without GitHub` as distinct primary actions.
- [AC-02] Given a candidate first usable release, when either primary action is selected, then its specified onboarding path is available through completion without a disabled, placeholder, or dead action.
- [AC-03] Given the entry or onboarding flow is displayed, when the user changes between light and dark themes, then the current screen remains usable with the same actions, content, status meaning, focus visibility, and layout stability.
- [AC-04] Given the current device has no stored manual theme choice, when SDD Orchestrator opens, then it uses the current operating-system theme preference.
- [AC-05] Given the user manually selects a theme, when SDD Orchestrator is reopened on the same device, then that local choice is restored without reading or writing a hosted theme preference.
- [AC-06] Given the same user opens SDD Orchestrator on another device with no stored choice, when the application loads, then the other device uses its own operating-system preference rather than synchronizing the first device's choice.
- [AC-07] Given the user signs in or out, when the entry or protected surface is shown, then the current device's manual theme choice remains unchanged.
- [AC-08] Given the current client has a valid GitHub-backed application session, when SDD Orchestrator opens, then the personal workspace is restored and the project catalog is shown without rendering the entry surface or requiring GitHub authentication again.
- [AC-09] Given the current session is invalid, expired, or revoked, when a protected route is opened, then no project catalog data is exposed and the client returns to the entry surface.
- [AC-10] Given a GitHub-authenticated user signs out, when session termination succeeds, then the entry surface is shown and on-device project data remains unchanged.
- [AC-11] Given GitHub authentication succeeds, when onboarding continues, then the user's stable personal workspace is created or restored without exposing credentials.
- [AC-12] Given `Orchestra-workflow` requests repository access for onboarding, when its approved permission scope is inspected, then it uses `Metadata: read-only` and no repository write permission.
- [AC-13] Given fresh GitHub authentication restores a workspace with existing projects, when routing completes, then the project catalog is shown with an `Add project` action and repository selection is not forced.
- [AC-14] Given fresh GitHub authentication creates or restores an empty workspace, when routing completes, then the repository-access check runs without another application action.
- [AC-15] Given the user selects `Add project` from the project catalog, when the action opens, then the repository-access check runs and no project or repository connection has been created yet.
- [AC-16] Given the authenticated user has no accessible `Orchestra-workflow` installation, when the repository-access check completes, then a dedicated `Grant repository access` screen is shown with a `Continue to GitHub` action and no repository picker or partial project is exposed.
- [AC-17] Given the grant screen is shown, when the user selects `Continue to GitHub`, then the public `Orchestra-workflow` installation flow opens.
- [AC-18] Given an organization installation request is awaiting approval, when the user returns or selects `Check again`, then the grant screen shows `Waiting for organization approval` and no repository picker, project, or repository connection is exposed until access is confirmed.
- [AC-19] Given a repository-access grant associated with the authenticated user becomes valid through a GitHub return or `Check again`, when the grant is accepted, then the repository picker opens directly with the newly granted repositories available.
- [AC-20] Given GitHub returns accessible personal, private, or organization repositories, when the picker loads, then every returned repository is available and searchable without requiring a URL.
- [AC-21] Given the repository picker has focus, when the user navigates and selects with a keyboard, then exactly one repository can be selected and confirmed without pointer input.
- [AC-22] Given search has no matches, GitHub returns no repositories, retrieval fails, or organization policy restricts access, when the state is shown, then it is distinguishable from the other states and presents an appropriate recovery action.
- [AC-23] Given repository retrieval is empty or fails, when the request ends, then the user sees an actionable state and no partial project is created.
- [AC-24] Given the user continues with a repository, when the storage step opens, then it asks `Where should your project work be saved?`, explains what project work includes and that the linked repository stays where it is, and presents `On this device` and `In my SDD Orchestrator account`.
- [AC-25] Given either storage mode is unavailable, when the storage step is shown, then both modes remain visible and the unavailable mode explains its missing prerequisite with a setup action that does not select the mode or create a project.
- [AC-26] Given `On this device` requires setup, when device setup succeeds, is canceled, or fails, then onboarding returns to the same storage step with the selected repository preserved; success refreshes availability without selecting a mode, while cancellation or failure leaves the mode unavailable and creates no project.
- [AC-27] Given no storage mode has been selected, when the user attempts to continue, then final confirmation and project creation remain unavailable without a silent default.
- [AC-28] Given a storage mode is selected, when final confirmation opens, then the selected repository, project name, and storage mode are visible for review.
- [AC-29] Given an unlinked repository is confirmed, when creation succeeds, then exactly one project and one repository connection are created atomically.
- [AC-30] Given project creation commits successfully, when onboarding completes, then the new project's dashboard opens and shows the linked repository, selected storage mode, and current connection status.
- [AC-31] Given a repository named `example` and no conflicting project name, when it is linked, then the default project name is `example`.
- [AC-32] Given a repository named `Café Roadmap` and no conflicting project name, when confirmation opens, then the default project name remains `Café Roadmap` without slug conversion or character loss.
- [AC-33] Given projects named `example` and `Example-1`, when another repository named `example` is linked, then the lowest available default is `example-2`.
- [AC-34] Given two separate personal workspaces, when each user links the same repository or uses the same project name, then each workspace enforces uniqueness independently.
- [AC-35] Given a project already links the selected repository, when the same workspace tries to link it again, then creation is blocked and the existing project is identified.
- [AC-36] Given the user edits a project name, when the name is saved, then case-insensitive uniqueness is enforced without changing project or repository identity.
- [AC-37] Given repository access is lost, when the project is shown, then it remains visible with a disconnected status and no stale credential is exposed.
- [AC-38] Given repository access later returns, when the connection is revalidated, then the same project can return to connected.
- [AC-39] Given onboarding completes, when repository state is inspected, then repository content and settings are unchanged and no AI agent has started.
- [AC-40] Given any onboarding operation fails, when it ends, then no duplicate workspace, project, or repository connection exists.
- [AC-41] Given any Slice 01 workflow is used, when stored and transmitted records are inspected, then no product-analytics event, identifier, or onboarding metric exists.
- [AC-42] Given a verified rights request applies to Slice 01 data, when the operator handles it, then applicable access, correction, export, restriction, objection, or deletion reaches the governed active and retained copies under the approved lifecycle.
- [AC-43] Given a public hosted deployment is missing any required deployment privacy record or review, when release readiness is evaluated, then that deployment remains blocked without blocking implementation or local verification.

## Open Questions

- None.
