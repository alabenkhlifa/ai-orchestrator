# Repository Execution Profile Tasks

## Status

Verified

Every task is complete and the verification gate passes: `mix check` with the full suite, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, the desktop and mobile browser matrix, the production asset and release build, and both specification validators. `capability:repository-profile-review` is ready for `specs/30-repository-execution-profile-completion/`.

Release readiness is separate and remains blocked. A production managed run still requires the approved Slice 07 consumer edge and manifest contract, a live configured worker smoke proof for each supported deployment profile, and the deployment-specific controller, processor, model, worker, region, transfer, notice, retention-enforcement, incident, and accountable privacy or legal evidence. Pilot selection, independent readiness, privacy, lifecycle, and final capability publication continue in `specs/30-repository-execution-profile-completion/`. Slice 07 consumption remains a later explicit `update-spec` agreement change.

## Active Slice

Assess one mature repository at one exact commit through a bounded read-only worker scan, persist one exact minimized worker proposal envelope, and let the owner review and approve one immutable managed-runtime profile without changing repository files.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 8`.
- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 7`.

Provides:

- `capability:repository-profile-review` — ready after `Task 11`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- All eleven tasks are standard, own one primary outcome, have at most three acceptance criteria and two entities, and have focused proof expected to run in about ten minutes.
- The longest `Depends on:` path contains eight tasks: Task 7, Task 8, Task 2, Task 3, Task 9, Task 13 or Task 14, Task 15, then Task 11.
- No exception is required.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One-root assessment start, disclosure, persistence, and readiness surface.
- Short-lived disclosure-confirmed repository-binding preparation that proves repository identity, normalized root, and current full commit without scanning content.
- Worker-local high-signal scanning, exact-commit cache, cancellation, and structured findings.
- Terminal minimized assessment results and exact-commit cache reuse.
- Deterministic worker-local proposal derivation, strict minimized authoritative envelope persistence, and exact assessment, cache and evidence binding.
- Owner-reviewed immutable execution-profile approval.

Excluded:

- Repository mutation, kit installation, empty-repository initialization, whole-source indexing or upload, backlog import, and automatic check invention.
- Slice 07 execution-manifest behavior changes.
- Pilot selection, independent readiness, privacy and lifecycle enforcement, final managed-runtime serialization, and `capability:repository-execution-profile` publication, owned by `specs/30-repository-execution-profile-completion/`.

Deferred after this slice:

- Multiple roots, monorepo subprojects, automatic backlog import, and issue-provider synchronization.
- `specs/30-repository-execution-profile-completion/` consumes `capability:repository-profile-review`, owns pilot selection and independent readiness, enforces AC-12, and owns AC-13 plus final capability publication.
- Slice 07 `update-spec` work that consumes `capability:repository-execution-profile` before managed execution.

Release gates:

- A future approved Slice 07 consumer edge and manifest contract before a production managed run relies on the profile.
- Live configured worker smoke proof for each supported deployment profile.
- Deployment-specific controller, processor, model, worker, region, transfer, notice, retention-enforcement, incident, and accountable privacy or legal evidence.

Traceability:

- Deferred criteria: AC-08, AC-09, AC-10, AC-11, AC-12, AC-13
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Parallel Implementation Ownership

- Implementation is partitioned by ownership between `specs/11-ai-runtime-governance#Task 7` and `specs/14-repository-execution-profile#Task 7`, `#Task 8`, plus `#Task 1` (Tasks 14.7, 14.8, and 14.1).
- `specs/11-ai-runtime-governance#Task 7` exclusively owns the personal AI worker transport, including its socket, channel, and any Endpoint registration.
- `specs/14-repository-execution-profile#Task 7` exclusively owns the assessment-specific repository-binding value and metadata adapter after disclosure confirmation. It must not modify the personal AI socket, channel, or Endpoint; any shared transport integration is serialized after Slice 11 Task 7.
- `specs/14-repository-execution-profile#Task 8` exclusively owns repository-assessment persistence and authorization, including its migration, hosted and device-authoritative storage contracts, owner-only start service, and focused domain and adapter proof.
- `specs/14-repository-execution-profile#Task 1` exclusively owns repository-assessment UI, including the route and project navigation, assessment LiveView, disclosure and exact-binding presentation, and focused browser test.
- `specs/14-repository-execution-profile#Task 14` exclusively owns worker-local proposal-payload derivation, complete-cache parity, and current-command envelope binding. It may update only the assessment-specific worker scan result and cache boundaries and must not modify authoritative persistence, the personal AI socket, channel, Endpoint, or generic worker transport owned by Slice 11.
- `specs/14-repository-execution-profile#Task 15` exclusively owns authoritative proposal-envelope persistence and the changed transfer disclosure. It may update only the hosted/device assessment-store and disclosure boundaries needed for that handoff and must not modify worker transport or Task 11 review UI.
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
  - Depends on: Task 8
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

- [x] Task 13 — Persist truthful minimized cache provenance with completed results.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 9
  - Purpose: Carry the actual worker cache outcome into the completed authoritative assessment so later owner and participant review never infers whether evidence was freshly scanned or reused.
  - Owned surfaces: Strict cache-provenance value, `fresh_scan` and `complete_cache` source allowlist, exact command cache-key digest, exact completed-evidence digest, cache-stored flag, completed-result handoff, hosted schema addition, hosted and device-authoritative assessment persistence parity, legacy completion and profile-proposal refusal with reassessment requirement, missing, malformed, inferred, mismatched, unsuccessful, stale, duplicate, cross-project and cross-workspace refusal, and no raw cache entry, repository index, repository source, credential, absolute path or diagnostic persistence.
  - Owns: none (cache-provenance handoff invariant)
  - Proof: Focused provenance-shape, fresh-scan, complete-cache, cache-not-stored, exact command and evidence binding, hosted/device adapter, restart, legacy-completion reassessment, proposal refusal, missing, malformed, inferred, mismatch, canceled, failed, stale, duplicate, cross-project, cross-workspace, minimized-field, and raw-content negative tests pass.
  - Delivered: `RepositoryAssessmentCacheProvenance` centralizes the exact Task 9 cache-key and evidence digest contract and accepts only worker-reported `fresh_scan` or `complete_cache` outcomes with a strict cache-stored flag. Completed assessment finishing now requires that value and recomputes both bindings before one atomic hosted or device-authoritative transition persists only the four minimized fields; canceled and failed outcomes persist none. The additive hosted migration constrains all-or-none, source, digest, complete-cache and completed-only shapes without backfilling legacy rows. Stored completions revalidate provenance against their reconstructed command and result before proposal or approval, and legacy or corrupted completions remain readable but require a new assessment.

- [x] Task 14 — Derive and cache the minimized profile-proposal payload.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 9
  - Purpose: Derive one deterministic minimized proposal payload while exact scan evidence remains worker-local, return the identical payload with an unchanged complete-cache hit, and rebuild the delivery envelope for the current assessment command.
  - Owned surfaces: `RepositoryExecutionProfileProposalPayload` worker-local value and payload digest contract, deterministic derivation of normalized commands, required checks, allowed scope, gaps, conflicts and multi-root blockers from approved high-signal evidence, stable ambiguity and missing-evidence blocker codes, Task 9 cache-key and evidence binding, current command, assessment, repository, root, commit, scanner and limit envelope binding, complete-cache entry extension, fresh-scan/cache-hit payload parity, prior-assessment binding refusal, malformed, mismatched, incomplete, canceled and failed exclusion, and no model call, source excerpt return, index transfer, absolute path, credential, raw diagnostic, analytics, repository mutation, authoritative persistence, or Slice 11 transport change.
  - Owns: entity:RepositoryExecutionProfileProposalPayload
  - Proof: Focused deterministic derivation, explicit command and required-check evidence, allowed-scope and multi-root evidence, ambiguity and missing-evidence blockers, malicious-content non-execution, fresh/cache payload and digest parity, current-command envelope rebinding, exact payload, evidence, command and result digest binding, prior-binding refusal, malformed, mismatch, incomplete, canceled, failed, raw-content negative, no-model, no-analytics, no-authoritative-write, no-repository-write, and no-Slice-11-transport tests pass.
  - Delivered: `RepositoryExecutionProfileProposalPayload` validates exact completed high-signal evidence while its raw content remains inside the worker, deterministically minimizes explicit commands, required checks, allowed scope, gaps, conflicts and multi-root blockers, and binds the stable payload digest to Task 9's cache-key and evidence digests. `WorkerRepositoryAssessmentCache` stores only that minimized payload beside complete evidence, returns the byte-identical payload on an exact hit, and rebuilds a transient `WorkerRepositoryExecutionProfileProposalEnvelope` for the current assessment command, disclosure, worker, limits and completed-result digest. Missing, ambiguous, malicious, malformed, mismatched, incomplete, canceled, failed, legacy and prior-bound values fail closed without repository execution or mutation, model or analytics calls, authoritative persistence, raw-content transfer, or Slice 11 transport changes.

- [x] Task 15 — Persist the exact minimized proposal envelope in authoritative project storage.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 13, Task 14
  - Purpose: Persist only the current-assessment envelope built from the cache-stable worker payload and truthful completed cache provenance so owners and participants can review it after the worker disconnects.
  - Owned surfaces: `RepositoryExecutionProfileProposalEnvelope` authoritative value, `RepositoryExecutionProfileProposalPayload` consumer, completed-assessment and Task 13 provenance binding, exact project, repository, root, commit, scanner, limit, cache-key, evidence, payload and envelope digest validation, current-command and prior-binding refusal, changed processing-disclosure transfer record, completed-only hosted and device-authoritative envelope-store parity, strict assessment-to-envelope read interface, restart persistence, legacy, missing, malformed, caller-supplied, mismatch, stale, unsuccessful, duplicate, cross-project and cross-workspace refusal, and no raw source, excerpt, index, absolute path, credential, diagnostic, model call, analytics, cross-authority fallback, repository mutation, worker transport, or Task 11 UI change.
  - Owns: entity:RepositoryExecutionProfileProposalEnvelope
  - Proof: Focused exact assessment and provenance binding, disclosure change, hosted/device adapter, restart, participant-readable value, legacy, missing, malformed, caller-replacement, mismatch, stale, canceled, failed, duplicate, cross-project, cross-workspace, no-hosted-copy, raw-content negative, no-model, no-analytics, no-repository-write, and no-worker-transport tests pass.
  - Delivered: `RepositoryExecutionProfileProposalEnvelope` persists only the six managed-runtime proposal fields with their cache-key, evidence, result, payload, and envelope digests, and rebuilds the worker delivery from the completed assessment before any write or read, so a replaced field, a foreign command, or a prior assessment binding fails closed. Completing an assessment now carries that exact envelope through one hosted transaction or one device-store call that stores both values or neither, while canceled and failed outcomes refuse an envelope and persist none and a completion stored without a verifiable one can never gain it. `AssessmentStore.fetch_envelope/3` revalidates the stored value against its assessment for the hosted owner, an active hosted participant, and the owning device workspace, survives device-store restart, creates no hosted copy for a device project, and refuses legacy, missing, malformed, caller-replaced, mismatched, stale, unsuccessful, duplicate, cross-project, and cross-workspace access. The additive hosted table is immutable by trigger and constrained to one envelope per assessment; no source content, excerpt, index, absolute path, credential, diagnostic, model call, analytics, repository write, or worker-transport change was introduced. The transfer disclosure now names the minimized envelope, which re-derives the content-addressed disclosure digest and requires a new boundary confirmation.

- [x] Task 10 — Propose and append immutable owner-approved profile versions.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Convert one current completed assessment into a strict profile proposal and append an immutable version only through owner approval.
  - Owned surfaces: Profile proposal value, `RepositoryExecutionProfile`, hosted schema and immutable version constraints, hosted and device-authoritative profile-store adapters, exact assessment and commit binding, root and base revision, instruction precedence, normalized commands and required checks, allowed scope, gaps, conflicts and multi-root blockers, owner-only approval or rejection, stale-assessment refusal, and append-only version history.
  - Owns: entity:RepositoryExecutionProfile
  - Proof: Focused proposal normalization, existing-instruction precedence, command, check, scope, gap, conflict, multi-root, hosted/device adapter, owner, stale-assessment, immutable-version, append-only, rejection, and cross-project tests pass.
  - Delivered: `RepositoryExecutionProfileProposal` derives immutable repository binding, base revision, assessment digest, and repository-instruction precedence from only the newest completed authoritative assessment, then strictly normalizes evidence-supported commands, required checks, allowed scope, gaps, conflicts, and multi-root blockers without accepting source content, credentials, or absolute paths. `RepositoryExecutionProfile` and the hosted migration append immutable project versions protected by exact assessment/proposal uniqueness, positive-version and digest constraints, and a database update-rejection trigger. Owner-only approval or rejection rechecks current project authority, repository identity, newest assessment, and proposal digest; rejection writes nothing and identical approval delivery is idempotent. Hosted writes are transactionally locked, while the device adapter appends atomically through the worker-owned DETS store, survives restart, and creates no hosted copy.

- [x] Task 11 — Let the owner review and approve the proposed profile.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 10, Task 15
  - Purpose: Show every managed-runtime field and blocker before an explicit owner approval without making repository instructions appear replaced.
  - Owned surfaces: Completed-assessment, cache-provenance and authoritative proposal-envelope presentation, envelope-only transient proposal reconstruction, profile proposal and version history LiveView, root, base revision, instruction precedence, command, required-check, allowed-scope, gap, conflict and multi-root presentation, managed-runtime-only explanation, owner approve and reject interactions, participant read-only access, stale recovery, `capability:repository-profile-review` provider and readiness write-back, and focused desktop/mobile browser scenario.
  - Owns: AC-07
  - Proof: Focused LiveView authorization and interaction tests plus one desktop/mobile browser file prove complete field and blocker visibility, caller-replacement refusal, repository-instruction authority, managed-runtime-only scope, explicit owner approval or rejection, participant read-only access, stale refusal, and profile-review capability readiness.
  - Delivered: `RepositoryAssessments.profile_review/3` resolves the newest assessment, requires it to be the completed one, reads its verified authoritative envelope, and rebuilds Task 10's transient proposal from the envelope's six proposal fields alone, so no browser, control-plane, participant, or owner input can replace a managed-runtime field or reuse a prior assessment binding. `RepositoryExecutionProfileLive` serves the hosted and device routes and shows the completed assessment, cache source, cache-stored flag, cache-key and evidence digests, root, base revision, instruction precedence, commands, required checks, allowed scope, gaps, conflicts, and multi-root blockers before any decision, with blockers visually distinct and a managed-runtime-only statement that the profile changes no repository file, instruction, CI rule, or branch policy. Owner-only approve and reject actions append one immutable version or write nothing; a newer assessment, a replaced envelope, and a legacy completion each fall back to an actionable unavailable state that offers no approval. Hosted participants read the same fields without a decision control, through the assessment-store `latest` and profile-store `list` reads widened to the existing viewer rule. Project navigation is unchanged and remains owned by Task 1.

## Verification Gate

- [x] Active-slice acceptance criteria AC-01 through AC-07 pass; AC-08 through AC-13 remain owned by `specs/30-repository-execution-profile-completion/`.
- [x] Hosted and device-authoritative adapter contracts pass.
- [x] Worker scanner safety, cancellation, cache, and no-mutation suites pass.
- [x] Authorization and project-isolation suites pass.
- [x] Desktop and mobile assessment and profile-approval browser scenarios pass.
- [x] `mix check` and all explicit project code-quality commands pass.
- [x] `npm --prefix assets ci` and `npm --prefix assets run test:e2e` pass.
- [x] `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` pass.
- [x] Specification validator and global capability graph pass.
- [x] `capability:repository-profile-review` is ready for `specs/30-repository-execution-profile-completion/`; Slice 07 consumption remains unimplemented until its explicit `update-spec` change is approved.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
