# Hosted Projects From A Local Repository

## Status

Draft

## Outcome

A signed-in person can connect a Git repository on their Mac and save the project work in their SDD Orchestrator account instead of on the device, and the project is connected to the worker that just proved the repository. Today the storage step offers that choice and then refuses it with `Saving local projects to a hosted account is coming soon.`, so the only project a local repository can produce is an accountless one on the device.

## Users

- Local repository owner: a signed-in person whose code is a Git repository on their Mac and who wants the project work reachable from any device they sign in on. Not assumed to be comfortable with a terminal.
- Project participant: a person the owner later invites. They never take part in creation, and they are named here only because hosted storage is what makes participation possible at all.

## In Scope

- Creating a hosted project from a local repository, in the storage step that already offers the choice.
- Committing the project, its repository connection, its authoritative storage mode, and its worker binding together, so the person lands on a project that is already connected.
- Carrying the portable repository identity the worker generated during selection into the hosted project, so the binding is proved against the repository that was actually chosen.
- Refusing the whole creation when any part fails, leaving no project, no connection, no binding, and an unchanged repository.
- The dashboard the person lands on showing the linked repository, the hosted storage mode, and the live connection state.

## Out of Scope

- The storage step itself, its availability rules, and its sign-in handoff, delivered by `specs/05-project-storage-lifecycle/`.
- Folder selection and repository proving on the worker, delivered by `specs/40-worker-repository-selection/` and `specs/02-local-project-onboarding/`.
- Reconnecting, disconnecting, or moving an existing hosted project to another Mac, delivered by `specs/37-hosted-local-repository-connection/`.
- Moving a project between storage modes in either direction. `specs/05-project-storage-lifecycle/` defers migration to its own child specification, and this slice creates a new project rather than moving one.
- The accountless on-device path, which stays exactly as it is.
- Anything the hosted project can then do, including features, readiness, and runs.

## Primary Workflow

1. The person opens `Work without GitHub`, and the worker on their Mac opens the folder picker. They choose a Git repository, and the worker proves it and reports the folder name.
2. The storage step asks where the project work should be saved. The person is signed in, so `In my SDD Orchestrator account` is available.
3. They choose it, name the project, and read the first-connection disclosure.
4. They confirm. One project is created in their account, linked to that repository, with the worker that proved it already connected.
5. They land on the project's dashboard, which shows the repository, `In my SDD Orchestrator account`, and that the worker is connected.
6. If anything in that step fails, nothing is created, the repository is untouched, and the reason is shown with the choice still available.

## Business Rules

- A hosted project from a local repository carries the portable repository identity the worker generated during selection. No path, remote, history, or file name is stored with it.
- The project, its repository connection, its authoritative storage mode, and its worker binding commit together or not at all. A person never reaches a half-made project.
- The binding names the worker that proved the repository during this selection. A different worker cannot be substituted, and the binding is never created for a repository the worker did not prove.
- A device project and a hosted project may link to the same repository and stay separate, as `specs/02-local-project-onboarding/` and `specs/05-project-storage-lifecycle/` already require. Creating one never merges, migrates, reassigns, uploads, deletes, or changes the storage mode of the other.
- Hosted storage requires a signed-in identity. Without one the choice stays unavailable and explains what is missing, which `specs/05-project-storage-lifecycle/` already defines.
- Creation is refused when the same account already holds a hosted project for that repository, and the person is pointed at the project they already have.
- The repository is never written to, and no repository source leaves the Mac.

## Acceptance Criteria

- [AC-01] Given a signed-in person has selected a local repository and chooses `In my SDD Orchestrator account`, when they confirm, then one hosted project exists in their account, linked to that repository, with exactly one authoritative storage mode.
- [AC-02] Given that creation succeeds, when the project is inspected, then it is bound to the worker that proved the repository during this selection, and the project's dashboard shows the repository, the hosted storage mode, and the worker as connected.
- [AC-03] Given any part of the creation fails, when the operation ends, then no project, repository connection, storage mode, or worker binding remains, the repository is unchanged, and the storage choice is still available with the reason shown.
- [AC-04] Given the person already has a device project for the same repository, when they create a hosted one, then both exist as separate projects with their own storage mode, and neither is merged, migrated, or changed.
- [AC-05] Given the account already holds a hosted project for that repository, when the person tries to create another, then creation is refused and they are pointed at the project they already have.
- [AC-06] Given the hosted project's stored records and logs are inspected, when the review runs, then no repository path, remote, history, file name, or source content is present, and the repository identity is the portable value the worker generated.

## Open Questions

- None.
