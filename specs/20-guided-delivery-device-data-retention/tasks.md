# Guided Delivery Device Data Retention Tasks

## Status

Blocked

Implementation depends on the published guided-delivery data surfaces and `capability:guided-delivery-processing-controls`, which are not yet ready. The project-storage governance provider is already available.

## Active Slice

Keep device-authoritative guided-delivery relay and cache data strictly transient, delete it within 24 hours through restart-safe reconciliation, and prove that no durable hosted device-project copy exists.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 1`.
- `capability:guided-delivery-data-surfaces` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-processing-controls` — provider `specs/18-guided-delivery-data-protection-controls#Task 4` — required before `Task 1`.

Provides:

- `capability:guided-delivery-device-transient-retention` — ready after `Task 2`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Strict transient relay and cache field allowlists for device-authoritative projects.
- Bounded active-transport handling and 24-hour cleanup.
- Restart-safe relay and cache reconciliation.
- Hosted-store and analytics negative proof for durable device-project copies.

Excluded:

- Device-authoritative project-record deletion or storage migration.
- Hosted-project retention, notification retention, temporary execution retention, security-log retention, backup expiry, or project deletion.
- Worker protocol redesign, provisioning, scheduling, or cross-worker migration.

Deferred after this slice:

- Project deletion, backup recovery boundaries, rights handling, anonymization, and deployment governance in focused child specifications.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Enforce transient relay storage and expiry.
  - Size: Standard
  - Proof scope: Focused
  - Status: Blocked until `capability:guided-delivery-data-surfaces` and `capability:guided-delivery-processing-controls` are ready.
  - Depends on: none
  - Purpose: Permit only the bounded relay state needed by a current device-worker exchange and remove it no later than 24 hours.
  - Owned surfaces: Device-authoritative mode revalidation, relay field allowlist, named transport purpose, creation and hard-expiry times, bounded active-exchange reference, prohibited-content rejection, 24-hour selector, active-transport handling, locked idempotent deletion, fixtures, and authority non-mutation.
  - Owns: AC-01, AC-02
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/delivery_device_relay_retention_test.exs` passes focused authority, allowlist, content rejection, active exchange, disconnect, 23-hour, 24-hour, idempotency, lock, and non-mutation cases.

- [ ] Task 2 — Enforce cache cleanup and no durable hosted copy.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Remove expired device-project presentation caches and prove cleanup cannot leave or restore an authoritative hosted copy.
  - Owned surfaces: Device-project cache allowlist, 24-hour selector, inaccessible cleanup-failure state, idempotent restart and reconciliation, deleted-content non-restoration, hosted feature, specification, run, activity, evidence, artifact and source-content scans, analytics identifier scan, fixtures, minimized diagnostics, `capability:guided-delivery-device-transient-retention` provider, and readiness write-back.
  - Owns: AC-03, AC-04
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/delivery_device_cache_retention_test.exs` passes focused 23-hour, 24-hour, content rejection, failure, retry, restart, reconciliation, non-restoration, hosted-store, and analytics negative cases.

## Verification Gate

- [ ] All four acceptance criteria pass with real device-authoritative and hosted-store fixtures.
- [ ] Relay and cache allowlists reject source, prompt, output, evidence, credential, email, and provider content.
- [ ] Twenty-four-hour, active-transport, restart, partial-failure, retry, and reconciliation scenarios pass.
- [ ] Hosted project, delivery, evidence, artifact, cache, and analytics stores contain no durable device-project copy.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass for the repository browser matrix.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.
- [ ] New decisions and proof receipts are written back.

## Blocked Decisions

- Active-slice implementation is blocked until `capability:guided-delivery-data-surfaces` and `capability:guided-delivery-processing-controls` are ready; no product or technical-design decision is unresolved.

## Progress Log

See [progress.md](progress.md).
