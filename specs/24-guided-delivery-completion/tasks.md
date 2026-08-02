# Guided Delivery Completion Tasks

## Status

Blocked

The agreement is approved. Task 1 is blocked until the foundation and all focused continuation capabilities are ready.

## Active Slice

Reconcile every guided-delivery provider and full deterministic verification gate, record implementation, local-verification, and release readiness separately, and publish the sole final guided-delivery capability.

## Cross-Specification Dependencies

Requires:

- `capability:guided-delivery-data-surfaces` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-notification-projection` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-artifact-preview-boundary` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-revocation-consumer` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-start-disclosure` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-notification-governance` — provider `specs/17-guided-delivery-notification-access#Task 5` — required before `Task 1`.
- `capability:guided-delivery-purpose-limitation` — provider `specs/18-guided-delivery-data-protection-controls#Task 5` — required before `Task 1`.
- `capability:guided-delivery-operational-retention` — provider `specs/19-guided-delivery-operational-retention#Task 5` — required before `Task 1`.
- `capability:guided-delivery-device-transient-retention` — provider `specs/20-guided-delivery-device-data-retention#Task 2` — required before `Task 1`.
- `capability:guided-delivery-project-deletion-governance` — provider `specs/21-guided-delivery-deletion-and-recovery#Task 6` — required before `Task 1`.
- `capability:guided-delivery-rights-governance` — provider `specs/22-guided-delivery-rights-and-anonymization#Task 6` — required before `Task 1`.
- `capability:guided-delivery-deployment-governance` — provider `specs/23-guided-delivery-deployment-governance#Task 3` — required before `Task 1`.

Provides:

- `capability:guided-specification-delivery` — ready after `Task 1`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Task 1 is `Size: Standard`: it owns one final readiness invariant, no implementation entity, and one focused proof receipt.
- No task-size exception is used; the complete repository, browser, security, dependency, production, and integration matrix belongs to the slice verification gate.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Exact provider, proof-receipt, readiness-write-back, and contract-identity reconciliation.
- Deterministic cross-provider compatibility fixtures.
- Full slice-scoped repository, browser, security, dependency, production-build, and integration proof.
- Separate implementation, local-verification, and release readiness.
- Final guided-delivery capability publication.

Excluded:

- Provider implementation, provider task proof repetition, deployment evidence bodies, production deployment, merge, and release execution.

Deferred after this slice:

- Future provider breadth, external notification channels, worker pools, automatic merge, and production deployment workflows.
- Deferred criteria: none.
- Deferred entities: none.

Release gates:

- Every deployment-specific release item classified by `capability:guided-delivery-deployment-governance`, including controller, vendor and agreement, region and transfer, notice, live enforcement, incident, DPIA or legal, and accountable privacy and security approval evidence.
- Live configured worker, coding-agent, preview when enabled, deletion, rights, and processor smoke evidence required by the owning deployment.
- Release criteria: none.
- Release entities: none.

## Tasks

- [ ] Task 1 — Reconcile guided-delivery readiness and publish the final capability.
  - Status: Blocked until every capability named for Task 1 is ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Publish one final guided-delivery contract only after every provider and deterministic compatibility seam is ready.
  - Owned surfaces: Exact capability-provider registry, provider task completion and proof-receipt lookup, readiness-write-back validation, provider slice-verification state, contract identity and compatibility fixtures, duplicate and stale provider rejection, implementation, local-verification and release status write-back, earliest-stage blocker projection, `capability:guided-specification-delivery` provider, and final readiness write-back only after this slice's verification receipts are recorded.
  - Owns: AC-01
  - Proof: Focused complete-provider, incomplete-provider-gate, missing-provider, incomplete-task, missing-receipt, stale-contract, duplicate-provider, compatibility, staged-readiness, earliest-blocker, gated final-publication, and no-provider-mutation tests pass through task scope.

## Verification Gate

- [ ] Every required capability resolves to one completed provider task with matching proof receipt, readiness write-back, and compatible contract identity.
- [ ] The individual validator for every guided-delivery specification and the global cross-specification capability graph pass.
- [ ] Deterministic foundation, notification, processing-control, retention, deletion, rights, deployment-profile, and downstream-consumer compatibility suites pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` passes.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix format --check-formatted`, `python3 .agents/scripts/run_proof.py slice -- mix compile --warnings-as-errors`, `python3 .agents/scripts/run_proof.py slice -- mix credo --strict`, `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `python3 .agents/scripts/run_proof.py slice -- mix deps.audit`, `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config`, and `python3 .agents/scripts/run_proof.py slice -- mix test` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass for the desktop and mobile browser matrix.
- [ ] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [ ] Implementation and local-verification readiness are recorded independently from deployment release readiness.
- [ ] `capability:guided-specification-delivery` is published exactly once after the gate passes and remains unavailable after any deterministic failure.

## Blocked Decisions

- Task 1 is blocked on unavailable provider capabilities; no product decision is unresolved.

## Progress Log

### 2026-08-02 - Final guided-delivery coordination slice created

- Completed: Approved the acyclic final coordination, provider-readiness reconciliation, full slice-scoped deterministic gate, staged-readiness, and sole final-capability publication contracts.
- Scope classification: Standard focused coordination slice with one task and a one-task critical path.
- Remaining: Wait for every named provider capability, complete Task 1 through focused proof, run the full verification gate, and publish final readiness.
- Failed checks: None. The individual specification validator and global capability graph pass with the coordinated continuation-specification update.
- Spec updates: Created requirements, design, capability ownership, task proof scope, traceability, downstream publication boundary, and release classification.
