# Guided Delivery Notification Access Tasks

## Status

Verified

All five tasks complete. `capability:guided-delivery-notification-access` and `capability:guided-delivery-notification-governance` are both ready. Implementation, local-verification, and release readiness are all complete — this slice declares no release gates.

## Active Slice

Deliver durable, authorized guided-delivery notification listing, unread and mark-read behavior, safe feature-link access, an accessible responsive inbox, and 90-day Slice 07 notification retention without changing delivery workflow state.

## Cross-Specification Dependencies

Requires:

- `capability:guided-delivery-notification-projection` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:project-participation-recipient-routing` — provider `specs/08-project-participation#Task 36` — required before `Task 1`.

Provides:

- `capability:guided-delivery-notification-access` — ready after `Task 4`.
- `capability:guided-delivery-notification-governance` — ready after `Task 5`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Authorized notification queries, durable unread state, idempotent mark-read, and PubSub-independent recovery.
- Safe internal feature-link authorization and non-disclosing denial.
- Responsive accessible notification presentation.
- Ninety-day retention for Slice 07 account-notification records.

Excluded:

- Lifecycle-event projection, recipient-role selection, event deduplication, or notification-body creation owned by Slice 07 Task 36.
- Participation identity, membership, display-profile repair, invitation, removal, or role mutation owned by Slice 08.
- External notification channels.
- Feature, run, review, assignment, or participation mutation from notification access or retention.

Deferred after this slice:

- External delivery channels and user-configurable notification preferences.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Implement authorized notification listing.
  - Size: Standard
  - Proof scope: Focused
  - Status: Done.
  - Depends on: none
  - Purpose: Return only the current participant's authorized guided-delivery notification records with durable unread state and minimized content.
  - Owned surfaces: Recipient-scoped notification query, Slice 07 event filtering, newest-first stable ordering, bounded pagination, current-participation revalidation, missing-profile-independent routing consumer, removed and cross-project denial, minimized list value, and fixtures.
  - Owns: AC-01
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/delivery/notification_access_test.exs` passes focused current, removed, cross-project, event-filter, ordering, pagination, unread, minimized-content, and missing-profile routing cases.

- [x] Task 2 — Deliver durable unread and idempotent mark-read behavior.
  - Size: Standard
  - Proof scope: Focused
  - Status: Done.
  - Depends on: Task 1
  - Purpose: Preserve recipient action state across duplicate actions, disconnected browsers, and application restart without treating PubSub as delivery.
  - Owned surfaces: Authorized notification read, idempotent mark-read transition, duplicate submission handling, durable unread recovery, PubSub-disabled behavior, reconnect and restart fixtures, and workflow-state non-mutation.
  - Owns: AC-02
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/delivery/notification_read_state_test.exs` passes focused unread, repeat mark-read, concurrency, no-PubSub, reconnect, restart, and state-non-mutation cases.

- [x] Task 3 — Enforce safe notification-link access.
  - Size: Standard
  - Proof scope: Focused
  - Status: Done.
  - Depends on: Task 1
  - Purpose: Return an authorized recipient to the related feature without disclosing inaccessible project or notification existence.
  - Owned surfaces: Internal feature-reference parsing, notification-recipient binding, current project and feature authorization, removed-participant denial, unknown and cross-project reference equivalence, redirect result, and fixtures.
  - Owns: AC-03
  - Proof: `python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/delivery/notification_safe_link_test.exs` passes focused current, removed, unknown, malformed, cross-project, stale-feature, and non-disclosing response cases.

- [x] Task 4 — Deliver the accessible notification inbox.
  - Size: Standard
  - Proof scope: Focused
  - Status: Done. `capability:guided-delivery-notification-access` is ready.
  - Depends on: Task 2, Task 3
  - Purpose: Let current participants inspect and act on durable notifications across supported desktop and mobile layouts.
  - Owned surfaces: Notification LiveView and navigation affordance, unread and read presentation, minimized status and time display, mark-read interaction, safe-link interaction, empty and populated states, loading and refusal states, keyboard order, focus behavior, responsive layout, fixtures, `capability:guided-delivery-notification-access` provider, and readiness write-back.
  - Owns: AC-04
  - Proof: `python3 .agents/scripts/run_proof.py task --task 4 -- mix test test/sdd_orchestrator_web/live/notification_live_test.exs` passes focused LiveView authorization, empty, populated, read, safe-link, keyboard, focus, desktop, and mobile cases.

- [x] Task 5 — Enforce Slice 07 notification retention.
  - Size: Standard
  - Proof scope: Focused
  - Status: Done. `capability:guided-delivery-notification-governance` is ready.
  - Depends on: Task 2
  - Purpose: Remove expired guided-delivery notification projections without changing their authoritative workflow or participation sources.
  - Owned surfaces: Slice 07 event-namespace selection, 90-day read and unread boundary, shared retention-pruner rule, locked idempotent pruning, restart and reconciliation behavior, unrelated-notification preservation, workflow and participation non-mutation, fixtures, `capability:guided-delivery-notification-governance` provider, and readiness write-back.
  - Owns: AC-05
  - Proof: `python3 .agents/scripts/run_proof.py task --task 5 -- mix test test/sdd_orchestrator/privacy/delivery_notification_retention_test.exs` passes focused 89-day and 90-day, read, unread, unrelated-event, idempotency, lock, restart, reconciliation, and non-mutation cases.

## Verification Gate

- [x] All five acceptance criteria pass through focused domain, LiveView, and retention proof.
- [x] Removed, absent-profile, unknown, malformed, and cross-project notification access fails closed without content disclosure.
- [x] Durable unread and mark-read behavior passes with PubSub disabled and after restart.
- [x] Desktop and mobile inbox scenarios pass through `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e`.
- [x] `python3 .agents/scripts/run_proof.py slice -- mix check` passes.
- [x] The explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope.
- [x] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` passes before the browser matrix.
- [x] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [x] The individual specification validator and global capability graph pass, and both provided capability readiness write-backs are recorded.
- [x] New decisions and proof receipts are written back.

## Blocked Decisions

None. `capability:project-participation-recipient-routing` is ready from `specs/08-project-participation#Task 36`.

## Progress Log

See [progress.md](progress.md).
