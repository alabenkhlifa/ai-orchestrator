# Guided Delivery Notification Access Progress Log

### 2026-08-11 — Task 4 complete: accessible notification inbox

- Completed: Added `SddOrchestratorWeb.NotificationLive` at `/notifications`, gated by a new `live_session :notifications` combining a hard application-session requirement with nilable hosted-identity resolution (neither existing `live_session` block alone carries both). Lists via `NotificationAccess.list/3`; `Mark read`/`Open` actions revalidate through `mark_read/3`/`resolve_safe_link/3` at click time, so a notification whose access lapsed between render and action shows one non-disclosing flash and disappears on reload rather than erroring. Unread rows show a `Mark read` button, read rows a `Read` badge (mirrors `HostedSessionsLive`'s existing badge-vs-button precedent). Added a "Notifications" entry point to `ProjectsLive`'s actions. Added `assets/e2e/notification-inbox.spec.js` for the slice verification gate's browser matrix (not run by this task — desktop/mobile browser proof is slice-scoped) and a matching `"notifications"` scenario in the shared `e2e_bootstrap_controller.ex` (additive; same per-scenario dispatch pattern every other e2e-consuming feature already uses there, no other task owns it). `capability:guided-delivery-notification-access` is now ready.
- Remaining: The verification gate only — all five tasks are now complete.
- Failed checks: None.
- Proof receipts:
- Proof receipt: `Task 4` — scope `Focused` — command `mix test test/sdd_orchestrator_web/live/notification_live_test.exs` — exit `0`.
  (Independently re-run and confirmed by the orchestrating session. Combined regression run of Tasks 1, 2, 3, 4, 5 plus `projects_live_test.exs`, `feature_board_live_test.exs`, `hosted_sessions_live_test.exs`, `e2e_bootstrap_controller_test.exs`, and the existing retention suites: 105 passed, exit 0 — no cross-task regression.)
- Spec updates: `tasks.md` Task 4 checked complete; capability readiness noted.

### 2026-08-11 — Task 5 complete: 90-day Slice 07 notification retention

- Completed: Added `Privacy.Retention.prune_delivery_notifications/1`, wired into the existing single-lock `prune_all/1` sweep (no new advisory lock — mirrors `prune_terminal_invitations/1`). Deletes `delivery.`-namespace `AccountNotification` rows 90 days past `occurred_at` regardless of read state; `participation.`-namespace rows are never selected. `capability:guided-delivery-notification-governance` is now ready. Implemented in parallel with Task 3 (disjoint files: this touched only `lib/sdd_orchestrator/privacy/` and its test; Task 3 touched only `lib/sdd_orchestrator/delivery/` and its test — both depended only on already-complete Tasks 1/2, no shared-file conflict).
- Remaining: Task 3 write-back (below), Task 4 (accessible notification inbox LiveView), and the verification gate.
- Failed checks: None. One transient false alarm during reconciliation — a direct `mix test` invocation across all four task test files together omitted the worktree's `MIX_TEST_PARTITION` env var and hit an unmigrated default-partition database; re-run with the correct partition passed (38 passed, 0 failures). Not a code defect.
- Proof receipts:
- Proof receipt: `Task 5` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/delivery_notification_retention_test.exs` — exit `0`.
  (Independently re-run and confirmed by the orchestrating session. Combined regression run of Tasks 1, 2, 3, 5 plus the existing `participation_retention_test.exs`/`retention_test.exs` suites: 38 passed, exit 0 — no cross-task regression.)
- Spec updates: `tasks.md` Task 5 checked complete; capability readiness noted.

### 2026-08-11 — Task 3 complete: safe notification-link access

- Completed: Added `NotificationAccess.resolve_safe_link/3`. Reuses `fetch/3` for notification-level authorization, parses `link_path` into project and feature ids, then calls `Delivery.Features.fetch/3` (the codebase's canonical project-scoped feature loader) to authorize `:view_feature` and confirm the feature genuinely belongs to the parsed project — catching a spliced/cross-project feature id that project-level authorization alone would miss. Every failure mode (unknown, removed, cross-project, malformed link, feature-not-of-project) collapses to the identical `{:error, :not_found}`; returns the notification's own stored `link_path` on success. Implemented in parallel with Task 5 (see that entry for the disjoint-files note).
- Remaining: Task 4 (accessible notification inbox LiveView) and the verification gate.
- Failed checks: None.
- Proof receipts:
- Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/notification_safe_link_test.exs` — exit `0`.
  (Independently re-run and confirmed by the orchestrating session.)
- Spec updates: `tasks.md` Task 3 checked complete.

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
