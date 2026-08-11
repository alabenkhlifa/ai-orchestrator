# Repository SDD Kit Integration Tasks

## Status

In Progress

Task 1 is complete. `specs/35-guided-delivery-feature-specification-link` (created via `update-spec` to resolve Task 2's AC-01 correlation gap) is now `Verified` and merged to `main`. All four of Task 2's required capabilities (`repository-execution-profile`, `guided-delivery-data-surfaces`, `guided-delivery-feature-specification-link`, `project-storage-authority`) are ready. Task 2 is executable next.

Task 2 was split via `update-spec` into a domain task (Task 2, unchanged label) and a new UI task (Task 3), because the original Task 2 combined a substantial worker-local git-diff and conflict-classification engine with a full eligibility, decline, and diff-review LiveView — domain foundation plus UI, a Task Size Gate split trigger. Tasks 3, 4, and 5 renumbered to 4, 5, and 6; no scope, acceptance criterion, or business rule changed.

Parallel-slice check (2026-08-09): reviewed against concurrently active slice 25 (Participation Identity Lifecycle). This slice owns only the repository-kit catalog and plan surfaces (`RepositoryKitPackage`, `RepositoryKitChangePlan`); no shared schema, migration, context, or UI. Partitioned by ownership — no serialization required.

## Active Slice

After one managed pilot, let the project owner inspect one immutable SDD kit, review its exact conflict-aware diff, and apply, update, or remove it only through confirmed isolated-branch operations while preserving Orchestrator specification authority.

## Cross-Specification Dependencies

Requires:

- `capability:repository-execution-profile` — provider `specs/30-repository-execution-profile-completion#Task 2` — required before `Task 2`.
- `capability:guided-delivery-data-surfaces` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 2`.
- `capability:guided-delivery-feature-specification-link` — provider `specs/35-guided-delivery-feature-specification-link#Task 1` — required before `Task 2`.
- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 2`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 6`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 6`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 6`.

Provides:

- `capability:sdd-kit-package` — ready after `Task 1`.
- `capability:repository-sdd-kit` — ready after `Task 6`.

## Task Size Gate

- Every task is standard, owns one independently provable package, plan, presentation, apply, lifecycle, or governance outcome, and has no more than three acceptance criteria and two entities.
- No exception is required.

## Proof Scope Gate

- Applies to: Task 1, Task 2, Task 3.

## Implementation Boundary

Included:

- Optional post-pilot offer, immutable package inspection, and permission disclosure.
- Worker-local no-execution planning, precedence and conflict classification, and exact diff.
- Owner-confirmed isolated-branch application with one commit.
- Explicit update and removal with installed-file ownership proof.
- Storage, privacy, source-of-truth, and managed-runtime fallback proof.

Excluded:

- Repository assessment, pilot implementation, empty-repository creation, automatic merge, direct default-branch writes, remote execution, automatic updates, and specification synchronization.

Deferred after this slice:

- Organization-curated package catalogs, package signing beyond the approved digest and provenance contract, multiple kit families, and automatic pull-request provider integration.

Release gates:

- Live authorized worker and repository-host smoke proof.
- Deployment-specific controller, processor, region, transfer, notice, retention-enforcement, incident, package-distribution, and accountable privacy or legal evidence.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Establish the immutable kit package catalog.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Make every installable file, script, permission, license, and source inspectable under one immutable identity.
  - Owned surfaces: `RepositoryKitPackage` schema and storage, `capability:sdd-kit-package` provider and readiness write-back, package ingestion, canonical manifest and digest, provenance, license, path and size validation, scripts and permissions inventory, adapter compatibility, supersession metadata, package inspection UI, and mutable-reference rejection.
  - Owns: AC-02, AC-03, entity:RepositoryKitPackage
  - Proof: Focused package identity, tamper, path, size, license, provenance, permission, mutable-reference, no-network, no-execution, UI, and browser tests pass before `capability:sdd-kit-package` readiness is recorded.

- [ ] Task 2 — Produce the optional exact change plan.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let owners decide from a complete repository-specific diff after their pilot proves the managed path.
  - Owned surfaces: Post-pilot eligibility read (resolve the linked feature via `capability:guided-delivery-feature-specification-link` by the pilot's `specification_id`, then read that feature's `lifecycle_column` through the existing board read; a not-linked result is not-yet-eligible, not an error), `RepositoryKitChangePlan` schema and persistence, approved-profile and exact-commit binding, worker-local comparison (reusing `WorkerRepositoryAssessment`'s exact-commit staleness check, selected-root containment, tree-entry listing, and blob-content-read primitives), complete file-operation diff, existing-rule precedence, protected-file handling (an existing `AGENTS.md`, `CLAUDE.md`, CI definition, specification template, or contribution rule is always omitted from the plan, never an overwrite target or an ordinary conflict), ordinary conflict classification, safety conflict classification, expiry, and no-mutation planning.
  - Owns: AC-04, AC-05, entity:RepositoryKitChangePlan
  - Proof: Focused pilot-state, eligibility-read, profile, stale-commit, complete-diff, protected-file, precedence, conflict (ordinary and safety), expiry, and no-mutation tests pass.

- [ ] Task 3 — Present post-pilot eligibility, decline, and the reviewable diff.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Let the owner see the optional offer, decline it without losing managed runtime SDD, and review Task 2's exact diff before confirming anything.
  - Owned surfaces: Post-pilot eligibility and decline LiveView (mirroring `RepositoryPilotLive`'s dual device/hosted route and context-loading pattern), plan-trigger action, diff and conflict presentation, and decline action.
  - Owns: AC-01
  - Proof: Focused LiveView tests covering the not-yet-eligible, eligible, decline, and diff-review states, and browser tests (authored as a deliverable, run at slice verification).

- [ ] Task 4 — Apply one confirmed plan on an isolated branch.
  - Size: Standard
  - Depends on: Task 3
  - Purpose: Turn only the reviewed operations into one auditable repository commit without bypassing repository ownership.
  - Owned surfaces: Safety and ordinary conflict gate, exact-plan owner confirmation, `RepositoryKitInstallation`, branch creation, default-branch prohibition, root and symlink containment, hooks-disabled application, confirmed file operations, one resulting commit, installed-file ownership digests, rollback-safe failure, and proof capture.
  - Owns: AC-06, AC-07, AC-08, entity:RepositoryKitInstallation
  - Proof: Focused authorization, stale-plan, conflict, branch isolation, default-branch negative, path and symlink, unexpected-file, hooks-disabled, operation allowlist, partial-failure, commit, evidence, and browser tests pass.

- [ ] Task 5 — Implement idempotent update and removal.
  - Size: Standard
  - Depends on: Task 4
  - Purpose: Keep permanent workflow files controllable without silent changes or deletion of repository-owned work.
  - Owned surfaces: Apply idempotency, explicit newer-version presentation, update planning and confirmation, kit-owned file comparison, user-modification conflicts, removal planning and confirmation, ownership-safe deletion, lifecycle history, and resulting branch evidence.
  - Owns: AC-09, AC-10, AC-11
  - Proof: Focused replay, changed-input, no-silent-update, owned and modified file, shared file, removal safety, history, branch, LiveView, and browser tests pass.

- [ ] Task 6 — Enforce governance and publish the repository-kit capability.
  - Size: Standard
  - Depends on: Task 5
  - Purpose: Prove kit lifecycle data remains governed and workflow installation never becomes a second specification authority.
  - Owned surfaces: Hosted and device storage parity, role access, retention, deletion, processor and transfer controls, diff and log redaction, no analytics, no secondary use, authorized specification-tool adapter, no project-specific specification files, no synchronization, managed-runtime decline and removal fallback, `capability:repository-sdd-kit` readiness write-back, and release evidence.
  - Owns: AC-12, AC-13
  - Proof: Focused storage, access, lifecycle, rights, redaction, processor, no-analytics, source-of-truth, fail-closed tool, no-sync, managed-runtime fallback, and capability readiness tests pass.

## Verification Gate

- [ ] Acceptance criteria pass.
- [ ] Package integrity, provenance, license, permission, and no-execution suites pass.
- [ ] Conflict, exact-diff, stale-plan, branch-isolation, and mutation-negative suites pass.
- [ ] Update, removal, file-ownership, and idempotency suites pass.
- [ ] Hosted and device storage, privacy, lifecycle, and no-analytics suites pass.
- [ ] Desktop and mobile package, plan, conflict, apply, update, removal, and decline browser scenarios pass.
- [ ] `mix check` and all explicit project code-quality commands pass.
- [ ] `npm --prefix assets ci` and `npm --prefix assets run test:e2e` pass.
- [ ] `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` pass.
- [ ] Specification validator and global capability graph pass.

## Blocked Decisions

- None. All of Task 2's required capabilities are ready.

## Progress Log

See [progress.md](progress.md).
