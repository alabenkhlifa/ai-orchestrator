# Participation Operational Retention Progress Log

### 2026-08-14 — Task 2 complete: account-notification retention

- Completed: Added `prune_participation_notifications/1` to `Privacy.Retention`, mirroring `prune_delivery_notifications/1` exactly (90-day window, `like(event_type, "participation.%")`, no `read_at` filter — both read and unread rows are eligible), registered under `expired_participation_notifications` in `prune_all/1`. Namespace isolation proven both ways: a `delivery.*` row and an out-of-vocabulary row (inserted directly, bypassing the changeset's closed-vocabulary validation, to prove the DB has no constraint doing this job) are never selected.
- Scope classification: unchanged.
- Remaining: Task 3, then the verification gate.
- Failed checks: None.
- Proof receipts:
  - Result: 10 passed.
  - Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_account_notification_retention_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- Spec updates: Task 2 checkbox/status line only.

### 2026-08-14 — Task 1 complete: email-delivery diagnostic retention

- Completed: Added `prune_participation_email_delivery_diagnostics/1` to `Privacy.Retention` (30-day window, finalized `"sent"`/`"failed"` rows only, eligibility timestamp `COALESCE(delivered_at, attempted_at)`, `"pending"` never selected), registered under `expired_participation_email_delivery_diagnostics` in `prune_all/1`, and a matching moduledoc paragraph. No new module — extends the existing shared retention runner per design.md's "One Shared Runner With Serialized Rule Ownership" decision.
- Confirmed: `ParticipationEmailDelivery.record_result/3` currently always sets `delivered_at` for `"sent"` and leaves it `nil` for `"failed"`, but no DB constraint enforces that pairing, so the `COALESCE` fallback is a defensive, spec-correct implementation of "last authoritative attempt or completion," not just a reflection of current call sites.
- Confirmed the provider-owned `prune_participation_revocation_links/1` (specs/25) is untouched and composes correctly with the new rule in the same `prune_all/1` pass.
- Proof receipts:
  - Result: 11 passed.
  - Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_email_delivery_retention_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- Remaining: Tasks 2 and 3, then the verification gate.
- Failed checks: None.
- Spec updates: Task 1 checkbox/status line only.

### 2026-08-02 — Focused child specification created

- Completed: Moved unfinished participation email-delivery, account-notification, and operational-security-log retention out of the Slice 08 umbrella without changing the approved 30-day and 90-day outcomes.
- Remaining: Publish `capability:participation-identity-lifecycle`, then implement serialized Tasks 1 through 3 and the verification gate.
- Failed checks: None. The individual validator and 29-specification capability graph pass; implementation has not started because the identity-lifecycle provider is unavailable.
- Proof receipts: None.
- Spec updates: Added focused local AC-01 through AC-03 ownership, one shared retention-runner boundary, explicit non-duplication of provider-owned revocation direct-link cleanup, standard slice and task sizes, and focused proof commands for every task.
