# Worker-Initiated Pairing Progress Log

### 2026-08-27 - Design correction: binding and completion are separate, and Task 2 reopens

- Found by `Task 4`'s own proof, not by review. Four LiveView tests failed: after a valid code was redeemed, the screen never reached `data-worker-status="detected"`. The cause is not the test. `WorkerDiscovery.status/2` reports a worker `:incompatible` when it states no `os_family`, `os_major`, or `protocol_version`, and unreachable when it has no `last_seen_at`. A worker the dashboard creates has none of those, because the dashboard is not the worker.
- The deeper problem the failure exposed: `redeem_pairing/3` returned the per-worker credential to the browser. The app needs that credential to connect, and a browser cannot hand it over. The flow as designed could never have produced a working worker.
- The decision that caused it was mine and its stated reason was false. "Binding and completion are one transaction" was justified by claiming that an attempt bound but not completed is a workspace-attached credential with no holder. That is exactly the normal state of today's dashboard-issued pairing: `start_pairing/2` creates a bound attempt and the worker completes it later through `POST /worker_pairings`. The state has always existed and has always been safe, because the code is what completes it and only its holder has that.
- Corrected design, now recorded in `design.md` with the replaced tradeoff kept: redemption binds the attempt to the owner's workspace and stops. The app completes it through the existing `POST /worker_pairings`, reporting its own versions and receiving its own credential. Each step is done by the party that can actually do it.
- The safety property survives the split and needs nothing new to enforce it. `complete_pairing/2` builds the worker with the attempt's workspace; for an unbound attempt that is `nil`, which `LocalWorker.create_changeset/2` rejects as required, and `Task 1`'s check constraint independently forbids confirming an attempt that belongs to no workspace. Two separate mechanisms already refuse it.
- `Task 2` reopens. Its `Size:` drops from `Exception` to `Standard`, because binding alone is one conditional update and no longer spans two things that must be atomic together. Its committed code and test need reworking; the commit stays in history rather than being rewritten.
- `Task 1` and `Task 3` are unaffected and stay complete. Neither the unbound state nor anonymous issuance changes.
- Acceptance criteria reworded to match, without weakening any: `AC-04` now ends at the flow continuing once the worker comes online, `AC-05` is about a second binding rather than a second worker, and `AC-08` now includes the app receiving its own credential.
- Failed checks: `Task 4`'s proof is failing and stays failing until `Task 2` is reworked. That is the correct order; the code is wrong, not the test.
- Spec updates: `requirements.md` workflow step 5, one business rule, and `AC-04`, `AC-05`, `AC-08`. `design.md` approach, the replaced decision, and interfaces. `tasks.md` `Task 2`, `Task 4`'s proof, `Task 7`'s proof, the implementation boundary, and one verification-gate line.

### 2026-08-27 - Correction: the acceptance-criterion ownership map was wrong

- Found before starting `Task 4`, by checking what it actually owns rather than trusting the map I wrote. `Task 4` delivers the dashboard redemption surface but owned `AC-01`, which describes the worker app obtaining a code and showing it in the menu bar. `Task 4` can neither deliver nor prove that. The validator accepted it because every criterion had exactly one owner; one owner is not the same as the right owner.
- Second problem in the same map: `Task 2` owned `AC-04`, whose last clause is "the repository flow continues". That is only deliverable by `Task 4`'s LiveView, so the criterion had no owner that could prove all of it.
- Corrected ownership: `Task 2` owns `AC-05` and `AC-06`, which is exactly what its domain proof already covers. `Task 4` owns `AC-04`, the user-visible redemption workflow. `Task 5` owns `AC-01` and `AC-07`.
- `AC-01` and `AC-02` were also reworded so each is provable by one task. `AC-01` is now about the app obtaining and holding a live code. `AC-02` absorbed the menu-bar unpaired state it used to share with `AC-01`, alongside the click-to-copy behavior it already had. Nothing was weakened: both halves are still asserted, and `Task 6`'s proof line was updated to match.
- No completed history was rewritten. `Task 1`, `Task 2`, and `Task 3` remain complete and their recorded proofs still cover what they claim. `Task 2` losing `AC-04` does not invalidate its proof; the domain behaviour it proved is unchanged, and `Task 4` will exercise that same function end to end.
- Earliest stage blocked: active-slice implementation, which is why this was fixed before `Task 4` rather than after.
- Failed checks: None. `validate_spec.py` and the global graph pass.
- Spec updates: `requirements.md` `AC-01` and `AC-02` wording, and `tasks.md` `Owns:` lines for `Task 2`, `Task 4`, `Task 5` plus `Task 6`'s proof line. No workflow, business rule, design decision, task boundary, or capability edge changed.

### 2026-08-27 - Task 3 complete: anonymous issuance, bounded and audited

- Added `POST /pairing_codes` (`PairingCodeController`) and `Pairing.issue_unbound_code/2`. An app that has never been paired holds no credential and knows no workspace, so it cannot authenticate to ask for a code, and this endpoint does not ask it to.
- What makes that safe is what the call produces, not who made it: an attempt bound to nothing, which authorizes nothing anywhere until an owner redeems it. A code intercepted in transit is worth nothing to whoever intercepts it.
- The request body is ignored entirely. A test posts a workspace, a project, an account, a chosen `code_digest`, and a far-future expiry, and asserts none of them are honored: the attempt is still unbound, the digest is the server's, and the expiry is the server's. Nothing a caller sends can widen what it gets back.
- `PairingIssuanceThrottle` follows `HostedAccess.RateLimiter`: per-caller and global token buckets consumed together, so one noisy source cannot exhaust the service and many quiet ones cannot either. The caller key is HMAC'd with a per-process secret before it enters state, buckets hold only a token count and a timestamp, and they live in memory, so nothing describing a person or a machine is retained and the window expires with the process.
- Rate settled, the engineering choice `design.md` left open: 30 per caller per 10 minutes, 300 globally per minute, in `config :sdd_orchestrator, :pairing_issuance`. An unpaired app replaces its code before the ten-minute expiry, so one app needs roughly six an hour; the caller allowance leaves room for several apps behind one address.
- A refusal reveals nothing about an earlier code. The test exhausts the rate with an unredeemed code outstanding, then again with that code redeemed, and asserts the two `429` answers are identical.
- `PairingSecurityLog` records only `event=issue_code` and an outcome. A test asserts the log contains neither the code, nor its secret, nor the caller address, and that a throttled refusal is audited too.
- Found while running the security scan, and fixed under `specs/01` and `specs/02` rather than here: `mix sobelow --config` was exiting 1 because of `new_git_repository/0`, a browser-harness helper added during those slices after their sobelow run. Both slices recorded a passing sobelow that a later edit had invalidated. See the 2026-08-27 correction entries in their own progress logs.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (8 passed); the second is the regression check across every device and pairing suite (118 passed).

- Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator_web/controllers/pairing_code_controller_test.exs` — exit `0`.
- Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/ test/sdd_orchestrator_web/controllers/worker_pairing_controller_test.exs test/sdd_orchestrator/worker/pairing_test.exs` — exit `0`.

- Directly applicable safety checks: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix dialyzer`, and `mix sobelow --config` pass, and `mix credo --strict` reports no issues on the three new modules.
- Failed checks: None outstanding.
- Remaining: `Task 4` and `Task 5` are both unblocked and independent. `Task 4` makes the dashboard field redeem a real code; `Task 5` makes the app acquire and refresh one.
- Spec updates: `Task 3` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed; the issuance rate was an open engineering choice and is now recorded above.

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
