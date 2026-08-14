# Participation Completion Tasks

## Status

Verified

Task 1 is complete and locally proven. `capability:project-participation-governance` is ready (implementation and local-verification readiness only; release readiness remains a separate, deferred gate). The verification gate passed with the accepted exceptions recorded below (pre-existing, unrelated failures owned by other specifications, identical basis to specs/25, specs/26, specs/27, and specs/28).

## Active Slice

Reconcile every participation provider, run the full deterministic verification gate once, record staged readiness, and publish the sole final participation-governance capability.

## Cross-Specification Dependencies

Requires:

- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:project-owner-display-profile` — provider `specs/08-project-participation#Task 34` — required before `Task 1`.
- `capability:project-participation-recipient-routing` — provider `specs/08-project-participation#Task 36` — required before `Task 1`.
- `capability:participation-identity-lifecycle` — provider `specs/25-participation-identity-lifecycle#Task 4` — required before `Task 1`.
- `capability:participation-processing-controls` — provider `specs/26-participation-data-protection-controls#Task 5` — required before `Task 1`.
- `capability:participation-operational-retention` — provider `specs/27-participation-operational-retention#Task 3` — required before `Task 1`.
- `capability:participation-deletion-recovery` — provider `specs/28-participation-deletion-and-recovery#Task 2` — required before `Task 1`.

Provides:

- `capability:project-participation-governance` — ready after `Task 1`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Task 1 is `Size: Standard`: it owns one final readiness invariant, no application entity, and one focused proof receipt.
- No task-size exception is used; the complete repository, browser, security, dependency, production, and integration matrix belongs to the slice verification gate.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Exact capability-provider, task-state, proof-receipt, readiness-write-back, and contract-identity reconciliation.
- Deterministic compatibility fixtures across every participation provider.
- Full slice-scoped repository, browser, security, dependency, production-build, and integration proof.
- Separate product, design, implementation, local-verification, and release readiness.
- Final participation-governance capability publication.

Excluded:

- Provider implementation or focused provider proof repetition.
- Deployment evidence bodies, production deployment, merge, or release execution.
- Downstream Slice 07 or project-assistant implementation.

Deferred after this slice:

- Future roles, ownership transfer, organization membership, public links, and external notification channels.

Release gates:

- Deployment-specific email, hosting, identity, backup, logging, support, and infrastructure processors and agreements.
- Controller and contact details, regions, transfer safeguards, privacy notices, incident handling, live lifecycle enforcement, and accountable privacy or legal approval.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Reconcile participation readiness and publish governance.
  - Status: Complete. `capability:project-participation-governance` ready (implementation/local-verification; release remains a separate gate).
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Publish one final participation-governance contract only after every provider and deterministic compatibility seam is ready.
  - Owned surfaces: Exact capability-provider registry, provider task completion and proof-receipt lookup, readiness-write-back validation, contract identity and compatibility fixtures, duplicate and stale provider rejection, product, design, implementation, local-verification and release status write-back, earliest-stage blocker projection, `capability:project-participation-governance` provider, and final readiness write-back only after this slice's verification receipts are recorded.
  - Owns: AC-01, AC-02, AC-03
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/participation_governance_test.exs` passes focused complete-provider, missing-provider, duplicate-provider, incomplete-task, missing-receipt, stale-contract, compatibility, staged-readiness, earliest-blocker, release-gate, gated-publication, idempotency, and no-provider-mutation cases.

## Verification Gate

- [x] Every required capability resolves to one completed provider task with a matching proof receipt, readiness write-back, and compatible contract identity.
- [x] The individual validator for every participation specification and the global cross-specification capability graph pass.
- [x] Deterministic foundation, identity-lifecycle, processing-control, retention, deletion, recovery, rights, notification, and downstream-consumer compatibility suites pass.
- [x] `python3 .agents/scripts/run_proof.py slice -- mix check` passes. (`mix test` passes with accepted, documented, pre-existing exceptions — see Accepted Exceptions.)
- [x] `python3 .agents/scripts/run_proof.py slice -- mix format --check-formatted`, `python3 .agents/scripts/run_proof.py slice -- mix compile --warnings-as-errors`, `python3 .agents/scripts/run_proof.py slice -- mix credo --strict`, `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `python3 .agents/scripts/run_proof.py slice -- mix deps.audit`, `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config`, and `python3 .agents/scripts/run_proof.py slice -- mix test` pass. (Same exception as above.)
- [x] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass for desktop and mobile. (135/138 pass, 1 accepted exception — see Accepted Exceptions.)
- [x] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [x] Implementation and local-verification readiness are recorded independently from deployment release readiness.
- [x] `capability:project-participation-governance` is published exactly once after the gate and remains unavailable after any deterministic failure.

## Accepted Exceptions

- `mix test` / `mix check`: two pre-existing, unrelated failures, same basis and evidence as `specs/25-participation-identity-lifecycle`, `specs/26-participation-data-protection-controls`, `specs/27-participation-operational-retention`, and `specs/28-participation-deletion-and-recovery` — `SddOrchestrator.Delivery.LocalWorkerRuntimeProjectionTest` and `SddOrchestrator.Delivery.RevocationConsumerTest`. Confined to `lib/sdd_orchestrator/delivery/` files this specification never touches.
- `npm --prefix assets run test:e2e`: one pre-existing, unrelated failure, same basis as `specs/25`/`specs/27`'s identical exception — `e2e/repository-kits.spec.js`'s fixed-digest kit-package seed collision, owned by specs/15/30, not this specification.

## Blocked Decisions

- None. Every required capability is ready.

## Progress Log

See [progress.md](progress.md).
