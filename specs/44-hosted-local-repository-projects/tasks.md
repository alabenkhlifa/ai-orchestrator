# Hosted Projects From A Local Repository Tasks

## Status

Not Started

## Active Slice

Let a signed-in person choose `In my SDD Orchestrator account` for a local repository and get a hosted project that is already connected to the worker which proved that repository: the identity resolved from the attempt, the project and its connection and storage mode and worker binding committed together, a refusal leaving nothing behind, and the hosted dashboard showing the repository, the storage mode, and the live connection.

## Cross-Specification Dependencies

Requires:

- `capability:hosted-local-repository-connection` — provider `specs/37-hosted-local-repository-connection#Task 6` — required before `Task 2`.
- `capability:worker-repository-selection` — provider `specs/40-worker-repository-selection#Task 9` — required before `Task 1`.

Provides:

- `capability:hosted-local-repository-projects` — ready after `Task 4`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- `Projects.register_project/3` accepting a device-origin attempt whose storage mode is hosted, and resolving the hosted workspace the attempt proved.
- The worker binding written in the same transaction as the project, its repository connection, and its storage mode.
- The hosted branch of `LocalOnboardingLive`'s confirmed attempt, replacing the not-yet-available flash with creation, its refusals, and the routing to the hosted dashboard.
- The per-account refusal when a hosted project for that repository already exists.

Excluded:

- The storage step, its availability rules, and its sign-in handoff, owned by `specs/05-project-storage-lifecycle/`.
- Folder selection and repository proving, owned by `specs/40-worker-repository-selection/` and `specs/02-local-project-onboarding/`.
- Reconnecting, disconnecting, and moving a hosted project between Macs, owned by `specs/37-hosted-local-repository-connection/`.
- The accountless device branch and the device store, which stay unchanged.
- The project dashboard's presentation, which already renders this project shape.

Deferred after this slice:

- Moving a project between storage modes in either direction, which `specs/05-project-storage-lifecycle/` defers to its own child specification.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Create a hosted project from a device-origin attempt.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give the hosted choice somewhere to commit, using the writer the GitHub path already uses.
  - Owned surfaces: `Projects.register_project/3` accepting a device-origin attempt whose storage mode is hosted, the hosted workspace resolved from the attempt's `hosted_prerequisite_workspace_id`, the refusal for an attempt that never proved one, and the `repository_provider: "local"` project carrying the portable identity as its canonical repository id.
  - Owns: AC-01, entity:HostedLocalRepositoryProject
  - Proof: Focused tests cover a device-origin attempt with a proven hosted workspace producing one hosted local-provider project with one authoritative storage mode and its repository connection, an attempt with no proven workspace refused with nothing created, and a hosted-origin attempt behaving exactly as before.

- [ ] Task 2 — Bind the proving worker in the same commit.
  - Size: Exception — the project, its connection, its storage mode, and its binding are one invariant. Splitting them would leave a committed hosted project with no worker, which is the unconnected state this slice exists to avoid and which no screen could then resolve for a repository the worker has already stopped offering.
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Land the person on a project that can already reach a run.
  - Owned surfaces: `HostedLocalRepositoryBindings.put_validated_binding/6` called inside the creation transaction with the worker recorded in the attempt's selection, and the refusal when that worker is no longer usable.
  - Owns: AC-02, AC-03
  - Proof: Focused tests cover a created project bound to the worker that proved the repository, a worker that is no longer usable refusing the whole creation with no project, connection, storage mode, or binding left behind, and a different worker never being substituted.

- [ ] Task 3 — Replace the not-yet-available refusal with creation.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Make the choice the step already offers actually work.
  - Owned surfaces: `LocalOnboardingLive`'s `%{storage_mode: "hosted"}` clause creating the project, one sentence per refusal reason with the choice still available, routing to the hosted project's dashboard on success, and the per-account refusal naming the existing project when one already holds that repository.
  - Owns: AC-05
  - Proof: Focused LiveView tests cover a confirmed hosted attempt creating the project and routing to its dashboard, each refusal reason rendering its sentence with nothing created and the choice still offered, and a second hosted attempt for the same repository refused with a link to the existing project.

- [ ] Task 4 — Prove the click path, coexistence, and that no path leaks.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Show the whole path works for a person and leaves the device project alone, and establish `capability:hosted-local-repository-projects`.
  - Owned surfaces: The integration scenario from folder selection through the hosted choice to a connected hosted project, the coexistence check against a device project for the same repository, and the log and record review for a path, remote, history, or file name, which together establish `capability:hosted-local-repository-projects`.
  - Owns: AC-04, AC-06
  - Proof: An integration scenario drives selection, the hosted choice, and confirmation to a connected hosted project; a device project for the same repository is shown unchanged beside it; and a review of the stored records and captured logs finds only the portable identity.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Local onboarding's accountless device branch passes unchanged.
- [ ] GitHub hosted onboarding passes unchanged through the same writer.
- [ ] Hosted local-repository connection, reconnection, and disconnection pass unchanged.
- [ ] The log and record review finds no repository path, remote, history, file name, or source content.
- [ ] Build, formatting, lint, static checks, and logs review pass.
- [ ] Required browser scenarios pass.
- [ ] Product proof: one click path from `/` in a real browser, worker stand-in off, no `/_e2e` seeding, against the paired worker app: sign in, choose a local repository, choose `In my SDD Orchestrator account`, confirm, and see the hosted project's dashboard show the repository, the hosted storage mode, and the worker connected. Recorded in `progress.md`.

## Blocked Decisions

- None.

## Release Gate

- None.

## Progress Log

See [progress.md](progress.md).
