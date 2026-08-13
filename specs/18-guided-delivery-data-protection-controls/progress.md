# Guided Delivery Data Protection Controls Progress Log

### 2026-08-13 — Task 4 complete: prohibit product analytics and secondary use; capability:guided-delivery-processing-controls ready

- Completed: Built `SddOrchestrator.Privacy.DeliveryDataUsePolicy`, mirroring the established `AIRuntimeDataUsePolicy`/`PortabilityDataUsePolicy` fail-closed purpose/consumer pattern for all 13 Slice 07 data classes Task 1 classified. `@prohibited_purposes` (advertising, analytics, identity tracking, model training, unrelated improvement) and `@prohibited_consumers` (advertising network, analytics processor, unrelated processor) are refused before any allowed-route lookup. Unlike the two reference policies, `:model_provider` and `:preview_provider` are NOT blanket-prohibited — guided delivery legitimately dispatches to a worker/model (`run_command`) and a configured preview provider (`preview_deployment`) as its core service, so both are ordinary consumers legitimate only through their one narrow approved route, still refused for every secondary-use purpose by the same fail-closed check. Proved AC-05's full negative contract: no analytics-shaped purpose anywhere in Task 1's field-level inventory (store/request/event/metric), no analytics/advertising member in Task 1's own closed classification enums, no stable-profile-building purpose, and the legacy `:operational_security_log`/`:ai_runtime_operational_log` telemetry remains governed personal data, not analytics.
- **Readiness write-back**: `capability:guided-delivery-processing-controls` (provider `specs/18#Task 4`) is now ready — Task 4 is checked complete with a passing Focused proof receipt below.
- Remaining: Implement Task 5 and the verification gate.
- Failed checks: None. (One formatting-only fix applied directly by the main thread after independent re-verification: `mix format` on the test file — no logic change, proof re-run and still 19 passed, exit 0.)
- Proof receipt: `Task 4` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/delivery_purpose_limitation_test.exs` — exit `0`.
  - 19 passed. Re-verified independently by the main thread, including after the formatting fix. `mix compile --warnings-as-errors` clean.
- Spec updates: None; task completed within its approved scope.

### 2026-08-13 — Task 3 complete: delivery-boundary minimization and redaction

- Completed: Built `SddOrchestrator.Privacy.DeliveryContentBoundary` — one shared, reusable minimum-content detector for credential-shaped keys/text, participant-email-shaped text, and a generic raw-event allowlist check, with a single typed refusal vocabulary (`{:error, :credential_detected | :email_detected | :raw_event_detected}`) — plus `DeliveryContentBoundaryAudit`, a field-name-only diagnostic log mirroring Task 2's audit pattern. The detector mirrors (does not call) `SecretBoundary`'s key/PEM vocabulary and `Comments`'s secret/email regexes, keeping this task's ownership self-contained and out of `lib/sdd_orchestrator/delivery/`. Proved AC-04 against every named boundary: credential/email detection (unit), worker normalized-event allowlist and raw-provider-event rejection (real `ProtocolCodec`/`EventIngestion` calls), comment and activity-payload negative persistence scans (real `Comments.add/4` and `ActivityEntry` changesets), and notification-body minimization (realistic `RunNotifications`-shaped fixtures).
- **Finding, not fixed (out of this task's scope — `lib/sdd_orchestrator/delivery/` is a read-only dependency)**: `SddOrchestrator.Delivery.ReviewDecision.record_changeset/2` (`lib/sdd_orchestrator/delivery/review_decision.ex`) validates review `feedback` for required-ness, decision-pairing, and a 4000-byte cap, but runs no credential or email scan — unlike `Comments.add/4`'s equivalent check on comment bodies. AC-04 names "review" as a covered boundary; today a rejection's free-text feedback could carry a pasted token or email and it would persist as-is. Proved directly (not merely asserted) with a real `ReviewDecision.record_changeset/2` call in `delivery_content_boundary_test.exs`'s "review-feedback" describe block, alongside proof that the new shared detector would have caught it. Recommend routing a fix to Slice 07 product code through its own workflow (likely `update-spec` against specs/07, or a small follow-on task) — flagging to the user in the final slice summary rather than resolving here.
- Remaining: Implement Tasks 4 through 5 and the verification gate.
- Failed checks: None. (One formatting-only fix applied directly by the main thread after independent re-verification: `mix format` on the two new files — no logic change, proof re-run and still 30 passed, exit 0.)
- Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/delivery_content_boundary_test.exs` — exit `0`.
  - 30 passed. Re-verified independently by the main thread, including after the formatting fix. `mix compile --warnings-as-errors` clean.
- Spec updates: None; task completed within its approved scope.

### 2026-08-11 — Task 2 complete: project and exceptional-support access

- Completed: Proved AC-02 at the privacy-specification level by exercising the already-approved `SddOrchestrator.Delivery.ParticipantGuard` directly (current participant, absent, stale, removed, cross-project, and unknown-project identities all deny identically, without content disclosure) — no gap found, no Slice 07 product code touched. Built the wholly new AC-03 exceptional-support boundary: `SddOrchestrator.Privacy.DeliverySupportElevation` (schema + migration `20260811130000_create_delivery_support_elevations`, one grant per project incident, closed `purpose`/`scope` enums, `scope` defaults to `:metadata` so a grant never authorizes content access unless explicitly elevated, expiry required and DB-constrained to ≤24h, revocation paired with revoker by a DB check constraint), `SddOrchestrator.Privacy.DeliverySupportAccess` (`issue/1`, `authorize_content_read/2`, `revoke/2`, fail-closed and non-disclosing across absent/malformed/wrong-project/metadata-only/expired/revoked — same shape as `ParticipantGuard.authorize/2`), and `SddOrchestrator.Privacy.DeliverySupportAudit` (allowlisted, content-free audit log mirroring `IdentityLinking.Audit`'s pattern, at `:warning` level for operational visibility).
- Remaining: Implement Tasks 3 through 5 and the verification gate.
- Failed checks: None.
- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/delivery_access_controls_test.exs` — exit `0`.
  - 28 passed. Re-verified independently by the main thread. `mix format --check-formatted` and `mix compile --warnings-as-errors` clean on all new/changed files.
- Spec updates: None; task completed within its approved scope. One follow-up noted, not acted on: the new `delivery_support_elevations` table is support-governance metadata (not Slice 07 delivery content), so it is intentionally outside Task 1's `DeliveryProcessingInventory` scope — flagged here for whichever later specification governs operations/support tooling's own data inventory, not for this slice to resolve.

### 2026-08-11 — Task 1 complete: Slice 07 processing inventory

- Completed: Added `SddOrchestrator.Privacy.DeliveryProcessingRecord` (new struct, kept separate from the legacy `DataProcessingRecord` to avoid touching the 27 already-approved records) with a closed classification vocabulary (`basis`, `authority`, `recipient_category`, `processor_category`, `transfer_classification`, `lifecycle_owner`) and a `validate/1` that reports every failing field at once. Added `SddOrchestrator.Privacy.DeliveryProcessingInventory` holding one record per persisted field across all 13 Slice 07 (+ delivery-namespace Slice 08 notification) schemas — field lists are read live via each schema's `__schema__(:fields)` reflection, so `missing_fields/0`/`unknown_fields/0` catch drift automatically instead of via a hand-maintained list. Lifecycle owner classifications point at specs/17 (implemented), specs/19, specs/20, and specs/21 by actual scope, none of which enforce retention here — this task only classifies.
- Remaining: Implement Tasks 2 through 5 and the verification gate.
- Failed checks: None.
- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/delivery_processing_inventory_test.exs` — exit `0`.
  - 44 passed. Re-verified independently by the main thread. Legacy `test/sdd_orchestrator/privacy/processing_inventory_test.exs` re-run unchanged and still green (6 passed), confirming no regression to the 27 existing records.
- Spec updates: None; task completed within its approved scope. Two judgment calls made within scope, recorded here rather than as spec changes: `processing_confirmation` fields are classified `recipient_category: :operations_support` (compliance evidence, not participant-facing UI) rather than `:current_participants`; `run_attempt` lease/fence fields and `blocking_question` checkpoint/branch/workspace_path are classified `:worker_or_provider_capability` (execution machinery) rather than inheriting their entity's default `:current_participants`.

### 2026-08-11 — Unblocked, implementation started

- Completed: Confirmed `capability:guided-delivery-data-surfaces` (`specs/07-guided-specification-delivery#Task 54`) and `capability:guided-delivery-notification-access` (`specs/17-guided-delivery-notification-access#Task 4`) are both ready via `capability_index.py`. Corrected the stale `## Status: Blocked` header and Task 1 status to `In Progress`, and cleared `## Blocked Decisions`. Created branch `slice/18-guided-delivery-data-protection-controls` from up-to-date `main` in worktree `sdd-orchestrator-s18` and primed it.
- Remaining: Implement Tasks 1 through 5 and the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass.
- Proof receipts: None yet.
- Spec updates: Status corrections only; no requirements or design change.

### 2026-08-02 — Focused child specification created

- Completed: Moved unfinished processing, access, redaction, analytics, and secondary-use controls out of the Slice 07 umbrella without changing approved behavior.
- Remaining: Publish the completed guided-delivery data surfaces, complete notification access, then implement Tasks 1 through 5 and the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass; implementation has not started because required provider capabilities are unavailable.
- Proof receipts: None.
- Spec updates: Added focused ownership for processing inventory, project and support access, content boundaries, purpose limitation, and runtime negative proof.
