# Repository SDD Kit Integration Tasks

## Status

In Progress

Tasks 1 through 6 are complete. Task 7 (enforce governance and publish `capability:repository-sdd-kit`) is next, `Depends on: Task 6`, now satisfied. A real worker-dispatch path (so `plan_change/4`/`apply_plan/4`/`plan_update/4`/`plan_removal/3` can resolve a live `repository_path` instead of refusing) remains open — consistent with this slice's own declared release gate ("Live authorized worker and repository-host smoke proof"), not an implementation defect; see progress.md.

Task 2 was split via `update-spec` into a domain task (Task 2, unchanged label) and a new UI task (Task 3), because the original Task 2 combined a substantial worker-local git-diff and conflict-classification engine with a full eligibility, decline, and diff-review LiveView — domain foundation plus UI, a Task Size Gate split trigger. Tasks 3, 4, and 5 renumbered to 4, 5, and 6; no scope, acceptance criterion, or business rule changed.

Task 5 was split via `update-spec` into a narrowed idempotency-and-update task (Task 5, unchanged label, now AC-09+AC-10) and a new removal task (Task 6, AC-11), because the original Task 5 bundled two independently-testable lifecycle workflows — update (one state transition: `applied` → `updated`) and removal (a different state transition: `applied`/`updated` → `removed`) — plus a general idempotency fix into one task, the same "combines independently testable behaviors" / "more than one primary state transition" Task Size Gate trigger that split Task 2. The former Task 6 (governance) renumbered to Task 7, `Depends on: Task 6`; no scope, acceptance criterion, or business rule changed. `specs/13-sdd-adoption/tasks.md`'s `capability:repository-sdd-kit` requirement corrected from `#Task 6` to `#Task 7` in the same change.

Parallel-slice check (2026-08-09): reviewed against concurrently active slice 25 (Participation Identity Lifecycle). This slice owns only the repository-kit catalog and plan surfaces (`RepositoryKitPackage`, `RepositoryKitChangePlan`); no shared schema, migration, context, or UI. Partitioned by ownership — no serialization required.

## Active Slice

After one managed pilot, let the project owner inspect one immutable SDD kit, review its exact conflict-aware diff, and apply, update, or remove it only through confirmed isolated-branch operations while preserving Orchestrator specification authority.

## Cross-Specification Dependencies

Requires:

- `capability:repository-execution-profile` — provider `specs/30-repository-execution-profile-completion#Task 2` — required before `Task 2`.
- `capability:guided-delivery-data-surfaces` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 2`.
- `capability:guided-delivery-feature-specification-link` — provider `specs/35-guided-delivery-feature-specification-link#Task 1` — required before `Task 2`.
- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 2`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 7`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 7`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 7`.

Provides:

- `capability:sdd-kit-package` — ready after `Task 1`.
- `capability:repository-sdd-kit` — ready after `Task 7`.

## Task Size Gate

- Every task is standard, owns one independently provable package, plan, presentation, apply, lifecycle, or governance outcome, and has no more than three acceptance criteria and two entities.
- No exception is required.

## Proof Scope Gate

- Applies to: Task 1, Task 2, Task 3, Task 4, Task 5, Task 6.

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

- [x] Task 2 — Produce the optional exact change plan.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let owners decide from a complete repository-specific diff after their pilot proves the managed path.
  - Owned surfaces: Post-pilot eligibility read (resolve the linked feature via `capability:guided-delivery-feature-specification-link` by the pilot's `specification_id`, then read that feature's `lifecycle_column` through the existing board read; a not-linked result is not-yet-eligible, not an error), `RepositoryKitChangePlan` schema and persistence, approved-profile and exact-commit binding, worker-local comparison (reusing `WorkerRepositoryAssessment`'s exact-commit staleness check, selected-root containment, tree-entry listing, and blob-content-read primitives), complete file-operation diff, existing-rule precedence, protected-file handling (an existing `AGENTS.md`, `CLAUDE.md`, CI definition, specification template, or contribution rule is always omitted from the plan, never an overwrite target or an ordinary conflict), ordinary conflict classification, safety conflict classification, expiry, and no-mutation planning.
  - Owns: AC-04, AC-05, entity:RepositoryKitChangePlan
  - Proof: Focused pilot-state, eligibility-read, profile, stale-commit, complete-diff, protected-file, precedence, conflict (ordinary and safety), expiry, and no-mutation tests pass.

- [x] Task 3 — Present post-pilot eligibility, decline, and the reviewable diff.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Let the owner see the optional offer, decline it without losing managed runtime SDD, and review Task 2's exact diff before confirming anything.
  - Owned surfaces: Post-pilot eligibility and decline LiveView at `/projects/:id/kit` (`RepositoryKitOfferLive`, hosted-only for now — mirrors `RepositoryPilotLive`'s hosted context-loading pattern; no device route, since `RepositoryKitChangePlan` persistence is itself hosted-only pending Task 7), plan-trigger action, diff and conflict presentation, and decline action.
  - Owns: AC-01
  - Proof: Focused LiveView tests covering the not-yet-eligible, eligible, decline, and diff-review states pass. Browser scenario deferred (see progress.md): a real slice-gate `e2e_bootstrap_controller.ex` scenario would need to chain assessment, profile approval, pilot selection, feature linking, and kit publishing, which is out of a single focused task's scope to author unverified.

- [x] Task 4 — Apply one confirmed plan on an isolated branch.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Turn only the reviewed operations into one auditable repository commit without bypassing repository ownership.
  - Owned surfaces: Safety and ordinary conflict gate, exact-plan owner confirmation, `RepositoryKitInstallation`, branch creation, default-branch prohibition, root and symlink containment, hooks-disabled application, confirmed file operations, one resulting commit, installed-file ownership digests, rollback-safe failure, and proof capture.
  - Owns: AC-06, AC-07, AC-08, entity:RepositoryKitInstallation
  - Proof: Focused authorization, stale-plan, conflict, branch isolation, default-branch negative, path and symlink, unexpected-file, hooks-disabled, operation allowlist, partial-failure, commit, evidence, and browser tests pass.

- [x] Task 5 — Implement idempotent apply and kit update.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Let a retried confirmation return its already-recorded result instead of erroring or duplicating, and let the owner move an installed kit to a newer version without silently touching files no longer proven to be kit-owned.
  - Owned surfaces: Idempotent apply-retry for any confirmed plan (returns the existing `RepositoryKitInstallation` unchanged when the exact same plan is retried, generalized so Task 6's removal path can reuse the same mechanism rather than redefining it), the `RepositoryKitInstallation` lifecycle-history and state-transition schema extension (introduces the `updated` state alongside `applied` and the history mechanism Task 6's `removed` transition will also use, without redefining Task 4's existing columns), explicit newer-package-available presentation (informational only — a newer version is never selected or applied automatically), update planning (kit-owned file comparison among the new package's proposed content, the currently-installed file digests, and the live repository, distinguishing still-kit-owned-and-unchanged files from user-modified ones), update conflict presentation, update confirmation, and isolated-branch update apply reusing Task 4's `WorkerKitApply`.
  - Owns: AC-09, AC-10
  - Proof: Focused replay, changed-input, newer-version-info-only, update kit-owned-file comparison, user-modification conflict, update apply, branch, evidence, LiveView, and browser tests pass.

- [x] Task 6 — Implement kit removal.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Let the owner remove an installed kit's files on a new isolated branch without deleting anything not proven to still be kit-owned and unchanged.
  - Owned surfaces: Removal planning (kit-owned file comparison between the currently-installed file digests and the live repository, distinguishing still-kit-owned-and-unchanged files, safe to delete, from user-modified or shared files, left for explicit review), removal conflict presentation, removal confirmation, ownership-safe deletion, isolated-branch removal apply reusing Task 4's `WorkerKitApply` and Task 5's idempotent-retry mechanism, and the `removed` state transition on Task 5's lifecycle-history schema (extends it, does not redefine it).
  - Owns: AC-11
  - Proof: Focused removal planning, ownership-safe deletion, user-modified and shared-file conflict, removal apply, branch, evidence, LiveView, and browser tests pass.

- [ ] Task 7 — Enforce governance and publish the repository-kit capability.
  - Size: Standard
  - Depends on: Task 6
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

- None. Tasks 1–6 are complete; Task 7 has no unmet capability requirements.
- Deferred, not blocking: `RepositoryKitChangePlan` and `RepositoryKitInstallation` persistence are hosted-only for now (a device authority is refused with `:unsupported_authority`/`:unauthorized` at the persistence step). Building the `Device`/`Hosted` dual-authority split is explicitly Task 7's ("Hosted and device storage parity") owned surface, not a gap in Tasks 2–6.
- Deferred, not blocking: no worker-dispatch mechanism yet resolves a live `repository_path` for `plan_change/4`/`apply_plan/4`/`plan_update/4`/`plan_removal/3` from a hosted LiveView (Tasks 3, 4, 5, and 6 all surface this honestly as "not available from this screen yet" rather than fabricating one). This is the same already-declared release-gate concern ("Live authorized worker and repository-host smoke proof"), not new scope; it does not block implementation or local verification of Tasks 1–6.
- Resolved by Task 6: an already-removed installation is no longer a valid target for a further update or removal — `fetch_current_installation/1` now only treats `"applied"`/`"updated"` rows as active, so both `plan_update/4` and `plan_removal/3` refuse `{:error, :not_installed}` against a `"removed"` row.
- Resolved by Task 5: apply-retry is now genuinely idempotent (AC-09) — `apply_plan/4` short-circuits on a repeat `plan_id` and returns the already-persisted installation unchanged, before touching the repository or the expiry/conflict gates. Task 4's unique index on `plan_id` remains as a schema-level safety net beneath that behavior.
- Discovery, not acted on (out of this slice's scope): `AssessmentStore`/`ProfileStore`'s hosted "latest" reads break an `inserted_at` tie on `id desc` — a random UUID. Two profile approvals stamped with the same caller-supplied `now` therefore pick a non-deterministic "latest" assessment. Task 5's own tests hit this (worked around the same way `managed_runtime_profile_test.exs` already does, by advancing `now` between approvals) but the underlying tie-break belongs to the assessment/profile storage modules (specs/14/specs/30), not this slice — flagged here for whichever of those specs next touches that ordering, not fixed in this change.

## Progress Log

See [progress.md](progress.md).
