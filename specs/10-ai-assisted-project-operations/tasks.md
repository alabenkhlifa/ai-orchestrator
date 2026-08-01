# AI-Assisted Project Operations Tasks

## Status

Blocked

The product coordination agreement is approved. Coordination verification waits for runtime session, observation, and governance, the read-only project assistant, and SDD-adoption coordination. This umbrella owns no implementation.

## Active Slice

Verify that the shared runtime, read-only project assistant, and nested SDD-adoption contracts compose without duplicated authority, that later project-funding and mutation integrations remain separately owned, and that no child silently changes personal connection ownership, specification authority, repository trust, or Slice 07 lifecycle authority.

## Cross-Specification Dependencies

Requires:

- `capability:ai-runtime-session` — provider `specs/11-ai-runtime-governance#Task 11` — required before `Task 1`.
- `capability:ai-runtime-observation` — provider `specs/11-ai-runtime-governance#Task 5` — required before `Task 1`.
- `capability:ai-runtime-governance` — provider `specs/11-ai-runtime-governance#Task 6` — required before `Task 1`.
- `capability:read-only-project-assistant` — provider `specs/12-project-assistant#Task 10` — required before `Task 1`.
- `capability:sdd-adoption-coordination` — provider `specs/13-sdd-adoption#Task 1` — required before `Task 1`.

Provides:

- None.

## Task Size Gate

- The umbrella has one standard coordination-verification task and no implementation task.
- Child specifications own independently executable behavior, data, adapters, UI, privacy controls, and proof.
- No task-size exception is used.

## Implementation Boundary

Included:

- Cross-specification capability ownership and dependency verification.
- Confirmation that support and working-agent consumers share runtime contracts.
- Confirmation that private project Q&A and repository adoption preserve their separate permissions, storage, mutation, and source-of-truth boundaries.
- Confirmation that project-shared funding and Slice 07 lifecycle integration remain separately owned.

Excluded:

- Application code, migrations, schemas, adapters, worker commands, pages, provider integrations, runtime transitions, and tests implementing child behavior.
- Duplicate implementation tasks copied from any child specification.

Deferred after this slice:

- A focused project-shared API connection, permission, project-budget, and per-run ceiling specification.
- A focused confirmed assistant-action specification.
- An `update-spec` workflow for Slice 07 before it consumes runtime session, observation, pause, resume, stop, or linked continuation behavior.

Release gates:

- Release waits for every invoked child and consumer specification to pass its own implementation, verification, privacy, security, processor, transfer, notice, retention, and accountable review gates.

Traceability:

- Deferred criteria: none.
- Release criteria: none.
- Deferred entities: none.
- Release entities: none.

## Tasks

- [ ] Task 1 — Verify child ownership and integration readiness.
  - Size: Standard
  - Depends on: none
  - Purpose: Confirm the coordinated AI-operations contract without duplicating child implementation.
  - Owned surfaces: Cross-specification capability graph, runtime session, observation and governance compatibility, private assistant boundary, nested adoption boundary, sole specification authority, personal and project-shared ownership separation, no-funded-fallback rule, future Slice 07 update boundary, scope classification, and coordination readiness report.
  - Owns: AC-01, AC-02, AC-03
  - Proof: All required capabilities are ready with recorded proof, individual and global specification validators pass, no child duplicates runtime, conversation, repository, or specification authority, future funding and mutation have distinct owners, and Slice 07 remains unchanged pending its explicit `update-spec`.

## Verification Gate

- [ ] Every required runtime, assistant, and adoption capability is ready at its named provider task boundary.
- [ ] Individual child validators and the global capability graph pass.
- [ ] Runtime, project-funding, assistant, adoption, repository, and guided-delivery surfaces have one primary specification owner.
- [ ] No umbrella task duplicates a child implementation task.
- [ ] Personal subscription ownership, credential locality, access-safe visibility, and no-funded-fallback rules agree across children.
- [ ] Slice 07 integration remains deferred until its approved `update-spec`.

## Blocked Decisions

- Coordination is blocked until every required runtime, assistant, and adoption capability is implemented, proved, and recorded ready by its named provider task.

## Progress Log

### 2026-07-31 - Coordination umbrella created

- Completed: Approved the cross-workflow product rules, classified the result as an umbrella with focused child specifications, and reserved the runtime session and observation capability edges.
- Remaining: Deliver the runtime, project-assistant, and adoption capabilities, add focused project-funding and confirmed-action children, update Slice 07 before lifecycle integration, and run the coordination verification task.
- Failed checks: None recorded at creation.
- Spec updates: Created the coordination-only agreement with one verification task and no implementation ownership.
