# Hosted Session Project Access

## Status

Draft

## Outcome

A person whose only sign-in is the passwordless email link can see the projects they own and open one. Today they can create a hosted project and are then sent back to the entry page, because every owner screen requires the application session that only GitHub sign-in issues. Their project exists, it is connected to their Mac, and they cannot reach it.

## Users

- Passwordless owner: a person who signs in with an email link and owns hosted projects. They may have no GitHub account at all, which is the case `specs/03-hosted-passwordless-access/` exists to serve.
- GitHub owner: a person who signs in with GitHub. They are named only because their access must not change.

## In Scope

- The project list showing the projects a passwordless owner's account owns.
- Opening one of those projects and seeing its dashboard.
- Reaching the project list from `/` in a later session, without remembering a link.
- Keeping every screen scoped to the acting account, so one sign-in method never widens what a person can read.
- The project dashboard telling the truth about a repository that is on a Mac rather than on GitHub.
- The project dashboard's own controls working for whichever sign-in the person used.

## Out of Scope

- Every other screen behind the application session: project export and backup, AI connections, repository kits, and the GitHub onboarding steps. They stay GitHub-only for now.
- Composing on-device projects into the same list, which `specs/03-hosted-passwordless-access/` defers as its AC-20 to AC-23 and which needs the migration rules `specs/05-project-storage-lifecycle/` still defers.
- Creating a project from the list. A passwordless owner creates one through the local repository flow that `specs/44-hosted-local-repository-projects/` delivers.
- Sign-in, session lifetime, revocation, and recovery, all owned by `specs/03-hosted-passwordless-access/`.
- Merging a passwordless identity with a GitHub one, owned by `specs/04-github-identity-linking/`.
- What a project can then do, including features, readiness, and runs.

## Primary Workflow

1. The person finishes creating a hosted project from a local repository and is sent to that project.
2. The project's dashboard opens on their hosted session. It shows the repository, the hosted storage mode, and that their Mac is connected.
3. Later they open `/` in the same browser. Their hosted session is still valid, so they go to their project list.
4. The list shows the projects their account owns. They open one and reach the same dashboard.
5. If the hosted session has expired or been revoked, they are asked to sign in again and no project data is shown.

## Business Rules

- A person reaches a project screen through either sign-in method. Which method they used never changes what they may read.
- Every screen resolves the acting account and its workspace from the session that is actually present, and shows only that workspace's projects. A project in another workspace is not found rather than refused, so nothing about it is disclosed.
- A passwordless owner sees the same project list and the same project dashboard a GitHub owner sees. Controls that need GitHub, such as repository access checks, are not offered when the acting account has no GitHub identity.
- An expired, revoked, or absent session reaches no project screen and no project data.
- Being asked to sign in again says only that, because the product does not know which sign-in the person meant to use. It does not name one method as the missing one.
- A project whose repository is on a Mac is never described as a GitHub repository. Its screen does not claim GitHub access was lost, and it does not leave a repository label empty.
- The screens named out of scope keep requiring the application session, and a passwordless owner is told what is missing rather than shown a broken screen.

## Acceptance Criteria

- [AC-01] Given a person signed in only through the passwordless email link owns a hosted project, when they open that project's address, then its dashboard opens and shows the project, its storage mode, and its machine connection state.
- [AC-02] Given that person opens the project list, when the list renders, then it shows the projects their own account owns and no others.
- [AC-03] Given that person opens `/` with a valid hosted session, when the page resolves, then they reach their project list instead of the entry chooser.
- [AC-04] Given the acting account has no GitHub identity, when the project list renders, then no control that requires GitHub is offered and the list is otherwise complete.
- [AC-05] Given a person's hosted session has expired or been revoked, when they open a project screen or the project list, then they are asked to sign in again and no project, repository, or workspace data is shown.
- [AC-06] Given a person signed in with GitHub, when they use the project list and a project dashboard, then their access and what they see are unchanged.
- [AC-07] Given a person holds a session for one account, when they open a project owned by another account, then the project is not found and nothing about it is disclosed.
- [AC-08] Given a hosted project whose repository is on the person's Mac, when its dashboard renders, then it says where the repository is and whether that Mac is reachable, and it makes no claim about GitHub access.
- [AC-09] Given the acting account has no GitHub identity, when the project dashboard renders, then its sign-out ends the session that person actually holds, and no control on it leads to a screen that session cannot open.

## Open Questions

- None.
