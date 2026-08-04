# SDD Adoption Coordination Tasks

## Status

Blocked

The coordination task waits for the three child capabilities. The umbrella has no independent implementation work.

## Active Slice

Reconcile the mature-repository execution profile, optional repository kit, and empty-repository initialization capabilities into one release-ready adoption contract without duplicating child implementation.

## Cross-Specification Dependencies

Requires:

- `capability:repository-execution-profile` — provider `specs/30-repository-execution-profile-completion#Task 2` — required before `Task 1`.
- `capability:repository-sdd-kit` — provider `specs/15-repository-sdd-kit-integration#Task 5` — required before `Task 1`.
- `capability:initialized-sdd-repository` — provider `specs/16-empty-repository-initialization#Task 6` — required before `Task 1`.

Provides:

- `capability:sdd-adoption-coordination` — ready after `Task 1`.

## Task Size Gate

- The coordination task is standard because it produces one independently provable release-coordination outcome and changes no application implementation.
- No exception is required.

## Implementation Boundary

Included:

- Cross-child capability reconciliation, shared terminology verification, and combined release evidence.
- Confirmation that the umbrella owns no duplicate implementation or authoritative data.

Excluded:

- Repository assessment, mutation, initialization, worker, storage, assistant, board, or agent implementation.

Deferred after this slice:

- Additional repository-adoption workflows not owned by the three current children.

Release gates:

- Every deployment-specific privacy, processor, region, transfer, notice, retention-enforcement, incident, and accountable-review gate from the child specifications.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Reconcile child capability and release contracts.
  - Size: Standard
  - Depends on: none
  - Purpose: Prove the three independently implemented adoption paths compose without duplicate authority, hidden mutation, or readiness ambiguity.
  - Owned surfaces: `capability:sdd-adoption-coordination` provider and readiness write-back, cross-child capability graph, shared SDD meaning, four-axis readiness terminology, source-of-truth compatibility, trust-boundary compatibility, and combined release checklist.
  - Owns: AC-01, AC-02, AC-03
  - Proof: Individual child validators and the global graph pass; a manual contract review confirms no duplicated implementation or authoritative specification store; coordinated browser evidence proves correct routing and separate readiness presentation before `capability:sdd-adoption-coordination` readiness is recorded.

## Verification Gate

- [ ] All three required child capabilities are ready with recorded proof.
- [ ] Individual child specification validators pass.
- [ ] The global cross-specification graph passes without a cycle or ambiguous provider.
- [ ] Coordinated routing and four-axis readiness browser proof passes.
- [ ] Source-of-truth, privacy, and mutation boundaries agree across children.
- [ ] Release gates remain reported separately from implementation readiness.

## Blocked Decisions

- `capability:repository-execution-profile`, `capability:repository-sdd-kit`, and `capability:initialized-sdd-repository` are unavailable; this blocks Task 1 implementation.

## Progress Log

See [progress.md](progress.md).
