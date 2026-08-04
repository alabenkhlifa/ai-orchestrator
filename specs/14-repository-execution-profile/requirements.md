# Repository Execution Profile

## Status

Approved

## Outcome

A project owner can authorize a bounded read-only assessment of one mature repository at one exact commit and review and approve a reliable execution profile without changing repository files.

## Users

- Project owners authorizing repository inspection and approving how managed agents work.
- Developers and technical contributors reviewing existing instructions, commands, repository structure, and conflicts.
- Business analysts, product owners, and project managers reading clear assessment and profile explanations without needing to understand repository internals.

## In Scope

- One repository with at least one commit and one user-selected repository root.
- A first or changed-boundary disclosure before repository assessment.
- A short-lived, owner-requested worker preparation that proves the connected repository identity, normalizes one selected root, and resolves its current full commit only after the required processing-boundary confirmation.
- A worker-local, commit-bound, bounded, cancellable, and commit-cached read-only scan.
- High-signal inspection of existing agent instructions, contribution rules, project manifests, CI definitions, test and build commands, and repository structure.
- A structured assessment, one worker-generated minimized profile-proposal envelope, and an owner-approved execution profile.
- Existing repository instructions as the authoritative repository rules.
- Visible conflicts, missing checks, and multi-root blockers before profile approval.

## Out of Scope

- Empty or unborn repository initialization, defined in `specs/16-empty-repository-initialization/`.
- Permanent repository kit installation, update, and removal, defined in `specs/15-repository-sdd-kit-integration/`.
- Whole-repository source upload, hosted source index, automatic backlog import, issue-provider synchronization, or backlog rewriting.
- Editing repository instructions, CI, manifests, source, branches, hooks, settings, or credentials.
- Automatically inventing missing verification commands or resolving a safety conflict.
- Multiple independently configured roots or monorepo subprojects in the first executable slice.
- Changing the approved Slice 07 execution-manifest contract in this specification.
- Pilot selection, independent readiness, privacy and lifecycle enforcement, and final `capability:repository-execution-profile` publication, which are owned by `specs/30-repository-execution-profile-completion/` after this slice publishes `capability:repository-profile-review`.

## Primary Workflow

1. A project owner opens SDD adoption for a connected repository that has at least one commit.
2. The product explains what the worker will inspect, what remains worker-local, what structured results may enter authoritative project storage, and whether any configured model or processor receives approved content.
3. The owner confirms the first or materially changed processing boundary before any repository command is issued.
4. Through the authorized worker boundary, the owner selects one root inside the connected repository. The worker proves the repository identity, normalizes the root, resolves its current full commit, and returns only a short-lived minimized binding without scanning repository content.
5. The product shows the verified repository, selected root, exact commit, limits, and processing boundary, then the owner explicitly authorizes assessment.
6. The authorized worker scans only the approved high-signal surfaces under configured limits, reports progress, supports cancellation, and reuses an unchanged commit cache without uploading a whole-repository index.
7. While the approved high-signal evidence remains worker-local, the worker deterministically derives one cache-stable minimized profile-proposal payload containing only normalized commands, required checks, allowed scope, gaps, conflicts, and multi-root blockers; ambiguous or unsupported evidence becomes a visible blocker rather than a guess.
8. For each fresh or cached delivery, the worker binds that payload to the current exact assessment command and Task 9 provenance as one proposal envelope. The completed assessment, cache provenance, and current envelope are stored in the project's authoritative storage mode without transferring raw repository content or the scan index.
9. The product shows detected instructions, verification evidence, repository structure, minimized cache provenance, every proposal field, gaps, and conflicts with source anchors. Existing repository instructions remain authoritative, and the owner explicitly approves or rejects the proposal.
10. `specs/30-repository-execution-profile-completion/` presents assistant, specification, agent-execution, and release readiness separately and lets the owner select one current authoritative specification revision as the pilot without importing repository backlog.
11. After that continuation's privacy, lifecycle, and compatibility proof passes, the approved profile becomes available to managed runtime consumers without changing the repository; permanent kit integration remains a separate workflow.

## Business Rules

- Assessment requires a repository with at least one commit. An unborn local repository routes to empty-repository initialization because the existing local repository identity requires a root commit.
- Only the project owner may confirm the processing boundary, request repository-binding preparation, authorize a first assessment, approve or replace an execution profile, or change its root.
- Repository-binding preparation requires a currently authorized paired worker. A device-authoritative project uses its owning device workspace; a hosted project requires the owner to explicitly select a currently available device workspace and worker for this operation. Neither path creates an implicit account-to-device association.
- The worker must prove that the selected repository is the project's connected canonical repository before it returns a binding. Unknown, malformed, mismatched, cross-project, cross-workspace, unavailable, expired, replayed, or changed repository state fails closed.
- A binding preparation contains only the project and repository identities, normalized repository-relative root, full exact commit, scanner-contract and disclosure digests, opaque worker reference, nonce, and issue and expiry times. Absolute paths, repository content, Git history, remote URLs, credentials, and raw worker diagnostics remain worker-local. The preparation is short-lived, single-use, not authoritative project data, and creates no durable hosted copy for a device-authoritative project.
- Assessment authorization consumes the preparation only after the worker revalidates that its repository identity, root, and exact commit remain unchanged. A stale preparation issues no scan command and persists no assessment.
- The assessment is bound to one exact repository commit and one normalized root contained within the connected repository.
- The first slice supports one root. A detected multi-root or monorepo structure remains visible and blocks autonomous execution when one reliable root cannot represent the pilot.
- Scanning is read-only, bounded by configured file, byte, time, and path limits, cancellable, and cached only by project, repository identity, selected root, scanner contract version, and exact commit.
- The worker inspects only approved high-signal instruction, contribution, manifest, CI, check, and structure surfaces. It must not traverse ignored secrets, dependency stores, build outputs, binary content, or unrelated source to build a hosted index.
- Raw repository content and the scan index remain worker-local. The authoritative project store receives only the minimized structured assessment, source-relative evidence anchors, outcome metadata, the strict minimized proposal envelope, the approved profile, and any explicitly disclosed necessary excerpt.
- The authorized worker, not the control plane, owner input, or a model processor, derives the proposal payload deterministically from the approved high-signal scan evidence without executing repository content. It may emit only normalized `commands`, `required_checks`, `allowed_scope`, `gaps`, `conflicts`, and `multi_root_blockers`; missing or ambiguous evidence must produce stable blocker codes instead of invented commands or checks.
- A successful fresh scan and an unchanged complete-cache hit return the same exact six-field proposal payload and payload digest. That cached value is bound only to Task 9's reusable cache key and evidence digest; it contains no assessment id, disclosure digest, or worker reference.
- Every worker delivery rebuilds a current proposal envelope by binding the cache-stable payload to the current project, repository identity, selected root, exact commit, scanner and limit contracts, assessment command, cache-key digest, evidence digest, payload digest, and envelope digest. A cached or caller-supplied prior assessment binding is invalid. Canceled and failed assessments persist no proposal envelope.
- A completed assessment records the worker-reported cache source (`fresh_scan` or `complete_cache`), deterministic cache-key and evidence digests, whether the complete evidence remained cached, and the exact bound proposal-envelope reference. The product must not infer provenance or proposal fields from assessment contents.
- A completion created before either minimized handoff, or received without verifiable worker-reported provenance and proposal-envelope bindings, cannot be backfilled or used for a new profile approval. The owner must run a new assessment under the current contract.
- The product must show the processing disclosure before the first assessment and again only when the worker, model, processor, content-transfer, or retention boundary changes.
- Canceling or failing an assessment creates no approved profile and does not reuse incomplete results as a successful cache entry.
- Existing `AGENTS.md`, `CLAUDE.md`, contribution rules, CI requirements, security rules, and project conventions remain authoritative repository instructions.
- The review workflow reconstructs Task 10's transient proposal only from the persisted exact envelope and assessment-owned binding. Neither a browser, control-plane caller, participant, nor owner may supply replacement proposal fields. The proposal may normalize discovered commands and scope but cannot silently weaken, replace, or reinterpret an existing repository instruction.
- A conflict between existing instructions and autonomous execution must remain visible and block agent-execution readiness until the owner resolves it in the repository or approves a compatible documented profile. A safety conflict cannot be overridden in the product.
- A conflict that blocks autonomous execution does not by itself block the read-only project assistant from answering within its authorized tools and evidence.
- Missing or unreliable required checks blocks verified completion and `Ready for review`. The product must not invent a passing verification contract; an approved project check contract is required before a managed agent can make that claim.
- Assistant readiness, specification readiness, agent-execution readiness, and release readiness are independent states with reasons and the earliest blocked stage.
- Pilot selection references one current authoritative project specification and revision from `capability:project-specification-store`; it does not copy the documents or create another specification identity.
- Repository issues, tickets, TODOs, and backlog items remain untouched. Import requires a future explicit workflow that previews scope and duplicates before mutation.
- Managed runtime skills and authoritative specification revisions are sufficient for Orchestrator-managed SDD. Permanent repository files are not required.
- Before Slice 07 consumes `capability:repository-execution-profile`, its approved execution-manifest requirements, design, tasks, and capability edge must be changed through `update-spec` after the current Slice 07 work completes.
- Assessment, proposal-envelope, and profile data are confidential project data, follow the project's authoritative storage mode, are available only to current authorized project participants according to role, and are prohibited from analytics, advertising, model training, or unrelated reuse.
- This specification owns assessment completion, exact-commit caching, the minimized proposal-envelope handoff, and owner-approved profile versions. `specs/30-repository-execution-profile-completion/` owns pilot selection, independent readiness, the separately verifiable privacy and lifecycle controls, and final managed-runtime capability publication without redefining the assessment, envelope, or profile authority.

## Acceptance Criteria

- [AC-01] Given a connected repository with at least one commit and a fresh worker-verified binding, when the owner reviews assessment start, then the product shows the one normalized root and current full exact commit without modifying the repository.
- [AC-02] Given assessment would cross a new or changed processing boundary, when the owner continues, then the product discloses inspected surfaces, local and transferred data, processors, retention, and purpose and issues no repository command until the owner explicitly confirms that boundary.
- [AC-03] Given an authorized assessment starts, when the worker scans, then it reads only approved high-signal surfaces under configured file, byte, path, and time limits and reports bounded progress.
- [AC-04] Given an assessment is canceled or fails, when processing stops, then no approved profile or successful cache entry is created and repository state is unchanged.
- [AC-05] Given the same root, scanner contract, and exact commit were completely assessed, when assessment is requested again, then the worker may reuse the complete cache; any relevant change requires a new assessment.
- [AC-06] Given existing instructions, commands, CI rules, or repository structure are detected, when results appear, then findings include worker-verified source-relative anchors and existing repository instructions remain authoritative.
- [AC-07] Given the worker produced a strict cache-stable profile-proposal payload from the exact completed evidence and bound it to the current assessment as one envelope, when the owner reviews it, then the completed assessment and cache provenance, root, base revision, instruction precedence, required checks, project commands, allowed scope, gaps, conflicts, and multi-root blockers are visible before approval, and no review caller may replace those fields or reuse a prior assessment binding.
- [AC-08] Given a stale commit, changed root, unresolved instruction conflict, unsupported multi-root boundary, or missing reliable checks, when approval or readiness is evaluated, then the affected agent-execution or verification state remains blocked with an actionable reason.
- [AC-09] Given a repository conflict prevents autonomous execution, when the read-only assistant is otherwise authorized, then assistant readiness remains independently available and does not claim agent-execution readiness.
- [AC-10] Given the owner selects a pilot, when selection commits, then it references one current authoritative specification and revision and imports or changes no repository backlog item.
- [AC-11] Given no reliable approved check contract exists, when a run result is evaluated, then verified completion and `Ready for review` remain unavailable until that contract is approved and its proof passes.
- [AC-12] Given source scanning, cache, findings, profile, or disclosure records are inspected, when privacy and security proof runs, then raw source and the index remain worker-local, authoritative data is minimized and access-controlled, and no analytics or secondary use exists.
- [AC-13] Given an approved profile and pilot feature, when managed-runtime compatibility is verified, then the exact profile can be supplied with authoritative SDD revisions and versioned runtime skills without creating or changing repository files.

## Open Questions

- None.
