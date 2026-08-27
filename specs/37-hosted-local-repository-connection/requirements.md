# Hosted Local Repository Connection

## Status

Approved

## Outcome

An owner of a hosted project whose code lives in a local Git repository can connect that project to a paired worker on their machine, see whether it is connected, and disconnect or move it to a different machine — without having restored the project from a backup package. Once connected, the project can reach a running development run instead of being refused for having no worker binding.

## Users

- Project owner: a signed-in person who owns a hosted project whose repository is a local Git repository on their own machine. Not assumed to be comfortable with a terminal.
- Local worker: the paired macOS worker app on that machine, which proves the repository without disclosing its path.

## In Scope

- Connecting a hosted local-repository project to a paired worker for the first time, from the project's own page.
- Choosing which paired machine to connect when more than one is available, and skipping that choice when exactly one is.
- Pointing the selected machine at the repository folder through its native folder picker, because the machine cannot find a repository it has never been told about.
- Showing the project's worker connection state on its page: connected, temporarily unavailable, or not connected.
- Disconnecting a connected project, and moving it to a different machine that proves the same repository.
- Actionable refusals when the machine does not hold that repository, when no worker is paired, and when the selected worker is revoked, inactive, or unreachable.

## Out of Scope

- Restoring a hosted project from a backup package and reconnecting it, which `specs/06-project-portability` already delivers through its own restore-gated flow. This slice adds the first-connection path that flow was never reachable for.
- Connecting a project during hosted onboarding, at project creation. Connection happens from the project's own page so an already-created project is never permanently unconnectable.
- Device-authoritative (accountless) local projects, which `specs/02-local-project-onboarding` already connects through its own onboarding flow.
- GitHub-backed hosted projects, whose repository authorization is a separate existing flow.
- Pairing, installing, or updating the worker itself, owned by `specs/02-local-project-onboarding` and `specs/36-local-worker-native-distribution`.
- Anything the run itself does after the worker is connected, owned by `specs/33-local-worker-run-execution`.
- Windows and Linux workers.

## Primary Workflow

1. The owner opens a hosted project whose repository is a local repository and sees that it is not connected to any machine.
2. The owner chooses to connect this machine.
3. When more than one paired worker is available, the owner picks which machine; when exactly one is available, it is used without asking.
4. The selected machine opens its native folder picker and the owner points it at the repository, because a machine that has never held this project cannot locate its repository on its own.
5. The machine computes the repository's identity locally and proves it is the exact one the project already names, without sending a path, remote URL, filename, Git history, or source.
6. On an exact match the project becomes connected and its page shows the connection state.
7. On any failure the project stays exactly as it was and the owner is told what to do next.
8. Later the owner can disconnect the project, or connect a different machine that proves the same repository, from the same page.

## Business Rules

- A project may be connected only by the personal workspace that owns it, and only to a worker that is currently authorized for the owner's device workspace. Neither authority substitutes for the other.
- The owner names the repository folder; the machine never searches for it. The selected path is used only to compute the repository identity on the device and never leaves it.
- Connection requires an exact match between the portable repository identity the project already holds and the identity the selected worker computes. A different repository is never accepted as a substitute, and a legacy workspace-scoped identifier is never accepted as an exact match.
- Only a hosted project whose repository provider is local may be connected this way. A GitHub-backed project is refused as an invalid provider rather than silently bound.
- A project has at most one connected machine. Connecting a different machine replaces the existing binding atomically; a failed replacement leaves the previous binding and the repository untouched.
- No connection attempt, successful or failed, may change repository content, branches, remotes, or Git configuration.
- A refusal must never create, alter, or remove a binding, and must name what the owner can do about it.
- Connecting stores only the routing already approved by `specs/06-project-portability`: the project, the selected worker, and the last successful validation time. No path, credential, remote URL, device label, or repository content is stored or displayed.
- Disconnecting removes the routing only. The project, its specifications, and its repository are unaffected.

## Acceptance Criteria

- [AC-01] Given a hosted local-repository project with no connected machine, when the owner selects a paired machine and points it at the repository folder and it proves the exact repository, then the project becomes connected and its page shows it, with no backup package or restore involved.
- [AC-02] Given the selected machine does not hold that exact repository, or holds it only under a legacy workspace-scoped identifier, when connection is attempted, then it is refused, no binding is created or changed, and no different repository is accepted as a substitute.
- [AC-03] Given the selected worker is not authorized for the owner's device workspace, or is revoked, inactive, or unreachable, or the project is not a local-repository project, when connection is attempted, then it is refused with an actionable reason and no binding is created or changed.
- [AC-04] Given the owner has more than one active paired worker, when they start connecting, then they choose which machine explicitly; given exactly one is available, then it is used without presenting a choice.
- [AC-05] Given no worker is paired on this machine, when the owner opens the connection action, then they are shown the product's shared pairing guidance defined by `specs/02-local-project-onboarding`, using graphical steps and no terminal command.
- [AC-06] Given a hosted local-repository project, when the owner opens its page, then it shows connected, temporarily unavailable, or not connected, without exposing a repository path, device label, or credential.
- [AC-07] Given a connected project, when the owner disconnects it, then the routing is removed, the page shows it as not connected, and the project, its specifications, and its repository are unchanged.
- [AC-08] Given a connected project, when the owner connects a different machine that proves the same repository, then the binding is atomically replaced, the previous machine no longer authorizes the project, and a failed replacement preserves the previous binding.
- [AC-09] Given a hosted local-repository project connected through this flow, when a development run is started for it, then the worker's gateway credential exchange succeeds and the run reaches execution instead of being refused for having no binding.
- [AC-10] Given the owner cancels folder selection, or points the machine at a folder that is not a Git repository, then no connection is attempted, nothing is stored, and the project is unchanged.

## Open Questions

- None.
