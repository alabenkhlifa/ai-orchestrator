# Hosted Session Project Access Design

## Context

The application has two independent sign-ins. `SddOrchestratorWeb.UserAuth` resolves `:current_account` from an opaque session token that only `AuthController` issues after GitHub sign-in. `SddOrchestratorWeb.HostedUserAuth` resolves `:current_hosted_access` from a separate cookie that only the passwordless magic link issues. Neither reads the other.

The router splits the screens along that line. `live_session :authenticated` requires the application session and holds `/projects` and `/projects/:id/overview`. `live_session :participation` mounts both hooks and holds `/projects/:id/features` and the invitation screens, which is why an invited participant can work. `live_session :notifications` mounts both because it needs an application account and a nilable hosted identity together, and its own moduledoc records that neither existing block was the right combination.

Passwordless access was built as the participant door. `specs/03-hosted-passwordless-access/` deferred its combined-catalog criteria AC-20 to AC-23, so no screen ever had to list a passwordless owner's own projects. That was consistent while a passwordless person could only be invited to a project. `specs/44-hosted-local-repository-projects/` changed it: a passwordless person can now create a project, and `ProjectLandingController` sends them to `/projects/:id/overview`, which their session cannot pass. They land on `/`. Confirmed by running it.

The pieces needed are already present. A hosted session resolves a full `%Account{}` and its `%PersonalWorkspace{}`, because `HostedIdentity` belongs to an account and `HostedAccess.Sessions` loads both. So the acting identity a screen needs is available from either session, and only the resolution is missing.

Both screens are close to ready. `ProjectsLive` and `ProjectDashboardLive` each read `socket.assigns.current_account`, derive the workspace with `Accounts.get_or_create_personal_workspace/1`, and scope every query to that workspace. `Connections.project/4` takes the account only to revalidate GitHub repository connections, and short-circuits on an empty connection list, which is exactly the shape of a hosted local-repository project. `ProjectsLive` also reads `Accounts.get_github_identity/1`, which answers `nil` for an account with no GitHub identity.

## Proposed Approach

Resolve the acting account and workspace from whichever session is present, and leave every authorization decision where it already is.

- One `on_mount` hook owns the rule. It assigns the acting account and personal workspace from the application session when there is one, from the hosted session otherwise, and halts to the entry surface with the existing hosted-access notice when there is neither. The screens read the resolved assigns instead of `:current_account` directly, so neither screen decides which sign-in it trusts.
- `/projects` and `/projects/:id/overview` move to a live session using that hook. Every other route in `live_session :authenticated` stays exactly where it is, so the screens this slice does not name keep requiring the application session.
- `/` resolves a hosted session too, so a valid one reaches the project list rather than the entry chooser, the same way a valid application session already does.
- Workspace scoping is unchanged and stays the only authorization. Both screens already query by `workspace_id`, and a project outside the acting workspace already resolves to nothing and routes back, which is what AC-07 requires.
- GitHub-dependent controls read the acting account's GitHub identity, which is already `nil` for a passwordless account. The catalog's `Add project` handoff goes to the repository-access check, which is GitHub-only, so it is offered only when that identity exists.

## Components Affected

- `SddOrchestratorWeb.UserAuth` or a new sibling module: the `on_mount` hook that resolves the acting account and workspace from either session and halts without one.
- `SddOrchestratorWeb.Router`: the live session holding `/projects` and `/projects/:id/overview`, and the hosted resolution on `/`.
- `SddOrchestratorWeb.ProjectsLive`: reading the resolved account and workspace, and offering the GitHub-only handoff only to an account that has GitHub.
- `SddOrchestratorWeb.ProjectDashboardLive`: reading the resolved account and workspace.
- `SddOrchestratorWeb.EntryLive`: sending a valid hosted session to the project list.

## Data and Access Boundaries

- `ActingIdentity`: the account and personal workspace a request acts as, resolved per mount from the application session or the hosted session. It is not stored. It holds no credential and no identity detail beyond what the screen already renders.

Required boundaries:

- The acting workspace comes from the session that is actually present. A screen never reads one session's account and another session's workspace.
- Every project query stays scoped to the acting workspace. Widening the sign-in methods never widens the rows a person can read.
- A screen this slice does not name keeps its application-session requirement.
- An absent, expired, or revoked session renders no project, repository, or workspace data, and the halt discloses nothing about whether a project exists.
- No new personal data is stored, and no log gains an account, email, workspace, or project identifier it does not already carry.

## Interfaces

- One `on_mount` hook answering the acting account and personal workspace, or halting to the entry surface.
- Compatibility that must hold: GitHub sign-in and everything it reaches, the participant screens and their hosted resolution, the notification inbox's combined gate, `ProjectLandingController`'s redirect decision, and the screens that stay application-session only.

## Decisions and Tradeoffs

### One resolution hook, not a second session

- Choice: The hook resolves the acting account from whichever session is present. The passwordless sign-in is not changed to also issue an application session.
- Reason: The application session is the GitHub credential's session, and its token is what `Accounts.valid_access_token/1` and the GitHub screens are built on. Issuing one for an account with no GitHub credential would put a token behind screens that assume it can be refreshed.
- Consequence: Every screen that should serve both doors has to use the hook. A screen that reads `:current_account` directly keeps its application-session behaviour, which is the safe default for the screens this slice leaves alone.

### Workspace scoping stays the only authorization

- Choice: Nothing about who may read a project changes. The hook only decides which account is acting.
- Reason: Both screens already scope every query by `workspace_id` and already resolve a foreign project to nothing. The gap was never authorization; it was that one valid identity could not be seen at all.
- Consequence: A person with both sessions in one browser acts as the application session's account, which is the one the GitHub screens also act as. Two accounts in one browser is `specs/04-github-identity-linking/`'s subject, not this slice's.

### The dashboard drops its GitHub parts for a local repository

- Choice: A hosted project whose repository is on a Mac renders no `Repository` row, no GitHub connection badge, and no access-lost notice. The machine region it already has is what states where the repository is and whether that Mac is reachable.
- Reason: `Connections.to_entry/2` gives such a project `status: :disconnected` because it has no `RepositoryConnection`, so the screen currently prints `GitHub access to this repository was lost.` about a project with no GitHub repository, and renders the `Repository` label with no value. Nothing stores a repository name to print either: the folder name became the project name, and the only other repository value is the portable identity, which is not for reading.
- Consequence: The person reads where their repository lives from one region rather than two, and no second copy of a repository value is stored. A GitHub-backed project keeps every one of those parts exactly as it has them.

### The catalog stays read-and-open for a passwordless owner

- Choice: The list shows and opens projects. `Add project` continues to the GitHub repository-access check and is offered only to an account with a GitHub identity.
- Reason: The passwordless owner's way to make a project is the local repository flow, which `specs/44-hosted-local-repository-projects/` delivers and which starts from `/`, not from the catalog.
- Consequence: A passwordless owner with no projects yet sees an empty list rather than a create action. `ProjectsLive` currently redirects an empty workspace straight into the GitHub check, so that path needs an answer for an account that cannot take it.

## Risks

- `ProjectsLive` sends an empty workspace to the repository-access check on mount. For a passwordless account that is a redirect into a screen it cannot use, so the empty-workspace path has to be handled rather than inherited.
- Moving two routes between live sessions changes their mount hooks. A screen that quietly depended on `:current_account` being an application account, directly or through a component, would change behaviour without failing to compile.
- The GitHub badge, the access-lost notice, and the `Repository` row are driven by the connection entry's status, which the catalog row shares. Hiding them for a local repository must not change what a GitHub-backed project shows.
- The revalidation path takes an account to refresh GitHub tokens. A passwordless account has none, so revalidation must be a no-op for it rather than a failed refresh that marks a connection disconnected.

## Open Questions

- None.
