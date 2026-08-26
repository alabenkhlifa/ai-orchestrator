# Worker-Initiated Pairing Progress Log

### 2026-08-26 - Task 2 complete: redemption binds the workspace and pairs in one transaction

- Added `Pairing.redeem_pairing/3`. It is the moment an unbound attempt stops being inert. Creating the worker and claiming the attempt happen in one transaction, so an attempt is never left bound to a workspace with nobody holding the credential.
- The claim is a single conditional `UPDATE` whose guard lives in the `WHERE` clause, not a read followed by a write. An attempt already confirmed, canceled, or bound to another workspace matches no row, so the database decides the winner. A redemption that loses the claim calls `Repo.rollback/1`, which discards the worker row it had already inserted, leaving nothing behind.
- A code that was issued already bound, by `start_pairing/2` for the dashboard or the deep link, is redeemable here too, but only against the workspace it was issued for. That is what makes this safe to expose: holding someone else's code does not let a redeemer pull it into their own workspace. A test proves the refused attempt is left untouched so its rightful owner can still redeem it.
- Every refusal answers `{:error, :invalid_code}`. Expired, canceled, already redeemed, wrong secret, foreign workspace, malformed, empty, and never existed are deliberately indistinguishable. The test asserts this by collecting all seven answers and checking they reduce to one value, so a future change that reintroduces a specific reason fails.
- `complete_pairing/2` is untouched and still returns its own `:expired` and `:invalid_or_used` reasons. `specs/36`'s `POST /worker_pairings` contract is unchanged, and a test asserts that rather than assuming it.
- Honest limit on the concurrency proof: the test sandbox shares one connection, so the two redemptions serialize rather than racing in wall-clock time. The test proves the conditional claim refuses the second redemption even when it arrives from another process, and the atomicity itself rests on the single `UPDATE`. True parallel execution is not exercised here and would need a shared-mode sandbox.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (8 passed); the second is the regression check across every existing pairing caller and Task 1's own suite (34 passed).

- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/pairing_redemption_test.exs` — exit `0`.
- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/pairing_test.exs test/sdd_orchestrator/devices/unbound_pairing_attempt_test.exs test/sdd_orchestrator_web/controllers/worker_pairing_controller_test.exs test/sdd_orchestrator/worker/pairing_test.exs` — exit `0`.

- Directly applicable safety checks: `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `mix dialyzer` pass, and `mix credo --strict` reports no issues on the changed module.
- Failed checks: None.
- Remaining: `Task 3` is next and is unblocked. It exposes the anonymous issuance endpoint that lets an app obtain one of these codes.
- Spec updates: `Task 2` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed.

### 2026-08-26 - Task 1 complete: a pairing attempt may now exist unbound

- Added `device_workspace_id` nullability and the check constraint `pairing_attempts_bound_before_use_check` in one migration. The constraint reads `device_workspace_id IS NOT NULL OR (confirmed_at IS NULL AND worker_id IS NULL)`. It makes the third shape unreachable: an attempt that confirmed a pairing or holds a worker while belonging to no workspace, which would be a credential attached to nobody.
- `PairingAttempt` gained `create_unbound_changeset/2`. It does not cast `device_workspace_id`, so a caller cannot pass one in through the attrs map. An unbound attempt is unbound by construction, not by the caller choosing to omit a field.
- `create_changeset/2` is unchanged and still requires a workspace, so `Pairing.start_pairing/2`, the dashboard, the deep link, and `POST /worker_pairings` behave exactly as before. A test asserts that rather than assuming it.
- Correction to the task's recorded `Size: Exception` reason: it names a backfill, and none was needed. Every existing row already carries a workspace and already satisfies the new constraint, so the migration performs no data change. The exception itself still holds for the reason that matters: relaxing the column without the constraint in the same migration opens a window where the invalid shape is reachable.
- The `down` migration deletes unbound rows before restoring `NOT NULL`. Those rows authorized nothing by construction, so discarding them loses no pairing anyone holds. Rollback and re-apply were both exercised against the development database.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (8 passed); the second is the directly applicable regression check on every existing pairing caller (26 passed).

- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/unbound_pairing_attempt_test.exs` — exit `0`.
- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/pairing_test.exs test/sdd_orchestrator_web/controllers/worker_pairing_controller_test.exs test/sdd_orchestrator/worker/pairing_test.exs` — exit `0`.
- Directly applicable safety checks: `mix compile --warnings-as-errors` and `mix format --check-formatted` pass, and `mix credo --strict` reports no issues on the changed module.
- Failed checks: None.
- Remaining: `Task 2` is next and is unblocked. `capability:workspace-bound-local-worker-authorization` is ready.
- Spec updates: `Task 1` checked complete and the slice moved to `In Progress`. No requirement, design decision, acceptance criterion, or task boundary changed.

### 2026-08-26 - Specification created from a gap found while testing locally

- Completed: Wrote `requirements.md`, `design.md`, and this plan. Product requirements are `Approved`; tasks are `Not Started` with `Task 1` executable now.
- Trigger: pairing a freshly installed worker app was impossible. The `Open in App` deep link only renders at `/onboarding/local` with a project parameter. That address needs a project, a local project needs a paired worker, and a paired worker needs a code. Nothing broke the cycle.
- Decisions the user made: the app fetches its own code and shows it; the code is created unbound and is attached to a Mac project space only when an owner redeems it; clicking the menu-bar status line copies the code; the app refreshes the code before it expires.
- Scope: `split required` against `specs/02-local-project-onboarding/` and `specs/36-local-worker-native-distribution/`. Both are `Verified`. This work adds an anonymous trust boundary and changes `PairingAttempt`'s lifecycle, so neither should absorb it. Both stay unchanged and this slice consumes their capabilities instead.
- Found while inspecting: the code format is an attempt id joined to a random secret, so collisions are impossible by construction rather than by a check. The design keeps that property. The pairing form's placeholder advertises a short code the product has never issued; `Task 4` corrects it.
- Failed checks: None. No code was written.
- Proof receipts: None yet.
- Spec updates: New specification. `specs/02` and `specs/36` are untouched.
