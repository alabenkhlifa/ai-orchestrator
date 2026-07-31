# Repository Execution Profile

## Status

Approved

## Outcome

A project owner can authorize a bounded read-only assessment of one mature repository at one exact commit, review and approve a reliable execution profile, and select one pilot feature for managed SDD work without changing repository files or importing the existing backlog.

## Users

- Project owners authorizing repository inspection and approving how managed agents work.
- Developers and technical contributors reviewing existing instructions, commands, repository structure, and conflicts.
- Business analysts, product owners, and project managers selecting a pilot feature and reading clear readiness explanations without needing to understand repository internals.

## In Scope

- One repository with at least one commit and one user-selected repository root.
- A first or changed-boundary disclosure before repository assessment.
- A worker-local, commit-bound, bounded, cancellable, and commit-cached read-only scan.
- High-signal inspection of existing agent instructions, contribution rules, project manifests, CI definitions, test and build commands, and repository structure.
- A structured assessment and owner-approved execution profile.
- Existing repository instructions as the authoritative repository rules.
- Visible conflicts, missing checks, and separate assistant, specification, agent-execution, and release readiness.
- Selection of one existing Orchestrator feature specification as the pilot; unrelated repository backlog remains untouched.
- Managed runtime SDD compatibility without permanent repository mutation.

## Out of Scope

- Empty or unborn repository initialization, defined in `specs/16-empty-repository-initialization/`.
- Permanent repository kit installation, update, and removal, defined in `specs/15-repository-sdd-kit-integration/`.
- Whole-repository source upload, hosted source index, automatic backlog import, issue-provider synchronization, or backlog rewriting.
- Editing repository instructions, CI, manifests, source, branches, hooks, settings, or credentials.
- Automatically inventing missing verification commands or resolving a safety conflict.
- Multiple independently configured roots or monorepo subprojects in the first executable slice.
- Changing the approved Slice 07 execution-manifest contract in this specification.

## Primary Workflow

1. A project owner opens SDD adoption for a connected repository that has at least one commit.
2. The product explains what the worker will inspect, what remains worker-local, what structured results may enter authoritative project storage, and whether any configured model or processor receives approved content.
3. The owner selects one repository root and authorizes assessment of the current exact commit.
4. The authorized worker scans only the approved high-signal surfaces under configured limits, reports progress, supports cancellation, and reuses an unchanged commit cache without uploading a whole-repository index.
5. The product shows detected instructions, project commands, verification evidence, repository structure, gaps, and conflicts with source anchors.
6. The product proposes an execution profile. Existing repository instructions remain authoritative, and the owner reviews and explicitly approves or rejects the proposal.
7. The product shows assistant, specification, agent-execution, and release readiness separately.
8. The owner selects one current Orchestrator feature specification as the pilot. No repository issue or backlog item is imported unless a separate explicit import workflow is later authorized.
9. The approved profile becomes available to managed runtime consumers without changing the repository; permanent kit integration is offered only through its separate workflow after the pilot reaches its required milestone.

## Business Rules

- Assessment requires a repository with at least one commit. An unborn local repository routes to empty-repository initialization because the existing local repository identity requires a root commit.
- Only the project owner may authorize a first assessment, approve or replace an execution profile, change its root, or select the pilot feature.
- The assessment is bound to one exact repository commit and one normalized root contained within the connected repository.
- The first slice supports one root. A detected multi-root or monorepo structure remains visible and blocks autonomous execution when one reliable root cannot represent the pilot.
- Scanning is read-only, bounded by configured file, byte, time, and path limits, cancellable, and cached only by project, repository identity, selected root, scanner contract version, and exact commit.
- The worker inspects only approved high-signal instruction, contribution, manifest, CI, check, and structure surfaces. It must not traverse ignored secrets, dependency stores, build outputs, binary content, or unrelated source to build a hosted index.
- Raw repository content and the scan index remain worker-local. The authoritative project store receives only the minimized structured assessment, approved profile, source-relative evidence anchors, outcome metadata, and any explicitly disclosed necessary excerpt.
- The product must show the processing disclosure before the first assessment and again only when the worker, model, processor, content-transfer, or retention boundary changes.
- Canceling or failing an assessment creates no approved profile and does not reuse incomplete results as a successful cache entry.
- Existing `AGENTS.md`, `CLAUDE.md`, contribution rules, CI requirements, security rules, and project conventions remain authoritative repository instructions.
- A proposed profile may normalize discovered commands and scope but cannot silently weaken, replace, or reinterpret an existing repository instruction.
- A conflict between existing instructions and autonomous execution must remain visible and block agent-execution readiness until the owner resolves it in the repository or approves a compatible documented profile. A safety conflict cannot be overridden in the product.
- A conflict that blocks autonomous execution does not by itself block the read-only project assistant from answering within its authorized tools and evidence.
- Missing or unreliable required checks blocks verified completion and `Ready for review`. The product must not invent a passing verification contract; an approved project check contract is required before a managed agent can make that claim.
- Assistant readiness, specification readiness, agent-execution readiness, and release readiness are independent states with reasons and the earliest blocked stage.
- Pilot selection references one current authoritative project specification and revision from `capability:project-specification-store`; it does not copy the documents or create another specification identity.
- Repository issues, tickets, TODOs, and backlog items remain untouched. Import requires a future explicit workflow that previews scope and duplicates before mutation.
- Managed runtime skills and authoritative specification revisions are sufficient for Orchestrator-managed SDD. Permanent repository files are not required.
- Before Slice 07 consumes `capability:repository-execution-profile`, its approved execution-manifest requirements, design, tasks, and capability edge must be changed through `update-spec` after the current Slice 07 work completes.
- Assessment and profile data are confidential project data, follow the project's authoritative storage mode, are available only to current authorized project participants according to role, and are prohibited from analytics, advertising, model training, or unrelated reuse.

## Acceptance Criteria

- [AC-01] Given a connected repository with at least one commit, when the owner opens assessment, then the product shows one-root selection and the current exact commit without modifying the repository.
- [AC-02] Given assessment would cross a new or changed processing boundary, when the owner continues, then the product discloses inspected surfaces, local and transferred data, processors, retention, and purpose before authorization.
- [AC-03] Given an authorized assessment starts, when the worker scans, then it reads only approved high-signal surfaces under configured file, byte, path, and time limits and reports bounded progress.
- [AC-04] Given an assessment is canceled or fails, when processing stops, then no approved profile or successful cache entry is created and repository state is unchanged.
- [AC-05] Given the same root, scanner contract, and exact commit were completely assessed, when assessment is requested again, then the worker may reuse the complete cache; any relevant change requires a new assessment.
- [AC-06] Given existing instructions, commands, CI rules, or repository structure are detected, when results appear, then findings include worker-verified source-relative anchors and existing repository instructions remain authoritative.
- [AC-07] Given the scan proposes an execution profile, when the owner reviews it, then root, base revision, instruction precedence, required checks, project commands, allowed scope, gaps, and conflicts are visible before approval.
- [AC-08] Given a stale commit, changed root, unresolved instruction conflict, unsupported multi-root boundary, or missing reliable checks, when approval or readiness is evaluated, then the affected agent-execution or verification state remains blocked with an actionable reason.
- [AC-09] Given a repository conflict prevents autonomous execution, when the read-only assistant is otherwise authorized, then assistant readiness remains independently available and does not claim agent-execution readiness.
- [AC-10] Given the owner selects a pilot, when selection commits, then it references one current authoritative specification and revision and imports or changes no repository backlog item.
- [AC-11] Given no reliable approved check contract exists, when a run result is evaluated, then verified completion and `Ready for review` remain unavailable until that contract is approved and its proof passes.
- [AC-12] Given source scanning, cache, findings, profile, or disclosure records are inspected, when privacy and security proof runs, then raw source and the index remain worker-local, authoritative data is minimized and access-controlled, and no analytics or secondary use exists.
- [AC-13] Given an approved profile and pilot feature, when managed-runtime compatibility is verified, then the exact profile can be supplied with authoritative SDD revisions and versioned runtime skills without creating or changing repository files.

## Open Questions

- None.
