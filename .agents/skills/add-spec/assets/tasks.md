# <Feature or Slice Name> Tasks

## Status

Not Started | In Progress | Blocked | Verified

## Active Slice

<The working behavior this task file is expected to deliver>

## Cross-Specification Dependencies

Requires:

- `capability:<name>` — provider `specs/<feature>#Task <n>` — required before `Task <n>`.

Provides:

- `capability:<name>` — ready after `Task <n>`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- <Work allowed in this slice>
- <Another allowed change>

Excluded:

- <Related work that must remain separate>

Deferred after this slice:

- <Required behavior planned for a later executable slice>

Release gates:

- <Deployment or release evidence that is not required for active implementation, or None>

Traceability:

- Deferred criteria: <AC-<n> IDs outside the active slice, or none>
- Release criteria: <AC-<n> IDs proved only at release, or none>
- Deferred entities: <entity:<Name> items outside the active slice, or none>
- Release entities: <entity:<Name> items introduced only for release, or none>

## Tasks

- [ ] Task 1 — <First implementation step>
  - Size: Standard | Exception — <Why splitting would create an invalid intermediate state>.
  - Proof scope: Focused | Broad — <Why this task owns an inseparable broader gate>.
  - Depends on: none
  - Purpose: <Why this step is needed>
  - Owned surfaces: <UI, API, domain, persistence, integration, security or privacy, and operational surfaces for which this task is the primary owner>
  - Owns: <AC-<n> IDs and entity:<Name> items this task is the primary owner of, or none>
  - Proof: <Check that shows this step works>

- [ ] Task 2 — <Next implementation step>
  - Size: Standard | Exception — <Why splitting would create an invalid intermediate state>.
  - Proof scope: Focused | Broad — <Why this task owns an inseparable broader gate>.
  - Depends on: Task 1
  - Purpose: <Why this step is needed>
  - Owned surfaces: <Surfaces for which this task is the primary owner>
  - Owns: <AC-<n> IDs and entity:<Name> items this task is the primary owner of, or none>
  - Proof: <Check that shows this step works>

## Verification Gate

- [ ] Acceptance criteria pass
- [ ] Relevant automated tests pass
- [ ] Build and type checks pass
- [ ] Product proof: one click path from `/` in a real browser, worker stand-in off, no `/_e2e` seeding, recorded in `progress.md`
- [ ] New decisions are written back
- [ ] Deferred work is recorded

## Blocked Decisions

- <Decision that blocks the active slice and the earliest stage it blocks, or None>

## Progress Log

See [progress.md](progress.md).
