# Participation Operational Retention Tasks

## Status

Verified

All three tasks are complete and locally proven. `capability:participation-operational-retention` is ready. The verification gate passed with the accepted exceptions recorded below (pre-existing, unrelated failures owned by other specifications, identical basis to specs/25 and specs/26).

## Active Slice

Delete finalized participation email-delivery diagnostics at 30 days, participation account notifications at 90 days, and minimized participation operational-security logs at 30 days through one locked, restart-safe, and reconcilable retention workflow.

## Cross-Specification Dependencies

Requires:

- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:participation-identity-lifecycle` — provider `specs/25-participation-identity-lifecycle#Task 4` — required before `Task 1`.

Provides:

- `capability:participation-operational-retention` — ready after `Task 3`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Tasks 1 through 3 are `Size: Standard`: each owns one independently provable retention invariant and one focused proof command.
- The three-task dependency path is required because every task extends `Privacy.Retention.prune_all/1`, its shared scheduler, and reconciliation proof; no task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Thirty-day finalized participation email-delivery diagnostic cleanup.
- Ninety-day read and unread participation account-notification cleanup.
- Participation-only namespace selection in the shared notification store.
- Fixed minimized participation operational-security events and 30-day deletion.
- Shared pruner registration, locking, restart, idempotency, category results, and reconciliation.
- Compatibility proof for the provider-owned identity-lifecycle rule.

Excluded:

- Implementing or changing terminal invitation cleanup, departed `ProjectParticipant.hosted_identity_id` cleanup, `ParticipationRevocation.former_hosted_identity_id` cleanup, acknowledgement behavior, or retained revocation fields.
- Notification content, recipient routing, email retry policy, shared notification schema redesign, or non-participation notification retention.
- Historical-attribution rights handling, backup expiry, processor propagation, project deletion, and final governance review.
- Production processor selection, deployment, merge, or release execution.

Deferred after this slice:

- Participation processing controls, backup expiry, deletion and anonymization propagation, and final governance capability publication remain in their focused specifications.

Release gates:

- Production security-log sink configuration, enforced 30-day deletion, access restriction, processor, region, transfer, and incident evidence.
- Accountable privacy and security approval for the deployed operational-retention configuration.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Enforce participation email-delivery diagnostic retention.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Remove finalized participation email-delivery diagnostics after their short operational purpose while preserving authoritative participation state.
  - Owned surfaces: Finalized `ParticipationEmailDelivery` selector, authoritative attempt or completion timestamp, 30-day boundary, pending retry exclusion, `Privacy.Retention.prune_all/1` email-delivery category, `Privacy.RetentionPruner` lock and restart integration, idempotent deletion, category reconciliation, unchanged invitation, participant, profile, revocation and account assertions, fixtures, and provider-owned identity-lifecycle rule compatibility without direct-link selector changes.
  - Owns: AC-01
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/participation_email_delivery_retention_test.exs` passes focused 29-day and 30-day, sent, failed, pending, authoritative-time, invitation, participant, profile, revocation, account, idempotency, lock, restart, reconciliation, and identity-lifecycle compatibility cases.

- [x] Task 2 — Enforce participation account-notification retention.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Delete expired participation in-product notifications without changing authorization or another shared notification namespace.
  - Owned surfaces: Approved `participation.*` event selector, 90-day occurrence boundary, read and unread deletion, non-participation namespace preservation, `Privacy.Retention.prune_all/1` account-notification category, shared lock and restart integration, idempotent deletion, category reconciliation, current authorization non-mutation, fixtures, and shared-store compatibility.
  - Owns: AC-02
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/participation_account_notification_retention_test.exs` passes focused 89-day and 90-day, read, unread, participation namespace, guided-delivery namespace, future namespace, active authorization, idempotency, lock, restart, reconciliation, and shared-store cases.

- [x] Task 3 — Enforce minimized participation security-log retention and publish readiness.
  - Status: Complete. `capability:participation-operational-retention` ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Keep only short-lived structured participation security evidence and reconcile the complete operational-retention capability.
  - Owned surfaces: Participation security-event type allowlist, fixed event structure, coarse outcomes, fixed reason categories, UTC occurrence time, fresh non-secret correlation identifier, credential, email, digest, project-content, comment, evidence, repository, provider-payload, secret and unrelated-identity exclusion, typed refusal or omission of forbidden input, retention-capable log adapter, 30-day selector, `Privacy.Retention.prune_all/1` security-log category, shared scheduler, advisory lock, interruption, restart, retry, category reconciliation across Tasks 1 through 3 and the provider-owned identity-lifecycle rule, duplicate-rule rejection, no participation-state mutation, fixtures, `capability:participation-operational-retention` provider, and readiness write-back.
  - Owns: AC-03
  - Proof: `python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/privacy/participation_security_log_retention_test.exs test/sdd_orchestrator/privacy/participation_operational_retention_test.exs` passes focused event, allowlist, outcome, reason, occurrence, correlation, forbidden-content, credential, email, digest, project, repository, secret, unrelated-identity, 29-day and 30-day, idempotency, lock contention, interruption, restart, retry, category reconciliation, duplicate identity-rule, no-state-mutation, capability-readiness, and minimized diagnostic cases.

## Verification Gate

- [x] All three acceptance criteria pass at their exact time boundaries.
- [x] Delivery cleanup preserves pending retry and every invitation, participant, profile, revocation, and account record.
- [x] Notification cleanup covers read and unread participation events while preserving authorization and every other namespace.
- [x] Security-event allowlist and forbidden personal-data, project-content, repository, credential, secret, and unrelated-identity scans pass.
- [x] The shared retention runner passes idempotency, advisory-lock, interruption, supervised-restart, retry, category-result, overdue-reconciliation, and non-restoration scenarios.
- [x] Identity-lifecycle compatibility proves its direct-link rule remains provider-owned and registered exactly once.
- [x] `python3 .agents/scripts/run_proof.py slice -- mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope. (`mix test` passes with two accepted, documented, pre-existing exceptions — see Accepted Exceptions.)
- [x] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass for the repository browser matrix. (135/138 pass, 1 accepted exception — see Accepted Exceptions.)
- [x] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [x] The individual specification validator and global cross-specification graph pass, all proof receipts and readiness write-backs are recorded, and `capability:participation-operational-retention` is published only after Task 3 and this gate complete.
- [x] New decisions and invalidated proof are written back.

## Accepted Exceptions

- `mix test` / `mix check`: two pre-existing, unrelated failures, same basis and evidence as `specs/25-participation-identity-lifecycle` and `specs/26-participation-data-protection-controls` — `SddOrchestrator.Delivery.LocalWorkerRuntimeProjectionTest` and `SddOrchestrator.Delivery.RevocationConsumerTest`. Both reproduce in isolation, are confined to `lib/sdd_orchestrator/delivery/` files this specification never touches, and are unrelated to Tasks 1-3.
- `npm --prefix assets run test:e2e`: one pre-existing, unrelated failure, same basis as `specs/25-participation-identity-lifecycle`'s identical exception — `e2e/repository-kits.spec.js`'s fixed-digest kit-package seed collision, owned by specs/15/30, not this specification.
- (Fixed directly, not an exception): a Slice 18 test (`delivery_notification_retention_test.exs`) assumed a participation-namespace notification never expires; Task 2's new rule means it now legitimately does, via its own category. Updated the test's assertion rather than treating this as an exception, since it is a direct, foreseen consequence of this slice's own approved behavior. See `progress.md` 2026-08-14 entry.

## Blocked Decisions

- None. Both required capabilities are ready.

## Progress Log

See [progress.md](progress.md).
