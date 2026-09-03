# Assessing A Repository On A Mac Tasks

## Status

In Progress

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

- [x] Task 1 — Admit a repository on a Mac at both assessability gates.
  - Size: Exception — five gates across four modules express one authorization rule. Changing any subset leaves a project admitted at one step and refused at the next, which is the defect itself rather than a smaller version of the fix.
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Stop the assessment refusing a project whose repository is reachable, so it can be scanned at all.
  - Owned surfaces: one owned assessability predicate in `RepositoryAssessments`, and every gate that expresses the same rule reading it: `authorize_project/2`, `RepositoryAssessmentLive`'s hosted context, `AssessmentStore.Hosted`'s `put/2` and `lock_project_binding/1`, and `ProfileStore.Hosted`'s `active_binding?/2` and `lock_project_binding/1`. All admit a hosted active project reachable through a connected GitHub connection or through its worker binding, and none becomes more permissive than the domain.
  - Owns: AC-01, AC-02, AC-06
  - Proof: Focused tests cover a hosted project whose repository is on a Mac starting an assessment, finishing it, and reaching a proposed profile; a GitHub project unchanged at every gate; a hosted project reachable by neither refused at every gate; and a person who does not own the project refused with nothing disclosed.
  - Delivered: `RepositoryAssessments.assessable_hosted_project?/1` is the one rule, and all five gates read it. A Mac project now assesses, finishes, proposes, and approves.

- [x] Task 2 — Name the repository, and name an unreachable Mac.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Make the screen say what it is about and why a start is not offered, instead of turning the person away.
  - Owned surfaces: `RepositoryAssessmentLive`'s repository label for a project whose repository is on a Mac, reusing the device route's existing wording, and its rendered state when the bound Mac is not reachable, which offers no start and changes nothing.
  - Owns: AC-03
  - Proof: Focused LiveView tests cover the screen naming such a repository with the device route's wording, rendering with no start and a stated reason when the bound Mac is not reachable, leaving the project unchanged in that state, and a GitHub project's label unchanged.
  - Delivered: both routes render one owned label for a repository on a Mac. The unreachable state needed no new code, because the screen's existing no-worker handling already produces it.

- [x] Task 3 — Prove the profile is approvable and the chain is clear.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Show the assessment actually produces something the owner can approve, which is the precondition that blocked a run.
  - Owned surfaces: The integration scenario from opening the assessment for a repository on a Mac through to an approved execution profile, which establishes `capability:mac-repository-assessment`.
  - Owns: AC-04, AC-05
  - Proof: An integration scenario assesses such a repository, completes it, and approves the execution profile from its proposal; and a GitHub project's assessment and profile approval are shown unchanged beside it.
  - Delivered: the journey runs through the screens, and the `execution_profile` start precondition is proven to flip from unmet to met, which is the thing the slice set out to unblock.

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
