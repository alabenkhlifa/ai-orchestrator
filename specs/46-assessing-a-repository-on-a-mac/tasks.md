# Assessing A Repository On A Mac Tasks

## Status

Not Started

## Active Slice

Let the owner of a hosted project whose repository is on their Mac assess that repository and approve its execution profile: one assessability rule expressed at both gates, the screen naming the repository and the unreachable Mac instead of redirecting, and the profile approvable from the assessment that follows.

## Cross-Specification Dependencies

Requires:

- `capability:hosted-local-repository-projects` — provider `specs/44-hosted-local-repository-projects#Task 4` — required before `Task 1`.

Provides:

- `capability:mac-repository-assessment` — ready after `Task 3`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- The assessability rule admitting a hosted project whose repository is reachable through its worker binding, at the domain gate and at the screen's gate together.
- The screen's repository label for such a project, and its not-reachable state.
- Proof that the execution profile is approvable from the assessment that follows.

Excluded:

- The scan, the proposal envelope, the disclosure digest, and the profile's own approval mechanics, owned by `specs/14-repository-execution-profile/`.
- The `:device` route and the accountless flow behind it.
- Connecting, reconnecting, or moving the Mac, owned by `specs/37-hosted-local-repository-connection/`.
- Pressing `Start development`, owned by `specs/41-feature-delivery-from-the-ui/`.
- Every other screen that assumes a hosted project has a GitHub repository connection.

Deferred after this slice:

- Auditing the remaining screens for the same assumption. This slice fixes the one that blocks a run.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Admit a repository on a Mac at both assessability gates.
  - Size: Exception — the screen's gate and the domain's gate express one authorization rule. Changing either alone leaves a state where the screen offers an assessment the domain refuses, or refuses one the domain would allow, which is an authorization boundary disagreeing with itself.
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Stop the assessment refusing a project whose repository is reachable, so it can be scanned at all.
  - Owned surfaces: `RepositoryAssessments.authorize_project/2` for a hosted authority, and `RepositoryAssessmentLive`'s `active_hosted_project?/1`, both admitting a hosted active project that is reachable through a connected GitHub connection or through its worker binding.
  - Owns: AC-01, AC-02, AC-06
  - Proof: Focused tests cover a hosted project whose repository is on a Mac being admitted at both gates and starting an assessment, a GitHub project unchanged at both, a hosted project reachable by neither refused at both, and a person who does not own the project refused with nothing disclosed.

- [ ] Task 2 — Name the repository, and name an unreachable Mac.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Make the screen say what it is about and why a start is not offered, instead of turning the person away.
  - Owned surfaces: `RepositoryAssessmentLive`'s repository label for a project whose repository is on a Mac, reusing the device route's existing wording, and its rendered state when the bound Mac is not reachable, which offers no start and changes nothing.
  - Owns: AC-03
  - Proof: Focused LiveView tests cover the screen naming such a repository with the device route's wording, rendering with no start and a stated reason when the bound Mac is not reachable, leaving the project unchanged in that state, and a GitHub project's label unchanged.

- [ ] Task 3 — Prove the profile is approvable and the chain is clear.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Show the assessment actually produces something the owner can approve, which is the precondition that blocked a run.
  - Owned surfaces: The integration scenario from opening the assessment for a repository on a Mac through to an approved execution profile, which establishes `capability:mac-repository-assessment`.
  - Owns: AC-04, AC-05
  - Proof: An integration scenario assesses such a repository, completes it, and approves the execution profile from its proposal; and a GitHub project's assessment and profile approval are shown unchanged beside it.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] The GitHub assessment and its profile approval pass unchanged.
- [ ] The accountless device route passes unchanged.
- [ ] Authorization refusals pass unchanged for a person who does not own the project.
- [ ] Build, formatting, lint, static checks, and logs review pass.
- [ ] Required browser scenarios pass.
- [ ] Product proof: one click path from `/` in a real browser, worker stand-in off, no `/_e2e` seeding, against the paired worker app: open a hosted project whose repository is on this Mac, assess it, approve its execution profile, and see the feature's execution-profile precondition become met. Recorded in `progress.md`.

## Blocked Decisions

- None.

## Release Gate

- None.

## Progress Log

See [progress.md](progress.md).
