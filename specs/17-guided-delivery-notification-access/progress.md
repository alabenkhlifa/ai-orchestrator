# Guided Delivery Notification Access Progress Log

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
