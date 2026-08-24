# Hosted Local Repository Connection Tasks

## Status

Not Started

Product readiness: `Approved`, no open product question. Design readiness: `Approved`, no open technical question. Implementation readiness: not started; every required capability is ready. Verification readiness: not started. Release readiness: blocked on this slice's own release gates.

## Active Slice

Let the owner of a hosted local-repository project connect it to a paired machine from the project's own page, see its connection state, disconnect it, or move it to a different machine that proves the same repository — closing the gap that made `specs/36-local-worker-native-distribution` Task 12's gateway credential exchange refuse a real worker.

## Cross-Specification Dependencies

Requires:

- `capability:hosted-local-repository-binding` — provider `specs/06-project-portability#Task 26` — required before `Task 1`.
- `capability:portable-local-repository-identity` — provider `specs/02-local-project-onboarding#Task 9` — required before `Task 7`.
- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 2`.
- `capability:local-worker-run-execution` — provider `specs/33-local-worker-run-execution#Task 12` — required before `Task 6`.

Provides:

- `capability:hosted-local-repository-connection` — ready after `Task 6`.

## Slice Size Gate

- Slice size: Standard

One coherent outcome — an owner connects a hosted local-repository project to a machine and can see, undo, and move that connection — through one verification gate, seven tasks total, and a longest `Depends on:` path of six tasks (`Task 1 → Task 2 → Task 7 → Task 4 → Task 5 → Task 6`). Both are well inside the standard limits, because every durable contract this slice needs already exists in `specs/06-project-portability` and is consumed rather than rebuilt.

## Task Size Gate

- Every task is `Size: Standard`. Each delivers one independently provable outcome, owns at most three acceptance criteria, owns no data entity, and is expected to produce one task-boundary implementation commit.
- Task labels are stable identifiers and tasks are listed in dependency order rather than numeric order: Task 7 was added during implementation preflight and is listed between Tasks 2 and 3, where it executes.
- The first-connection authority gate (Task 1) is separate from the machine picker (Task 2) because one is a domain authorization boundary with its own cross-workspace and invalid-provider proof, and the other is a selection surface whose distinct failure is having no paired worker at all.
- Repository folder selection (Task 7) is separate from machine selection (Task 2) because it crosses the device boundary through the native picker and fails differently — a cancelled selection or a folder that is not a Git repository — from having no machine to choose.
- Connection-state display (Task 3) is separate from the connect action (Task 4) because the display must be correct for a project that was never connected and for one connected by any other means, and it is the surface `specs/36` Task 12 had to bypass entirely.
- Disconnect and machine replacement (Task 5) are separate from first connection (Task 4) because replacement is an atomic transition over an existing binding with its own preserve-on-failure invariant, while first connection creates one where none existed.
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- A first-connection authority gate for a normal hosted local-repository project, composing `specs/06-project-portability`'s existing exact worker validation and binding transaction unchanged.
- Presentation of the owner's active paired workers for explicit selection, collapsing to the single available worker, and a distinct no-worker-paired result.
- Native folder selection on the chosen machine and on-device computation of the repository's portable identity, so the machine is told where the repository is and no path leaves it.
- Worker connection state on the hosted project page: connected, temporarily unavailable, not connected.
- The connect, disconnect, and connect-a-different-machine actions on that page, with actionable refusal copy.
- An end-to-end proof that a project connected this way reaches a running development run.

Excluded:

- `specs/06-project-portability`'s `HostedLocalRepositoryBinding` schema, `LocalRepositoryValidation`, `put_validated_binding/6`, `connection_state/3`, `disconnect/2`, and the restore-gated `HostedLocalRepositoryReconnection` and `RepositoryReconnection.required/2`. This slice consumes them and changes none of them.
- `specs/02-local-project-onboarding`'s pairing, credential custody, worker discovery, compatibility policy, and worker liveness refresh.
- `specs/33-local-worker-run-execution`'s gateway credential exchange, command handling, and run execution.
- `specs/36-local-worker-native-distribution`'s worker packaging, installation, and update flow.
- Connecting during hosted onboarding at project creation.
- Device-authoritative accountless local projects and GitHub-backed hosted projects.
- Windows and Linux workers.

Deferred after this slice:

- Connecting a hosted local-repository project during onboarding, if creation-time connection is later shown to be worth a second entry point.
- Presenting the connected machine's label or last validation time to the owner, which requires a separate minimization decision about what worker data may be disclosed.

Release gates:

- A live proof on a machine other than the development machine that a freshly created hosted local-repository project connects and runs, with no prior developer configuration.
- Accountable privacy and security review of the first-connection authorization surface, covering the same credential-custody and data-minimization boundary `specs/02-local-project-onboarding` and `specs/06-project-portability` already committed to.
- A decision, in that same review, on whether the connect, disconnect, and replace actions need their own minimized operational-security event. This slice deliberately adds none, because `specs/06-project-portability`'s `SecurityLog` list is fixed and scoped to backup and restoration.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 - Add the first-connection authority gate for a hosted local-repository project.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Make a normal hosted local-repository project connectable at all, without weakening the restore gate that currently owns the only path to a binding.
  - Owned surfaces: The first-connection domain action, owning `PersonalWorkspace` authorization, local-provider and already-held-identity preconditions, explicit worker selection handoff, the call into `specs/06-project-portability`'s binding transaction with an identity already proved on the device, and the exact-match, legacy-identifier, invalid-provider, unauthorized-worker, and unreachable-worker refusals.
  - Owns: AC-02, AC-03
  - Proof: Focused tests cover a first connection for a project with no package provenance, cross-workspace denial, invalid provider refusal, exact-match success, mismatch and legacy-identifier refusal, unauthorized, revoked, inactive, and unreachable worker refusal, and that every refusal leaves the binding set and the repository fixture unchanged.

- [ ] Task 2 - Present the owner's paired machines for selection.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let the owner name which machine to connect, and distinguish having no paired worker from a failed connection.
  - Owned surfaces: Active paired-worker listing for the owner's current device workspace, explicit selection contract, the single-available-worker collapse, submit-time confirmation of the chosen worker, and the no-worker-paired result with graphical install and pairing guidance.
  - Owns: AC-04, AC-05
  - Proof: Focused tests cover multiple active workers presented for explicit choice, exactly one used without a choice, a worker paired between listing and submit not silently substituted, an inactive or revoked worker excluded from selection, and the no-worker-paired result carrying no terminal command.

- [ ] Task 7 - Point the selected machine at the repository folder.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Tell the machine where the repository is. A machine that has never held this project cannot locate it, and the restore flow avoided the question only because a restored project's worker already knew.
  - Owned surfaces: The native folder-picker handoff for the selected machine, on-device computation of the repository's portable identity through `specs/02-local-project-onboarding`'s `PortableRepositoryIdentity`, the cancelled-selection and not-a-Git-repository results, and the guarantee that the chosen path never leaves the device.
  - Owns: AC-10
  - Proof: Focused tests cover a selected folder yielding only a portable identity, a cancelled selection attempting no connection, a folder that is not a Git repository refused with an actionable reason, and assertions that no path, remote URL, filename, or Git object reaches the control plane in any result.

- [ ] Task 3 - Show worker connection state on the hosted project page.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Give the owner a real place to see whether the project is connected — the surface `specs/36-local-worker-native-distribution` Task 12 had to bypass because none existed.
  - Owned surfaces: The hosted project page's connection-state region for a local-repository project, its connected, temporarily unavailable, and not-connected presentation, its non-disclosure of path, credential, device label, and compatibility metadata, and its absence for a GitHub-backed project.
  - Owns: AC-06
  - Proof: Focused page tests cover a never-connected project, a connected project, a connected project whose worker heartbeat is stale, and a GitHub-backed project showing no worker connection region, asserting no path, credential, or device label is rendered in any state.

- [ ] Task 4 - Connect this machine from the hosted project page.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3, Task 7
  - Purpose: Deliver the owner-visible first connection end to end, from the project page through selection to a visible connected state.
  - Owned surfaces: The connect action on the hosted project page, its wiring of machine selection, folder selection, and the first-connection gate, its success transition to the connected state, and its actionable refusal copy for mismatch, legacy identifier, unavailable worker, and unauthorized worker.
  - Owns: AC-01
  - Proof: Focused page tests cover a successful connection moving the page to connected, each refusal keeping the page unconnected with actionable copy and no binding, and a repeated submit resolving to the same binding rather than a second one.

- [ ] Task 5 - Disconnect and move the project to a different machine.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Stop a connected project from being stuck on one machine, and let the owner undo the link without touching the project or its repository.
  - Owned surfaces: The disconnect action and its idempotency, the connect-a-different-machine action, the atomic replacement transition, the preserve-the-previous-binding invariant on a failed replacement, and the page's return to a not-connected state after disconnect.
  - Owns: AC-07, AC-08
  - Proof: Focused page and domain tests cover disconnect removing only the routing, a repeated disconnect succeeding, replacement by a machine that proves the same repository, a failed replacement leaving the previous binding and machine authoritative, and the project, its specifications, and its repository fixture unchanged throughout.

- [ ] Task 6 - Prove a connected project reaches a running development run.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Close the defect this slice exists for: `specs/36-local-worker-native-distribution` Task 12's real worker was refused `403` at the gateway credential exchange because no binding could exist.
  - Owned surfaces: The end-to-end integration proof over surfaces already owned elsewhere, from a hosted local-repository project connected through this slice's own page to a successful gateway credential exchange and a run reaching execution, plus the `capability:hosted-local-repository-connection` readiness write-back.
  - Owns: AC-09
  - Proof: Focused integration test drives a normal hosted local-repository project through this slice's own connect action, then asserts the gateway credential exchange succeeds where it previously refused and the run reaches execution; asserts the same exchange still refuses for an unconnected project.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Ownership, cross-workspace denial, and invalid-provider refusal tests pass for the first-connection gate.
- [ ] Exact-match, legacy-identifier, mismatch, and preserve-on-failure tests pass for connection and replacement.
- [ ] Repository content, branch, remote, and Git-configuration non-mutation is proved against a real fixture repository.
- [ ] Minimization checks confirm no path, credential, remote URL, device label, or compatibility metadata is stored, rendered, or returned from folder selection.
- [ ] A hosted local-repository project connected through this slice reaches a running development run.
- [ ] Build, formatting, lint, static checks, and logs review pass.
- [ ] Required browser scenarios pass.
- [ ] New decisions are written back.
- [ ] Deferred work is recorded.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
