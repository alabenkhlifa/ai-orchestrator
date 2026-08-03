# Repository Execution Profile Tasks

## Status

In Progress

The product and technical contracts are approved. Tasks 7, 8, 1, 2, 3, and 9 are complete. Task 10 remains in progress in its isolated task worktree. Privacy, lifecycle, and final capability publication continue in `specs/30-repository-execution-profile-completion/`. Slice 07 consumption remains a later explicit `update-spec` agreement change.

## Active Slice

Assess one mature repository at one exact commit through a bounded read-only worker scan, let the owner approve one execution profile and pilot specification, and publish the profile capability for managed runtime integration without changing repository files.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 8`.
- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 7`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 4`.

Provides:

- `capability:repository-approved-pilot` — ready after `Task 4`.
- `capability:repository-profile-readiness` — ready after `Task 12`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- All ten tasks are standard, own one primary outcome, have at most three acceptance criteria and two entities, and have focused proof expected to run in about ten minutes.
- The longest `Depends on:` path contains eight tasks: Task 7, Task 8, Task 1, Task 2, Task 3, Task 10, Task 11, then Task 4 or Task 12.
- No exception is required.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One-root assessment start, disclosure, persistence, and readiness surface.
- Short-lived disclosure-confirmed repository-binding preparation that proves repository identity, normalized root, and current full commit without scanning content.
- Worker-local high-signal scanning, exact-commit cache, cancellation, and structured findings.
- Terminal minimized assessment results and exact-commit cache reuse.
- Owner-reviewed immutable execution-profile approval.
- One authoritative pilot specification and revision reference plus independent readiness.

Excluded:

- Repository mutation, kit installation, empty-repository initialization, whole-source indexing or upload, backlog import, and automatic check invention.
- Slice 07 execution-manifest behavior changes.
- Privacy and lifecycle enforcement plus final managed-runtime serialization and `capability:repository-execution-profile` publication, owned by `specs/30-repository-execution-profile-completion/`.

Deferred after this slice:

- Multiple roots, monorepo subprojects, automatic backlog import, and issue-provider synchronization.
- `specs/30-repository-execution-profile-completion/` consumes the two focused handoffs from Tasks 4 and 12, enforces AC-12, and owns AC-13 plus final capability publication.
- Slice 07 `update-spec` work that consumes `capability:repository-execution-profile` before managed execution.

Release gates:

- A future approved Slice 07 consumer edge and manifest contract before a production managed run relies on the profile.
- Live configured worker smoke proof for each supported deployment profile.
- Deployment-specific controller, processor, model, worker, region, transfer, notice, retention-enforcement, incident, and accountable privacy or legal evidence.

Traceability:

- Deferred criteria: AC-12, AC-13
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Parallel Implementation Ownership

- Implementation is partitioned by ownership between `specs/11-ai-runtime-governance#Task 7` and `specs/14-repository-execution-profile#Task 7`, `#Task 8`, plus `#Task 1` (Tasks 14.7, 14.8, and 14.1).
- `specs/11-ai-runtime-governance#Task 7` exclusively owns the personal AI worker transport, including its socket, channel, and any Endpoint registration.
- `specs/14-repository-execution-profile#Task 7` exclusively owns the assessment-specific repository-binding value and metadata adapter after disclosure confirmation. It must not modify the personal AI socket, channel, or Endpoint; any shared transport integration is serialized after Slice 11 Task 7.
- `specs/14-repository-execution-profile#Task 8` exclusively owns repository-assessment persistence and authorization, including its migration, hosted and device-authoritative storage contracts, owner-only start service, and focused domain and adapter proof.
- `specs/14-repository-execution-profile#Task 1` exclusively owns repository-assessment UI, including the route and project navigation, assessment LiveView, disclosure and exact-binding presentation, and focused browser test.
- Repository-wide verification is serialized after the active Slice 11 and Slice 14 task-scoped changes are reconciled. Each parallel task runs only its focused proof and must not modify the other task's owned surfaces.

## Tasks

- [x] Task 7 — Prepare a trusted repository binding after disclosure confirmation.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Supply Task 1 with one fresh worker-verified repository identity, normalized root, and current full commit without scanning content or trusting owner-entered repository values.
  - Owned surfaces: `RepositoryBindingPreparation` value contract, owner and hosted/device authority, explicit paired-worker selection, processing-boundary confirmation prerequisite, assessment-specific metadata adapter and deterministic double, canonical repository identity proof, one-root selection, repository-relative root normalization and containment, full exact-commit resolution, short expiry, single-use consumption and unchanged revalidation, unknown, malformed, mismatch, stale, replay, unavailable, cross-project and cross-workspace refusal, no absolute path or raw diagnostic return, no durable hosted copy, no scan command, and repository non-mutation fixture.
  - Owns: entity:RepositoryBindingPreparation
  - Proof: Focused domain, authorization, adapter-contract, expiry, replay, stale, identity-mismatch, root-containment, exact-commit, cross-project, cross-workspace, no-hosted-copy, no-scan-command, and unchanged-repository tests pass without modifying the personal AI socket, channel, or Endpoint.

- [x] Task 8 — Establish authoritative repository-assessment state and storage parity.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 7
  - Purpose: Consume one unchanged trusted binding through an owner-only service and persist one pending assessment in exactly the project's authoritative storage destination without issuing a scan command.
  - Owned surfaces: `RepositoryAssessment` value and state transition, hosted schema and migration, hosted and device-authoritative assessment-store adapters, device-store contract, owner and device authority, project and exact-binding isolation, changed-boundary confirmation record, pending-scan creation, stale and replay refusal, no durable hosted copy for device projects, and no-command or repository-mutation contract.
  - Owns: entity:RepositoryAssessment
  - Proof: Focused domain, migration, owner and device authorization, hosted/device adapter-contract, restart persistence, cross-project, cross-workspace, stale, replay, no-hosted-copy, no-command, and unchanged-repository tests pass.
  - Delivered: `RepositoryAssessments.start_assessment/4` consumes one unchanged Task 7 binding and creates one minimized `pending_scan` value; `RepositoryAssessment` and the hosted migration constrain the exact repository, scanner and disclosure digests, worker reference, confirmation time, and sole Task 8 state; `AssessmentStore.Hosted` persists only owner-authorized hosted projects in PostgreSQL while `AssessmentStore.Device` persists only connected projects owned by the current device workspace through strict allowlisted `DeviceStore`/DETS callbacks. Device values survive adapter restart and create no hosted row; stale, expired, replayed, cross-project, cross-workspace, wrong-authority, malformed, or repository-mismatched input persists nothing, and no scanner, command transport, repository path, content, raw diagnostic, or repository mutation was introduced.

- [x] Task 1 — Establish assessment state and owner-controlled start.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8
  - Purpose: Let the owner review the processing boundary and one verified repository binding, then explicitly create the pending assessment through the authoritative Task 8 service.
  - Owned surfaces: Assessment entry and one-root selection LiveView, hosted and device routes, project navigation, inspected-surface, local-data, transfer, processor, retention, purpose and limit disclosure, first or changed-boundary confirmation interaction, verified repository, normalized-root and full-commit presentation, owner-only start action, and focused desktop/mobile browser scenario.
  - Owns: AC-01, AC-02
  - Proof: Focused LiveView authorization and interaction tests plus one desktop/mobile browser file prove only the owner can confirm and start, every required disclosure and exact-binding field is visible, and no metadata or scan command is issued before confirmation.
  - Delivered: `RepositoryAssessmentLive` serves owner-authorized hosted and device routes, content-addresses the complete processing disclosure, lists only currently reachable paired workers, accepts one normalized relative root without narrowing Task 7's length contract, and separates disclosure confirmation and metadata-only binding preparation from the final Task 8 start transition. Hosted owners receive one owner-only Assessment navigation destination; device projects receive a local dashboard entry. The verified repository, normalized root, and full commit remain visible before start, safe failures disclose no raw diagnostics, and the resulting pending assessment stays in the project's authoritative hosted or device store without issuing a scan command.

- [x] Task 2 — Implement bounded worker-local repository assessment.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Gather the smallest reliable repository evidence without executing content or uploading a whole-repository index.
  - Owned surfaces: Read-only worker command, root-containment and exact-commit guards, high-signal allowlist, ignored and prohibited paths, byte/file/time limits, progress, cancellation, structured findings, and no repository mutation enforcement.
  - Owns: AC-03, AC-04
  - Proof: Focused worker protocol, malicious-content, path-escape, ignored-secret, binary, limit, cancellation, mutation-negative, and structured-result tests pass.
  - Delivered: `RepositoryAssessmentCommand` serializes one strict minimized pending-assessment command bound to the project, canonical repository, selected root, exact commit, scanner and disclosure digests, opaque worker, and capped path, file, byte, per-file, and time limits without a filesystem path or credential. `WorkerRepositoryAssessment.scan/3` verifies current `HEAD`, requires the selected root to be a tree at that commit, enumerates and reads only exact-commit Git objects, restricts findings to allowlisted instruction, contribution, manifest, CI, check, and top-level structure signals, excludes secrets, generated and dependency stores, symlinks, binaries, unsafe paths, and untracked or modified working-tree content, reports content-free progress, cooperatively cancels without a result, and returns deterministic repository-relative digests and counts without raw content, absolute paths, cache, persistence, transport, or repository mutation.

- [x] Task 3 — Persist one terminal minimized assessment result.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Accept one strict worker result for the pending exact binding and persist only its minimized complete or unsuccessful terminal outcome in the project's authoritative store.
  - Owned surfaces: Strict terminal-result value, pending-to-terminal transition, exact project, repository, root, commit, scanner and limit binding, complete, canceled and failed outcome rules, source-relative finding anchors, result allowlist and size limits, hosted and device-authoritative terminal update parity, stale, duplicate, cross-project and cross-workspace refusal, and no raw source, index, absolute path, credential, or raw diagnostic persistence.
  - Owns: AC-06
  - Proof: Focused result-shape, pending-to-terminal, hosted/device adapter, source-anchor, exact-binding, stale-commit, duplicate, canceled, failed, cross-project, cross-workspace, minimized-field, and raw-content negative tests pass.
  - Delivered: `RepositoryAssessmentResult` accepts only exact command-bound completed, canceled, or allowlisted failed outcomes; caps findings, structure, anchors, counters, line counts, and the aggregate serialized value; and stores no source content, absolute path, credential, index, or raw diagnostic. Pending assessments now own the scanner version and exact limit contract. `RepositoryAssessments.finish_assessment/5` performs one strict pending-to-terminal transition through transactionally locked hosted storage or one serialized device-store compare-and-swap, rechecking current authority and repository binding, rejecting terminal inserts and repeats, and preserving legacy device pending records through strict normalization.

- [x] Task 9 — Reuse only complete exact-commit worker evidence.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Avoid repeating an unchanged completed worker scan without allowing incomplete, failed, canceled, stale, or differently limited evidence to become a hit.
  - Owned surfaces: Worker-local cache value and adapter, complete-only insertion, cache key over project, repository identity, root, exact commit, scanner contract and limit contract, deterministic provenance, incomplete and unsuccessful exclusion, relevant-key invalidation, bounded storage, and no authoritative or hosted raw index copy.
  - Owns: AC-05
  - Proof: Focused complete hit, miss, exact-key reuse, project, repository, root, commit, scanner and limit invalidation, incomplete, failed and canceled exclusion, bounded-storage, restart-policy, and no-hosted-copy tests pass.
  - Delivered: `WorkerRepositoryAssessmentCacheEntry` accepts only strict completed `RepositoryAssessmentResult` evidence, keys it by cache-contract version, project, repository identity, normalized root, full commit, scan protocol, scanner digest, and every limit field, and emits deterministic cache-key and evidence digests. `WorkerRepositoryAssessmentCache` provides an explicitly worker-owned memory-only LRU process bounded by entry count and encoded bytes, revalidates and rebinds a hit to the current command, refuses conflicting, incomplete, failed, canceled, malformed, or oversized values, and deliberately discards all entries on restart. It persists no repository content, raw index, hosted row, device-authoritative value, filesystem entry, or application-supervised state.

- [ ] Task 10 — Propose and append immutable owner-approved profile versions.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Convert one current completed assessment into a strict profile proposal and append an immutable version only through owner approval.
  - Owned surfaces: Profile proposal value, `RepositoryExecutionProfile`, hosted schema and immutable version constraints, hosted and device-authoritative profile-store adapters, exact assessment and commit binding, root and base revision, instruction precedence, normalized commands and required checks, allowed scope, gaps, conflicts and multi-root blockers, owner-only approval or rejection, stale-assessment refusal, and append-only version history.
  - Owns: entity:RepositoryExecutionProfile
  - Proof: Focused proposal normalization, existing-instruction precedence, command, check, scope, gap, conflict, multi-root, hosted/device adapter, owner, stale-assessment, immutable-version, append-only, rejection, and cross-project tests pass.

- [ ] Task 11 — Let the owner review and approve the proposed profile.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 9, Task 10
  - Purpose: Show every managed-runtime field and blocker before an explicit owner approval without making repository instructions appear replaced.
  - Owned surfaces: Completed-assessment and cache-provenance presentation, profile proposal and version history LiveView, root, base revision, instruction precedence, command, required-check, allowed-scope, gap, conflict and multi-root presentation, managed-runtime-only explanation, owner approve and reject interactions, participant read-only access, stale recovery, and focused desktop/mobile browser scenario.
  - Owns: AC-07
  - Proof: Focused LiveView authorization and interaction tests plus one desktop/mobile browser file prove complete field and blocker visibility, repository-instruction authority, managed-runtime-only scope, explicit owner approval or rejection, participant read-only access, and stale refusal.

- [ ] Task 4 — Select one authoritative pilot specification revision.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 11
  - Purpose: Bound adoption to one current authoritative Orchestrator feature without copying specifications or importing repository backlog items.
  - Owned surfaces: Shared-store specification and current revision selector, owner-only pilot selection, stable pilot reference, stale-revision refusal, no specification-document copy, no repository issue or backlog import, hosted and device-authoritative persistence parity, focused LiveView interaction, `capability:repository-approved-pilot` provider, and readiness write-back.
  - Owns: AC-10
  - Proof: Focused specification-store consumer, current and stale revision, owner, participant read-only, hosted/device adapter, stable-reference, no-copy, no-import, LiveView, and browser tests pass.

- [ ] Task 12 — Present independent repository readiness and verification blockers.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 11
  - Purpose: Explain separately what the assistant, specification workflow, autonomous agent, and release may safely do without inventing a reliable check contract.
  - Owned surfaces: Assistant, specification, agent-execution and release readiness value and UI, earliest blocking stage and actionable reason codes, stale commit and changed-root behavior, unresolved instruction and safety conflict behavior, unsupported multi-root behavior, reliable required-check contract gate, verified-completion and `Ready for review` denial, read-only assistant independence, `capability:repository-profile-readiness` provider, and readiness write-back.
  - Owns: AC-08, AC-09, AC-11
  - Proof: Focused stale-commit, changed-root, conflict, safety-conflict, multi-root, missing and unreliable check, assistant independence, earliest-stage reason, LiveView, and browser tests pass.

## Verification Gate

- [ ] Active-slice acceptance criteria AC-01 through AC-11 pass; AC-12 and AC-13 remain owned by `specs/30-repository-execution-profile-completion/`.
- [ ] Hosted and device-authoritative adapter contracts pass.
- [ ] Worker scanner safety, cancellation, cache, and no-mutation suites pass.
- [ ] Authorization and project-isolation suites pass.
- [ ] Desktop and mobile assessment, profile approval, pilot, conflict, and readiness browser scenarios pass.
- [ ] `mix check` and all explicit project code-quality commands pass.
- [ ] `npm --prefix assets ci` and `npm --prefix assets run test:e2e` pass.
- [ ] `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` pass.
- [ ] Specification validator and global capability graph pass.
- [ ] Both focused continuation capabilities are ready for `specs/30-repository-execution-profile-completion/`; Slice 07 consumption remains unimplemented until its explicit `update-spec` change is approved.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
