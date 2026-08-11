# Guided Delivery Notification Access Progress Log

### 2026-08-11 — Task 5 complete: 90-day Slice 07 notification retention

- Completed: Added `Privacy.Retention.prune_delivery_notifications/1`, wired into the existing single-lock `prune_all/1` sweep (no new advisory lock — mirrors `prune_terminal_invitations/1`). Deletes `delivery.`-namespace `AccountNotification` rows 90 days past `occurred_at` regardless of read state; `participation.`-namespace rows are never selected. `capability:guided-delivery-notification-governance` is now ready. Implemented in parallel with Task 3 (disjoint files: this touched only `lib/sdd_orchestrator/privacy/` and its test; Task 3 touched only `lib/sdd_orchestrator/delivery/` and its test — both depended only on already-complete Tasks 1/2, no shared-file conflict).
- Remaining: Task 3 write-back (below), Task 4 (accessible notification inbox LiveView), and the verification gate.
- Failed checks: None. One transient false alarm during reconciliation — a direct `mix test` invocation across all four task test files together omitted the worktree's `MIX_TEST_PARTITION` env var and hit an unmigrated default-partition database; re-run with the correct partition passed (38 passed, 0 failures). Not a code defect.
- Proof receipts:
- Proof receipt: `Task 5` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/delivery_notification_retention_test.exs` — exit `0`.
  (Independently re-run and confirmed by the orchestrating session. Combined regression run of Tasks 1, 2, 3, 5 plus the existing `participation_retention_test.exs`/`retention_test.exs` suites: 38 passed, exit 0 — no cross-task regression.)
- Spec updates: `tasks.md` Task 5 checked complete; capability readiness noted.

### 2026-08-11 — Task 2 complete: durable unread and idempotent mark-read

- Completed: Added `NotificationAccess.fetch/3` and `NotificationAccess.mark_read/3`, both gated behind the same per-record participation-revalidation `list/3` uses (extracted into a shared private `authorized_record?/2` helper). `mark_read/3` delegates the actual durable transition to the already-idempotent `Notifications.mark_read/3` rather than re-implementing it. Every failure mode (unknown id, wrong account, unparsable link, removed participant) collapses to the identical `{:error, :not_found}`.
- Remaining: Tasks 3 through 5 and the verification gate.
- Failed checks: None.
- Proof receipts:
- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/notification_read_state_test.exs` — exit `0`.
  (8 passed. Independently re-run and confirmed by the orchestrating session. Task 1's `notification_access_test.exs` re-run standalone after this edit — 10 passed, no regression.)
- Spec updates: `tasks.md` Task 2 checked complete.

### 2026-08-11 — Task 1 complete: authorized notification listing

- Completed: Implemented `SddOrchestrator.Delivery.NotificationAccess.list/3` — recipient-scoped, `delivery.`-namespace-only query with newest-first stable ordering (`desc: occurred_at, desc: id`), bounded/clamped pagination mirroring `Delivery.Activity`'s convention, and per-call (never cross-call) participation revalidation through `Delivery.ParticipantGuard`/`Participation.Boundary`. Project id is parsed from `link_path` since `AccountNotification` carries no `project_id` column; unparsable or unauthorized records are dropped without backfilling the page. Confirmed a current participant with no `ProjectMemberProfile` row is still listed (the case the whole slice was blocked on).
- Remaining: Tasks 2 through 5 and the verification gate.
- Failed checks: None.
- Proof receipts:
- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/notification_access_test.exs` — exit `0`.
  (10 passed. Independently re-run and confirmed by the orchestrating session.)
- Spec updates: `tasks.md` Task 1 checked complete.

### 2026-08-11 — Recipient-routing capability confirmed ready, Task 1 started

- Completed: Confirmed `capability:project-participation-recipient-routing`, `capability:project-participation-boundary`, and `capability:guided-delivery-notification-projection` are all `ready` via `python3 .agents/scripts/capability_index.py`. Cleared the stale `Blocked` status and `Blocked Decisions` note (`specs/08-project-participation#Task 36` completed the repaired routing this blocker was waiting on). Created `slice/17-guided-delivery-notification-access` worktree and started Task 1.
- Remaining: Implement Tasks 1 through 5 and the verification gate.
- Failed checks: None.
- Proof receipts: None yet.
- Spec updates: `tasks.md` Status changed Blocked → In Progress; Task 1 status line and Blocked Decisions updated to reflect capability readiness. No product or design decision changed.

### 2026-08-02 — Focused child specification created

- Completed: Moved unfinished notification access and notification-retention ownership out of the Slice 07 umbrella without changing approved product behavior.
- Remaining: Deliver the repaired Slice 08 recipient-routing capability, then implement Tasks 1 through 5 and the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass; implementation has not started because the required recipient-routing capability is unavailable.
- Proof receipts: None.
- Spec updates: Added focused notification access, read-state, safe-link, inbox, and retention ownership with standard task size and focused proof scope.
