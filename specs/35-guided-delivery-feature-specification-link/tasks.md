# Guided Delivery Feature-Specification Link Tasks

## Status

In Progress

Task 1 is complete: `Feature` gained its owner-only `specification_id` link, uniqueness constraint, and `capability:guided-delivery-feature-specification-link` is ready. Task 2 (the owner-facing link control) is next and unblocked.

## Active Slice

Let the project owner link, change, or clear one delivery-board feature's reference to a current authoritative specification, and publish a deterministic read of that link for another approved specification to consume.

## Cross-Specification Dependencies

Requires:

- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 1`.
- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.

Provides:

- `capability:guided-delivery-feature-specification-link` — ready after `Task 1`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Every task is standard, owns one independently provable outcome, and has no more than three acceptance criteria and two entities.
- No exception is required.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- The optional, owner-only `specification_id` link on `Feature`, its uniqueness constraint, link and unlink context functions, the published capability read, and the owner-facing link control in the feature detail view.

Excluded:

- Any change to `specs/30-repository-execution-profile-completion`'s `RepositoryPilotSelection` schema, business rules, or pilot-selection UI.
- Any change to `Delivery.Readiness`'s existing readiness-assessment axes.
- Requiring a link at feature creation, or backfilling a link for features created before this change.
- Participant-level (non-owner) specification browsing or linking.
- Repository-kit installation eligibility itself, owned by `specs/15-repository-sdd-kit-integration`.

Deferred after this slice:

- Backfilling links for features created before this change.
- Broader participant specification authorization, if `specs/09-project-specification-storage` ever approves it.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Add the specification link to `Feature` and publish the read capability.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let a feature carry a stable link to the specification it delivers, and let another approved specification resolve that link deterministically.
  - Owned surfaces: `Feature.specification_id` schema and migration with its `(project_id, specification_id)` uniqueness constraint, `Delivery.Features.link_specification/5` and `unlink_specification/3` (owner-only authorization, current-snapshot validation), `Delivery.Features.fetch_by_specification/2` capability read, and `capability:guided-delivery-feature-specification-link` provider and readiness write-back.
  - Owns: AC-02, AC-03, AC-04, entity:Feature
  - Proof: Focused link, unlink, uniqueness-conflict, not-linked-result, and other-fields-unchanged tests pass before `capability:guided-delivery-feature-specification-link` readiness is recorded.

- [ ] Task 2 — Add the owner-facing link control to the feature detail view.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let the owner actually perform the link and unlink action from the product UI, and prove the action is refused for anyone else.
  - Owned surfaces: Feature detail LiveView link control, available (unlinked) specification listing display, link and unlink actions wired to Task 1's context functions, and owner-only control visibility and refusal.
  - Owns: AC-01, AC-05
  - Proof: Focused LiveView and browser tests covering the owner control, the excluded-already-linked specification, and non-owner refusal (both control absence and a direct refused attempt) pass.

## Verification Gate

- [ ] Acceptance criteria pass.
- [ ] Link, unlink, uniqueness, authorization, and capability-read suites pass.
- [ ] LiveView and browser scenarios pass.
- [ ] `mix check` and all explicit project code-quality commands pass.
- [ ] `npm --prefix assets ci` and `npm --prefix assets run test:e2e` pass.
- [ ] `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` pass.
- [ ] Specification validator and global capability graph pass.

## Blocked Decisions

- None. Task 1 is complete and Task 2 is immediately executable.

## Progress Log

See [progress.md](progress.md).
