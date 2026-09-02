# Hosted Session Project Access Tasks

## Status

In Progress

## Active Slice

Let a person signed in only through the passwordless email link reach the projects their account owns: one hook resolving the acting account and workspace from whichever session is present, the project dashboard and the project list served through it, `/` sending a valid hosted session to that list, and nothing else widened.

## Cross-Specification Dependencies

Requires:

- `capability:hosted-local-repository-projects` — provider `specs/44-hosted-local-repository-projects#Task 4` — required before `Task 5`.

Provides:

- `capability:hosted-session-project-access` — ready after `Task 5`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One `on_mount` hook resolving the acting account and personal workspace from the application session or the hosted session, and halting without either.
- `/projects/:id/overview` and `ProjectDashboardLive` served through that hook.
- `/projects` and `ProjectsLive` served through that hook, including its empty-workspace path and its GitHub-only handoff.
- `/` sending a valid hosted session to the project list.
- The notice a person reads when a project screen turns them away.
- The project dashboard's presentation for a project whose repository is on a Mac.

Excluded:

- Every other route in `live_session :authenticated`: project export and backup, AI connections, repository kits, and the GitHub onboarding steps. They keep requiring the application session.
- Sign-in, session lifetime, revocation, and recovery, owned by `specs/03-hosted-passwordless-access/`.
- Merging a passwordless identity with a GitHub one, owned by `specs/04-github-identity-linking/`.
- The participant screens and the notification inbox, which already resolve both sessions.
- Creating a project, owned by `specs/44-hosted-local-repository-projects/` and `specs/01-github-project-onboarding/`.

Deferred after this slice:

- Composing on-device projects into the same list, which `specs/03-hosted-passwordless-access/` defers as its AC-20 to AC-23 and which needs the migration rules `specs/05-project-storage-lifecycle/` still defers.
- Opening the remaining owner screens on a hosted session. Each carries its own authorization and data questions.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Resolve the acting identity from whichever session is present.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give both screens one owned answer to which account is acting, so neither decides for itself which sign-in it trusts.
  - Owned surfaces: The `on_mount` hook assigning the acting account and personal workspace, its resolution order when both sessions exist, and its halt to the entry surface with the existing hosted-access notice when neither does.
  - Owns: entity:ActingIdentity
  - Proof: Focused tests cover an application session resolving its own account and workspace, a hosted session resolving the account behind its hosted identity and that account's workspace, both sessions together resolving the application session's account, and no session halting to the entry surface with nothing assigned.
  - Delivered: `SddOrchestratorWeb.ActingIdentity` assigns `:acting_account` and `:acting_workspace`. Each credential is still read through the module that owns it.

- [x] Task 2 — Open a project on a hosted session.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let the person who just created a project actually reach it, which is the outcome this slice exists for.
  - Owned surfaces: `/projects/:id/overview`'s live session, `ProjectDashboardLive` reading the resolved account and workspace instead of `:current_account`, and the connection revalidation treated as a no-op for an acting account with no GitHub credential.
  - Owns: AC-01, AC-07
  - Proof: Focused LiveView tests cover a hosted-session owner opening their own hosted local-repository project and seeing the repository, the storage mode, and the connection state; the same project opened on an application session unchanged; and a project in another workspace resolving to not found on either session with nothing disclosed.
  - Delivered: `/projects/:id/overview` moved to `live_session :project_access`, and the dashboard reads the acting account and workspace. Revalidation was proven a no-op for a local-repository project rather than assumed.

- [x] Task 3 — List the projects the acting account owns.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Give the person a way back to their project that does not depend on remembering a link.
  - Owned surfaces: `/projects`'s live session, `ProjectsLive` reading the resolved account and workspace, its header controls and sign-out for an account with no GitHub identity, its empty-workspace path and empty state for an account that cannot take the GitHub repository-access check, the `Add project` handoff offered and accepted only for an account that has a GitHub identity, and the catalog entry's own record of whether a project has a repository connection.
  - Owns: AC-02, AC-04
  - Proof: Focused LiveView tests cover a hosted-session owner seeing their own projects and no others, an account with no GitHub identity seeing no GitHub-only control and no redirect into the repository-access check, an empty hosted workspace rendering rather than redirecting, and a GitHub account's list and controls unchanged.
  - Delivered: `/projects` moved to `live_session :project_access`, and the row's GitHub badge and recheck are keyed on the entry having a repository connection, the same rule `Task 6` applies on the dashboard.

- [x] Task 4 — Send a valid hosted session from the entry page to the list.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Make the list reachable in a later session without a remembered address.
  - Owned surfaces: `/`'s hosted-session resolution and the redirect to the project list, and the notice a person reads when a project screen turns them away, which must not name one sign-in method as the missing one. The entry chooser itself and the notices that belong to the hosted-access flow stay unchanged.
  - Owns: AC-03
  - Proof: Focused tests cover a valid hosted session at `/` reaching the project list, an application session still reaching it, no session still rendering the entry chooser, a project screen turning a session-less person away with a notice that names no sign-in method, and the hosted-access flow's own notices unchanged.
  - Delivered: `/` resolves a hosted session after the application one, and a project screen turns a person away to `/?project_access=required` reading `Sign in to open your projects.` The hosted-access marker and its sentence are unchanged.

- [x] Task 6 — Tell the truth about a repository that is on a Mac.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Stop the screen a passwordless owner lands on from describing a GitHub repository the project does not have.
  - Owned surfaces: `ProjectDashboardLive`'s `Repository` row, its GitHub connection badge, and its access-lost notice, each rendered only for a project that has a repository connection, leaving the machine region as the one place that states where a local repository is and whether its Mac is reachable.
  - Owns: AC-08
  - Proof: Focused LiveView tests cover a hosted local-repository project rendering no `Repository` row, no GitHub badge, and no access-lost notice while its machine region still states where the repository is and its reachability, and a GitHub-backed project rendering all three exactly as before in both the connected and the disconnected state.
  - Delivered: the GitHub connection presentation is keyed on the project having a repository connection, so a project with none renders none of it and the machine region is the one place that states where the repository is.

- [ ] Task 5 — Prove the click path and that nothing else widened.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 4, Task 6
  - Purpose: Show a person can create a project and then reach it, and that no other screen changed who may open it.
  - Owned surfaces: The integration scenario from creating a hosted project through to opening it and its list on the same hosted session, the expired and revoked session checks, and the route review proving every excluded screen still requires the application session, which together establish `capability:hosted-session-project-access`.
  - Owns: AC-05, AC-06
  - Proof: An integration scenario creates a hosted project from a local repository on a hosted session and opens both the project and the list; an expired and a revoked session reach neither and render no project data; and every route named excluded still refuses a hosted-only session.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] GitHub sign-in and every screen it reaches pass unchanged.
- [ ] The participant screens and the notification inbox pass unchanged.
- [ ] Every excluded screen still requires the application session.
- [ ] Build, formatting, lint, static checks, and logs review pass.
- [ ] Required browser scenarios pass.
- [ ] Product proof: one click path from `/` in a real browser, worker stand-in off, no `/_e2e` seeding, against the paired worker app: sign in with the email link, create a hosted project from a local repository, land on its dashboard, return to `/`, and open the same project from the list. Recorded in `progress.md`.

## Blocked Decisions

- None.

## Release Gate

- None.

## Progress Log

See [progress.md](progress.md).
