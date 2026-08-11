# Empty Repository Initialization Tasks

## Status

Verified

The product and design agreements are approved. This slice no longer depends on `capability:local-worker-run-execution` (specs/33): that capability's gateway credential, command, and manifest contract are hard-bound to an existing project and channel topic, and cannot exist before this slice's own project creation (Task 6). Task 1 now builds a project-independent dispatch foundation of its own, reusing `capability:workspace-bound-local-worker-authorization` (specs/02 Task 3, ready) for worker authorization and the existing `WorkerProtocol`/`ProtocolCodec`/`AgentAdapter` code as a library, without touching specs/33's schema or contract. All seven tasks are complete. `capability:sdd-kit-package` (Task 3's requirement, provider `specs/15-repository-sdd-kit-integration#Task 1`) was cherry-picked from its own slice branch onto `main` ahead of the rest of specs/15 (specs/15 Task 2 remains separately blocked on `capability:guided-delivery-feature-specification-link`), and this branch rebased onto that `main` before Task 3 started. Task 3's plan skeleton (structure, commands, checks, Git behavior) is a fixed, deterministic constant, not generated from the technical-foundation answer — an explicit product decision (2026-08-11) to avoid inventing an unproven structured-output contract from a coding-agent turn; see `progress.md`. Task 4 does not route through `AgentAdapter` or a coding-agent CLI at all: `InitializationWorkerChannel`'s `handle_in("dispatch", ...)` (Task 1) always executes on the control-plane process, not a genuinely remote paired worker's own machine, which the read-only conversation turns (Tasks 2-3) never needed to matter for, but Task 4's real file writes would; Task 4 instead builds its own deterministic staging path, reusing Task 1's authorization/capability-grant primitives directly. Task 5 continues the same pattern: it also never routes through `AgentAdapter`, and it does not wire any live caller (LiveView or otherwise) to invoke it — `target_path` remains a plain caller-supplied argument, matching Task 2's own open "resolve `target_reference` back to a path" gap; see `progress.md`. Task 6 is where that gap finally closes: it wires the LiveView's confirmed step to run `StagingBuilder` → `Publisher` → its own new `Handoff` module end to end in one live session, using `socket.assigns.target_path` directly. Task 7 retrofits governance across the whole pipeline built in Tasks 1-6 — processing inventory and field-purpose map, workspace-scoped plan access, a redacted content-free security log, dual-regime retention (24-hour pre-project abandonment vs. account-erasure-only once a result exists), and account-scoped rights export/erasure — and records `capability:initialized-sdd-repository` ready; see `progress.md`. The Verification Gate has passed with one documented exception: four pre-existing, unrelated test failures already investigated and accepted by `specs/35-guided-delivery-feature-specification-link`'s own Verification Gate the same day — see `progress.md`. Implementation and local-verification readiness are complete. Release readiness remains open per this slice's own already-declared Release gates.

Parallel-slice check (2026-08-09): reviewed against concurrently active slice 25 (Participation Identity Lifecycle). This slice owns only the repository-initialization plan/run surfaces (`RepositoryInitializationPlan`, `RepositoryInitializationRun`, `InitializationDispatch`); no shared schema, migration, context, or UI. Partitioned by ownership — no serialization required.

## Active Slice

Guide one user from an empty local directory through an explicit initialization plan to one checked first Git commit and normal local onboarding, with a permanent SDD kit proposed by default and no support-chat mutation.

## Cross-Specification Dependencies

Requires:

- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 1`.
- `capability:ai-runtime-session` — provider `specs/11-ai-runtime-governance#Task 11` — required before `Task 2`.
- `capability:sdd-kit-package` — provider `specs/15-repository-sdd-kit-integration#Task 1` — required before `Task 3`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 6`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 7`.

Provides:

- `capability:initialized-sdd-repository` — ready after `Task 7`.

## Task Size Gate

- Every task is standard, owns one independently provable foundation, discovery, confirmation, staging, commit, handoff, or governance outcome, and has no more than three acceptance criteria and two entities.
- No exception is required.

## Proof Scope Gate

- Applies to: Task 1, Task 2, Task 3, Task 4, Task 5, Task 6, Task 7.

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

- [x] Task 1 — Establish pre-project capability-scoped worker dispatch foundation.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give the read-only support conversation and the working agent one project-independent way to reach an authorized local worker, since `capability:local-worker-run-execution` (specs/33) cannot exist before this slice creates a project.
  - Owned surfaces: Pre-project worker authorization through `Devices.Pairing.authenticate_worker/1` and `authorize_for_workspace/2`, a project-independent `InitializationDispatch` command and manifest schema, its channel addressing, a read-only/plan-discovery vs. staging-write capability-grant enum enforced at command-routing time, and dispatch to one `AgentAdapter` implementation with a typed response.
  - Owns: entity:InitializationDispatch
  - Proof: Focused worker-authorization accept/refuse, manifest enforced-key rejection, capability-grant denial of an out-of-grant operation, and dispatch round-trip tests pass.

- [x] Task 2 — Guide purpose and technical foundation without mutation.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Establish an eligible empty target and enough user-approved intent to propose a valid minimal repository.
  - Owned surfaces: Empty-directory entry and operating-system selection, target eligibility and opaque reference, mature-repository routing, read-only initialization support tool policy dispatched through Task 1's foundation, versioned `RepositoryInitializationPlan`, product-first questions, technical-foundation question gate, and no-mutation enforcement.
  - Owns: AC-01, AC-02, AC-03, entity:RepositoryInitializationPlan
  - Proof: Focused empty, unborn, non-empty, existing-commit, opaque-path, support-tool denial, plan-version, decision-gate, LiveView, and browser tests pass.

- [x] Task 3 — Present the exact plan and capture confirmation.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Let the user understand every generated and transferred element before authorizing a working agent.
  - Owned surfaces: Structure and file preview, command and required-check contract, Git and first-commit preview, immutable kit package details and default selection, decline behavior and limitation copy, scripts and permissions, worker and provider summary, processing disclosure, exact-plan confirmation, and changed-input invalidation.
  - Owns: AC-04, AC-05, AC-06
  - Proof: Focused plan rendering, package digest, decline, managed-runtime fallback, disclosure, confirmation binding, changed-input invalidation, accessibility, LiveView, and browser tests pass.

- [x] Task 4 — Build the confirmed repository in isolated staging.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Materialize only the approved skeleton through a separate minimum-capability working agent.
  - Owned surfaces: `RepositoryInitializationRun`, working-agent authorization through Task 1's foundation with a staging-write capability grant, immutable plan command, staging-root containment, capability allowlist, skeleton adapter, kit vendoring when selected, undeclared-file rejection, hooks and remote-execution prohibition, normalized progress, cancellation, and target read-only posture.
  - Owns: AC-07, AC-08, AC-10, entity:RepositoryInitializationRun
  - Proof: Focused plan-staleness, agent separation, capability denial, path escape, undeclared output, package tamper, no-network, no-hook, selected and declined kit, progress, cancellation, and mutation-negative tests pass.

- [x] Task 5 — Verify, commit, and publish the unchanged target.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Produce one exact checked root commit or a visible safe failure without replacing user data.
  - Owned surfaces: Target unchanged-boundary revalidation, symlink and permission checks, confirmed command execution, typed required-check evidence, checked-tree binding, staging Git initialization, first commit, `RepositoryInitializationResult`, idempotent replay, rollback-safe publication, failure-stage activity, and no-success-on-failure rule.
  - Owns: AC-09, AC-11, AC-12, entity:RepositoryInitializationResult
  - Proof: Focused target-race, new-commit, symlink, permission, check failure, tree mismatch, Git hook negative, root-commit uniqueness, replay, publication failure, user-data preservation, evidence, and browser tests pass.

- [x] Task 6 — Complete onboarding and authoritative specification handoff.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Move a successfully initialized repository into normal project authority without creating another specification source.
  - Owned surfaces: Local-onboarding handoff, portable repository identity consumption, project and storage registration continuation, initialization-agreement conversion, complete shared-store first revision, no repository specification copy, handoff idempotency, and assistant/specification/agent-execution/release readiness presentation.
  - Owns: AC-13, AC-14
  - Proof: Focused local-onboarding, repository identity, storage selection, project creation, complete revision, replay, no-copy, readiness, LiveView, and browser integration tests pass.

- [x] Task 7 — Enforce governance and publish initialization readiness.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 6
  - Purpose: Govern pre-project and resulting project data across every worker, model, cache, log, backup, and deletion path.
  - Owned surfaces: Pre-project purpose and basis, field minimization, AI-runtime and project authority transition, worker-local index and staging lifecycle, role access, cancellation cleanup, retention and deletion, rights, processor and transfer controls, redacted logs, no analytics, no secondary use, `capability:initialized-sdd-repository` readiness write-back, and release evidence.
  - Owns: AC-15
  - Proof: Focused authority-transition, worker-locality, source-upload negative, access, lifecycle, cancellation cleanup, rights, processor, transfer, redaction, backup, no-analytics, no-secondary-use, and capability readiness tests pass.

## Verification Gate

- [x] Acceptance criteria pass.
- [x] Support-tool denial and working-agent capability-isolation suites pass.
- [x] Empty-target, staging, target-race, path, symlink, hook, and user-data-preservation suites pass.
- [x] Skeleton, kit choice, command, check, first-commit, publication, and idempotency suites pass.
- [x] Local-onboarding and complete specification-store handoff suites pass.
- [x] Privacy, lifecycle, rights, redaction, processor, and no-analytics suites pass.
- [x] Desktop and mobile discovery, plan, decline, confirmation, progress, failure, result, onboarding, and readiness browser scenarios pass.
- [x] `mix check` and all explicit project code-quality commands pass, with one documented exception: the full test run carries four pre-existing, unrelated failures already investigated and accepted as a documented exception by `specs/35-guided-delivery-feature-specification-link`'s own Verification Gate the same day — see `progress.md`. `format`, `compile --warnings-as-errors`, `credo --strict`, `dialyzer`, `deps.audit`, and `sobelow --config` all pass cleanly with no exception.
- [x] `npm --prefix assets ci` and `npm --prefix assets run test:e2e` pass.
- [x] `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` pass.
- [x] Specification validator and global capability graph pass.

## Blocked Decisions

- None. All seven tasks are complete and the slice is Verified.

## Progress Log

See [progress.md](progress.md).
