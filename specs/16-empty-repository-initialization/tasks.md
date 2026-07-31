# Empty Repository Initialization Tasks

## Status

Blocked

The product and design agreements are approved. Task 1 is blocked until the governed AI runtime session capability is ready; later tasks also consume the permanent-kit, worker-authorization, and specification-store capabilities.

## Active Slice

Guide one user from an empty local directory through an explicit initialization plan to one checked first Git commit and normal local onboarding, with a permanent SDD kit proposed by default and no support-chat mutation.

## Cross-Specification Dependencies

Requires:

- `capability:ai-runtime-session` — provider `specs/11-ai-runtime-governance#Task 4` — required before `Task 1`.
- `capability:sdd-kit-package` — provider `specs/15-repository-sdd-kit-integration#Task 1` — required before `Task 2`.
- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 5`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 5`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 6`.

Provides:

- `capability:initialized-sdd-repository` — ready after `Task 6`.

## Task Size Gate

- Every task is standard, owns one independently provable discovery, confirmation, staging, commit, handoff, or governance outcome, and has no more than three acceptance criteria and two entities.
- No exception is required.

## Implementation Boundary

Included:

- One empty local-directory eligibility and entry path.
- Read-only governed support conversation and versioned initialization plan.
- Exact structure, command, check, Git, package, permission, provider, and transfer preview.
- Explicit confirmation and separate working-agent launch.
- Isolated staging, minimal skeleton, hooks-disabled Git initialization, checks, first commit, and target publication.
- Local-onboarding and authoritative first-specification handoff.
- Readiness, privacy, lifecycle, and no-analytics proof.

Excluded:

- Non-empty repository changes, empty GitHub remote mutation, source import or merge, multiple roots, monorepos, production deployment, and project features beyond the skeleton.

Deferred after this slice:

- Empty GitHub repository initialization and push.
- Organization templates, multi-service foundations, multiple roots, remote repository creation, and richer starter catalogs.

Release gates:

- Live configured worker and working-agent smoke proof on each supported local operating-system profile.
- Deployment-specific controller, processor, model, worker, region, transfer, notice, retention-enforcement, incident, package-distribution, and accountable privacy or legal evidence.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Guide purpose and technical foundation without mutation.
  - Size: Standard
  - Depends on: none
  - Purpose: Establish an eligible empty target and enough user-approved intent to propose a valid minimal repository.
  - Owned surfaces: Empty-directory entry and operating-system selection, target eligibility and opaque reference, mature-repository routing, read-only initialization support tool policy, versioned `RepositoryInitializationPlan`, product-first questions, technical-foundation question gate, and no-mutation enforcement.
  - Owns: AC-01, AC-02, AC-03, entity:RepositoryInitializationPlan
  - Proof: Focused empty, unborn, non-empty, existing-commit, opaque-path, support-tool denial, plan-version, decision-gate, LiveView, and browser tests pass.

- [ ] Task 2 — Present the exact plan and capture confirmation.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Let the user understand every generated and transferred element before authorizing a working agent.
  - Owned surfaces: Structure and file preview, command and required-check contract, Git and first-commit preview, immutable kit package details and default selection, decline behavior and limitation copy, scripts and permissions, worker and provider summary, processing disclosure, exact-plan confirmation, and changed-input invalidation.
  - Owns: AC-04, AC-05, AC-06
  - Proof: Focused plan rendering, package digest, decline, managed-runtime fallback, disclosure, confirmation binding, changed-input invalidation, accessibility, LiveView, and browser tests pass.

- [ ] Task 3 — Build the confirmed repository in isolated staging.
  - Size: Standard
  - Depends on: Task 2
  - Purpose: Materialize only the approved skeleton through a separate minimum-capability working agent.
  - Owned surfaces: `RepositoryInitializationRun`, working-agent authorization, immutable plan command, staging-root containment, capability allowlist, skeleton adapter, kit vendoring when selected, undeclared-file rejection, hooks and remote-execution prohibition, normalized progress, cancellation, and target read-only posture.
  - Owns: AC-07, AC-08, AC-10, entity:RepositoryInitializationRun
  - Proof: Focused plan-staleness, agent separation, capability denial, path escape, undeclared output, package tamper, no-network, no-hook, selected and declined kit, progress, cancellation, and mutation-negative tests pass.

- [ ] Task 4 — Verify, commit, and publish the unchanged target.
  - Size: Standard
  - Depends on: Task 3
  - Purpose: Produce one exact checked root commit or a visible safe failure without replacing user data.
  - Owned surfaces: Target unchanged-boundary revalidation, symlink and permission checks, confirmed command execution, typed required-check evidence, checked-tree binding, staging Git initialization, first commit, `RepositoryInitializationResult`, idempotent replay, rollback-safe publication, failure-stage activity, and no-success-on-failure rule.
  - Owns: AC-09, AC-11, AC-12, entity:RepositoryInitializationResult
  - Proof: Focused target-race, new-commit, symlink, permission, check failure, tree mismatch, Git hook negative, root-commit uniqueness, replay, publication failure, user-data preservation, evidence, and browser tests pass.

- [ ] Task 5 — Complete onboarding and authoritative specification handoff.
  - Size: Standard
  - Depends on: Task 4
  - Purpose: Move a successfully initialized repository into normal project authority without creating another specification source.
  - Owned surfaces: Local-onboarding handoff, portable repository identity consumption, project and storage registration continuation, initialization-agreement conversion, complete shared-store first revision, no repository specification copy, handoff idempotency, and assistant/specification/agent-execution/release readiness presentation.
  - Owns: AC-13, AC-14
  - Proof: Focused local-onboarding, repository identity, storage selection, project creation, complete revision, replay, no-copy, readiness, LiveView, and browser integration tests pass.

- [ ] Task 6 — Enforce governance and publish initialization readiness.
  - Size: Standard
  - Depends on: Task 5
  - Purpose: Govern pre-project and resulting project data across every worker, model, cache, log, backup, and deletion path.
  - Owned surfaces: Pre-project purpose and basis, field minimization, AI-runtime and project authority transition, worker-local index and staging lifecycle, role access, cancellation cleanup, retention and deletion, rights, processor and transfer controls, redacted logs, no analytics, no secondary use, `capability:initialized-sdd-repository` readiness write-back, and release evidence.
  - Owns: AC-15
  - Proof: Focused authority-transition, worker-locality, source-upload negative, access, lifecycle, cancellation cleanup, rights, processor, transfer, redaction, backup, no-analytics, no-secondary-use, and capability readiness tests pass.

## Verification Gate

- [ ] Acceptance criteria pass.
- [ ] Support-tool denial and working-agent capability-isolation suites pass.
- [ ] Empty-target, staging, target-race, path, symlink, hook, and user-data-preservation suites pass.
- [ ] Skeleton, kit choice, command, check, first-commit, publication, and idempotency suites pass.
- [ ] Local-onboarding and complete specification-store handoff suites pass.
- [ ] Privacy, lifecycle, rights, redaction, processor, and no-analytics suites pass.
- [ ] Desktop and mobile discovery, plan, decline, confirmation, progress, failure, result, onboarding, and readiness browser scenarios pass.
- [ ] `mix check` and all explicit project code-quality commands pass.
- [ ] `npm --prefix assets ci` and `npm --prefix assets run test:e2e` pass.
- [ ] `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` pass.
- [ ] Specification validator and global capability graph pass.

## Blocked Decisions

- `capability:ai-runtime-session` is unavailable until its provider completes; this blocks Task 1 implementation.

## Progress Log

### 2026-07-31

- Completed: Approved the empty-local-repository discovery, confirmation, working-agent, staging, first-commit, default-kit, decline, onboarding, authoritative-specification, readiness, governance, and capability contracts.
- Remaining: Complete the prerequisite capabilities, implement Tasks 1–6, and pass the verification gate.
- Failed checks: None.
- Spec updates: Created the initial approved specification and first executable slice.
