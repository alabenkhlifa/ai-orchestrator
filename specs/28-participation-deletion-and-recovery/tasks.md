# Participation Deletion And Recovery Tasks

## Status

In Progress

The agreement is approved. `capability:project-participation-boundary`, `capability:participation-processing-controls`, and `capability:participation-operational-retention` are all ready. Task 1 is complete; Task 2 is next.

## Active Slice

Enforce 35-day recovery-only backup expiry and idempotent deletion or anonymization propagation across every configured participation copy without restoring access or identity links.

## Cross-Specification Dependencies

Requires:

- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:participation-processing-controls` — provider `specs/26-participation-data-protection-controls#Task 5` — required before `Task 1`.
- `capability:participation-operational-retention` — provider `specs/27-participation-operational-retention#Task 3` — required before `Task 1`.

Provides:

- `capability:participation-deletion-recovery` — ready after `Task 2`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Both tasks are `Size: Standard`, each owns one independently provable backup or propagation invariant, and focused proof is expected to run in about ten minutes.
- No task-size exception is used; complete repository, security, production, and release proof remains at the slice verification gate.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Participation backup expiry, encryption and recovery-only enforcement.
- Deletion and anonymization tombstone handling and restore ordering.
- Configured processor, cache, index, export, and derived-copy cleanup requests.
- Restricted acknowledgement, retry, restart, and reconciliation state.
- No-restored-access and no-restored-identification proof.

Excluded:

- Primary-store participation retention, rights disposition, and authorization.
- Operational email, notification, and security-log retention.
- Deployment-specific live vendor evidence or production deletion execution.

Deferred after this slice:

- Additional cleanup adapters not configured for the first release.

Release gates:

- Live enforced backup expiry and deletion or anonymization acknowledgement from every configured destination.
- Deployment-specific processor agreements, regions, transfer safeguards, recovery authorization, notices, incidents, and accountable privacy or legal approval.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Enforce participation backup expiry and tombstone-first recovery.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Prevent encrypted recovery copies from outliving their approved purpose or restoring a removed participation identity link.
  - Owned surfaces: Participation backup selection, encryption and recovery-only checks, 35-day expiry, deletion and anonymization tombstones, restore ordering, deployment-profile evidence validation, fixtures, and negative product and ordinary-support reads.
  - Owns: AC-01
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/participation_backup_lifecycle_test.exs` passes focused encryption, recovery-only, 35-day boundary, tombstone-preservation, restore-order, product-denial, support-denial, and no-restored-link cases.

- [ ] Task 2 — Propagate participation deletion and anonymization.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Remove approved participation identity data from configured non-backup copies without creating a new content-bearing cleanup store.
  - Owned surfaces: Processor, cache, index, export, and derived-copy adapter registry, deletion and anonymization requests, minimum request allowlist, opaque subject references, idempotency, acknowledgement and normalized failure state, retry lock, restart and recovery reconciliation, authorization compatibility, fixtures, `capability:participation-deletion-recovery` provider, and readiness write-back.
  - Owns: AC-02, AC-03
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/participation_propagation_test.exs` passes focused destination, allowlist, deletion, anonymization, duplicate, acknowledgement, failure, retry, restart, recovery, forbidden-content, no-restored-access, no-restored-label, and capability-readiness cases.

## Verification Gate

- [ ] All three acceptance criteria pass for deletion, anonymization, backup recovery, retry, and restart paths.
- [ ] Minimum cleanup request and restricted reconciliation negative scans pass without project content, credentials, emails, labels, account IDs, or hosted-identity IDs.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.
- [ ] Deployment-specific live evidence remains classified at release.

## Blocked Decisions

- None. All required capabilities are ready.

## Progress Log

See [progress.md](progress.md).
