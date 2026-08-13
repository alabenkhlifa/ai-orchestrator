# SDD Adoption Coordination Tasks

## Status

Verified

The three required child capabilities are ready, Task 1 reconciled their capability, terminology, source-of-truth, and trust-boundary contracts with no duplication or conflict found, and `capability:sdd-adoption-coordination` is published. See `progress.md` for the full receipt.

## Active Slice

Reconcile the mature-repository execution profile, optional repository kit, and empty-repository initialization capabilities into one release-ready adoption contract without duplicating child implementation.

## Cross-Specification Dependencies

Requires:

- `capability:repository-execution-profile` — provider `specs/30-repository-execution-profile-completion#Task 2` — required before `Task 1`.
- `capability:repository-sdd-kit` — provider `specs/15-repository-sdd-kit-integration#Task 9` — required before `Task 1`.
- `capability:initialized-sdd-repository` — provider `specs/16-empty-repository-initialization#Task 7` — required before `Task 1`.

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

- [x] Task 1 — Reconcile child capability and release contracts.
  - Size: Standard
  - Depends on: none
  - Purpose: Prove the three independently implemented adoption paths compose without duplicate authority, hidden mutation, or readiness ambiguity.
  - Owned surfaces: `capability:sdd-adoption-coordination` provider and readiness write-back, cross-child capability graph, shared SDD meaning, four-axis readiness terminology, source-of-truth compatibility, trust-boundary compatibility, and combined release checklist.
  - Owns: AC-01, AC-02, AC-03
  - Proof: Individual child validators and the global graph pass; a manual contract review confirms no duplicated implementation or authoritative specification store; coordinated browser evidence proves correct routing and separate readiness presentation before `capability:sdd-adoption-coordination` readiness is recorded.

## Verification Gate

- [x] All three required child capabilities are ready with recorded proof — see `capability_index.py` receipts in progress.md.
- [x] Individual child specification validators pass — specs/13, /14, /15, /16, /30 each exit `0`, see progress.md.
- [x] The global cross-specification graph passes without a cycle or ambiguous provider — `validate_spec.py --all specs` exit `0` (35 specifications).
- [x] Coordinated routing and four-axis readiness browser proof passes — six-spec Playwright run, 10 passed / 2 pre-existing documented skips, exit `0`, see progress.md.
- [x] Source-of-truth, privacy, and mutation boundaries agree across children — manual contract review in progress.md, no conflict found.
- [x] Release gates remain reported separately from implementation readiness — each child's own release gates (specs/14 §Release gates via specs/30, specs/15, specs/16) remain distinct from this umbrella's implementation-readiness proof; this task adds no release-gate evidence of its own.

## Blocked Decisions

- None. `capability:repository-execution-profile`, `capability:repository-sdd-kit`, and `capability:initialized-sdd-repository` are all ready.

## Progress Log

See [progress.md](progress.md).
