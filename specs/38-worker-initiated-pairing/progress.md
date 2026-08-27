# Worker-Initiated Pairing Progress Log

### 2026-08-27 - AC-08 corrected: the app hands off instead of claiming a setup it cannot finish

- Found by the user on a real install: the menu bar sat on "Paired, setting up…" with no code and no way to pair. It was paired, by my own verification a few minutes earlier, and it could never leave that state.
- The defect: `Task 8`'s success handler did not even bind the completion result. It discarded the credential, set `urlPairingOverrideStatus = .pairedSettingUp`, and stored nothing, so the app claimed a setup that had no project to complete against and could never finish.
- Why my verification missed it, which is the part worth keeping: I said I had checked the real app, but what I actually queried was the database. A worker row appeared, so I called the round trip closed. That is the server's half again — the same mistake that caused the previous reopening. The correct check was what the app held afterwards, and it held nothing.
- Decision, chosen by the user from three options: the app must not claim it is paired or setting up. The pairing exists on the control plane so the dashboard sees a worker and onboarding can continue; the app says the dashboard has taken over and stops there.
- `AC-08` reworded to match, and the workflow and scope lines with it. Nothing was weakened: the previous wording promised the app "receives its own credential", which it cannot usefully keep without a project, so the promise was unkeepable rather than merely unmet.
- The limitation is now stated rather than implied, in `Out of Scope`, in a design consequence, and as a risk: a worker paired this way is authorized but cannot connect or run anything until something gives it a project, a folder, and an agent. That follow-on will need a credential this flow discards, and it is recorded in the deferred boundary.
- Rejected, and recorded as rejected: storing the credential now with an unset project. That needs a storage contract for a partially configured worker, which is a larger decision than this slice should make alone.
- Recovery performed on the user's machine: the app was quit, which clears the in-memory override, and the two `pairing_attempts` rows and one `local_workers` row my verification created were deleted. Nothing had been written to disk, so relaunching returns it to `Not paired` with a fresh code.
- `Task 8` reopened. Its loop and its decision function are unchanged and correct; only the success handler and the state it shows must change.
- Failed checks: none failing. `mix check` passed clean at the gate (4582 passed) while this defect was present, which is exactly why it is recorded here rather than treated as covered.
- Spec updates: `requirements.md` `AC-08`, one workflow step, one in-scope line, and a new out-of-scope line. `design.md` one new decision and one new risk. `tasks.md` `Task 8` reopened with corrected owned surfaces and proof, and one new deferred item.

### 2026-08-27 - Task 8 complete: the app now performs the round trip, verified against the real app

- `PairingLoop.next/4` decides what an unpaired app does each tick: fetch a code when it has none or cannot reach the control plane, replace one nearing expiry, otherwise try to finish. A paired app idles, and `AppDelegate` stops the timer entirely rather than idling in a loop.
- The app discovers that an owner redeemed its code by attempting completion. It needs no new endpoint and no new state to read: an unbound attempt cannot be completed, so a refusal means "not yet" and a success means an owner bound it — and that same call already returned the credential. A refusal shows the person nothing, because it is not a failure they caused or can act on.
- Replacing beats attempting when a code is inside the refresh margin, so the app never spends its last seconds on a completion attempt while the person may be about to paste that code.
- Verified against the installed app rather than only in tests, which is the whole reason this task exists. The running app fetched a real unbound code from the live control plane; binding that code the way the dashboard does produced a worker within about six seconds, with no interaction. The worker carries `macos`, major `26`, protocol `1`, app `0.1.0` — the facts only the app can report — and the attempt is confirmed and linked to it.
- What this task deliberately does not do: configure the paired worker. A worker-initiated pairing has no project yet by definition, and post-pairing setup needs one. `AC-08` promises the app finishes pairing, takes its credential, stops offering a code, and reports its state; what a paired worker may then do stays out of scope and belongs to `specs/33-local-worker-run-execution/`.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (7 passed); the second is the whole worker-app suite (208 passed).

- Proof receipt: `Task 8` — scope `Focused` — command `swift test --package-path native/worker-app/MenuBarApp --filter PairingLoopTests` — exit `0`.
- Proof receipt: `Task 8` — scope `Focused` — command `swift test --package-path native/worker-app/MenuBarApp` — exit `0`.

- Directly applicable safety check: `swift build -c release` links the AppKit target, so the timer and completion wiring compile and not only the loop decision.
- Failed checks: None.
- Remaining: the slice verification gate, then `Verified`.
- Spec updates: `Task 8` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed beyond the reopening already recorded.

### 2026-08-27 - Verified removed: the app performs none of the calls the round trip needs

- Found by installing the app and using it, not by any check. `POST /pairing_codes` answered `201`, the app was running, and the pairing still could not complete.
- Three gaps, all in the `AppDelegate` wiring rather than in anything a test covered:
  - `refreshPairingCode()` is called once from `setUpPairingCode()` and never again, so the held code is fetched once and never replaced. Ten minutes later it expires and the menu offers something the dashboard refuses, which is exactly what `AC-07` exists to prevent.
  - `refreshPairingStatus()` is likewise called once at startup, so an app that starts unpaired never re-checks.
  - The app never attempts completion with its held code at all. `PairingFlowController` is triggered only by the `sddworker://` deep link, so nothing calls `POST /worker_pairings` with the code the menu is showing. `AC-08` describes the app finishing for itself, and no code path did that.
- Why the proofs missed it, which is the part worth keeping: `Task 5` and `Task 6` tested the Core decisions — when to refresh, what the menu says — and both are correct. `Task 7` proved the round trip at the domain level, calling `bind_pairing/2` then `complete_pairing/2` directly. None of them exercised the AppKit wiring that has to perform those calls on a schedule. I then wrote that the round trip was closed, on evidence that covered only the half a test could reach easily.
- The slice verification gate did not catch it either, and could not have: it runs `mix check`, the browser matrix, and `swift test`, and none of those drive a running menu-bar app against a live control plane.
- Changes: `Verified` removed and the verification gate unchecked. `Task 8` added, owning the app's unpaired polling schedule, the periodic refresh, the completion attempt, and stopping once paired. `AC-07` moves from `Task 5` and `AC-08` from `Task 7` to `Task 8`, because the task that delivers an observable behaviour should own the criterion for it. `capability:worker-initiated-pairing` now becomes ready after `Task 8` rather than `Task 7`; it has no consumers, so nothing downstream is affected.
- `Tasks 1` through `7` stay complete and their proofs stand. They delivered their owned surfaces; they simply no longer own criteria they could not finish delivering on their own.
- `design.md` gains the decision that the app discovers binding by attempting completion — a refusal means not yet, a success means an owner redeemed it — and its earlier claim that the app "learns it has been bound by the status check it already performs" is corrected, since no such check ran while unpaired. Assuming that was already true is what allowed the premature `Verified`.
- Failed checks: none currently failing; the gap is missing behaviour rather than a failing assertion, which is why nothing reported it.
- Spec updates: `tasks.md` status, capability readiness, `Task 7` owned surfaces, `Owns:` lines for `Task 5` and `Task 7`, the new `Task 8`, and the verification gate. `design.md` approach and one new decision. No requirement, workflow, business rule, or acceptance-criterion wording changed.

### 2026-08-27 - Verification gate passed; slice Verified

- The gate found what focused proof could not, which is the argument for it existing. `mix check` failed with the retention rule registered in only one of the three places the framework closes it: `Retention.rules/0`, `RetentionRuleOutcome`'s `Ecto.Enum`, and the `retention_rule_outcomes_rule_allowed` check constraint. My task proof ran the retention suites I judged relevant and passed, because that contract is asserted in a delivery retention test I had no reason to name.
- Fixed by adding the enum value and a migration extending the constraint, following the precedent migration for the previously added rule, which writes both directions out separately so `down` is a real inverse.
- The advisory-lock band was also full: 32 rules, 32 reserved keys. Its own comment states the width is only ever "as many keys as there are rules" and that a new rule extends the upper bound by one, so the band is now `1_900_000_001..1_900_000_033` rather than a key invented outside it.
- Two accepted exceptions, both confirmed as suite pollution rather than defects, and both passing in isolation together (60 passed):
  - `SddOrchestrator.ProjectAssistant.SecurityLogTest` "emits nothing for a success". Its `capture_log` collected `[repository_initialization_security] event=confirm_plan outcome=denied_or_missing`, which is another async test's output. `capture_log` captures the global handler, so `assert log == ""` is fragile under parallel async execution. Pre-existing fragility in a specification this slice does not touch, and nothing of this slice's logs at `:info` during the async phase.
  - `SddOrchestrator.Delivery.Worker.IsolationTest` fence-token test, the same load-sensitive failure recorded earlier in this repository's history.
- Proof receipts, all confirmed on the main thread by real exit status:
  - `python3 .agents/scripts/run_proof.py slice -- mix check` — 4580/4582 passed, 1 excluded `:live` tag, with the two accepted exceptions above.
  - `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `... mix deps.audit`, `... mix sobelow --config` — exit `0`.
  - `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `... npm --prefix assets run test:e2e` — exit `0` (153 passed, 2 skipped, on each of `chromium` and `mobile-chromium`).
  - `python3 .agents/scripts/run_proof.py slice -- swift test --package-path native/worker-app/MenuBarApp` — exit `0` (201 passed).
  - `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `... env MIX_ENV=prod mix release --overwrite` — exit `0`.
- The changed pairing screen did not disturb the other slices' browser scenarios. The stand-in fallback kept them driving the flow with a placeholder code, which is why it was deliberately kept in Task 4.
- Verified against the built artifact, not only the configuration: the production release contains no `E2E` and no `FakeProvider` module, so neither the harness nor the anonymous-issuance stand-in exists in a production build.
- Status: `In Progress` to `Verified`. `capability:worker-initiated-pairing` is ready for implementation and local verification only.
- Release readiness is separate and remains open: if the control plane is hosted, the processor, region, and transfer safeguards covering anonymous issuance requests reaching it; and confirmation of the retention window for unredeemed attempts and issuance-throttle counters in the accountable privacy review.
- Spec updates: slice status and the verification gate. No requirement, design decision, acceptance criterion, or task boundary changed.

### 2026-08-27 - Task 7 complete: the round trip closes and the data rules hold

- The whole path is proven in one scenario: the app obtains a code that belongs to nobody, polls and is told "not yet", the owner pastes it into the dashboard, the app's next poll succeeds and takes its own credential, and the workspace can discover the worker — with no further action anywhere.
- One change was needed to make polling viable. `complete_pairing/2` now refuses an unbound attempt with its existing `{:error, :invalid_or_used}` instead of raising a changeset. The app learns whether an owner has bound its code by trying to complete it, so "not yet" has to be an ordinary reply rather than a 500. The guards themselves are unchanged: `LocalWorker.create_changeset/2` still requires a workspace and the check constraint still forbids confirming an unbound attempt. This turns a raise into a clean answer; it does not open anything.
- A refusal never consumes the code. A test polls five times before binding and then completes successfully, so a slow owner cannot strand the app with a code it has already spent.
- Retention added as `unredeemed_pairing_attempts`, deleting attempts that were never confirmed once a grace day past expiry. Anonymous issuance means anyone who can reach the control plane can create one, so they must not accumulate. An expired attempt can never authorize anything again, and the row holds only a random digest, its salt, and timestamps, so nothing describing a person or a machine survives either way. A test proves a live attempt and a completed pairing are both left alone.
- The log review is a test rather than an inspection. It runs a whole successful pairing and a whole failed one at `:info`, then asserts the log contains neither the code, nor the credential, nor either of their secret halves.
- One stale assertion corrected in Task 2's suite: it expected `Ecto.InvalidChangesetError` where completing an unbound attempt now refuses cleanly. The property it guards — an unbound attempt cannot be completed — is unchanged and still asserted, and a second test now proves the code survives that refusal.
- `capability:worker-initiated-pairing` is ready. Its readiness is implementation and local-verification only; release readiness stays separate and is recorded in the release gate.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (7 passed); the second is the regression across every pairing, issuance, redemption, and retention suite (62 passed).

- Proof receipt: `Task 7` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/worker_initiated_pairing_test.exs` — exit `0`.
- Proof receipt: `Task 7` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/worker_initiated_pairing_test.exs test/sdd_orchestrator/devices/pairing_test.exs test/sdd_orchestrator/devices/pairing_redemption_test.exs test/sdd_orchestrator/devices/unbound_pairing_attempt_test.exs test/sdd_orchestrator_web/controllers/worker_pairing_controller_test.exs test/sdd_orchestrator_web/controllers/pairing_code_controller_test.exs test/sdd_orchestrator_web/live/pairing_redemption_live_test.exs and every retention suite` — exit `0`.

- Directly applicable safety checks: `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `mix dialyzer` pass, and `mix credo --strict` reports no issues on the changed modules.
- Failed checks: None.
- Remaining: the slice verification gate.
- Spec updates: `Task 7` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed.

### 2026-08-27 - Task 6 complete: the status line is the copy action

- `PairingCodeMenu.statusLine/3` decides what the menu's first line says and whether clicking it copies. `PairingCodeCopier` performs the write. Both live in `SDDOrchestratorWorkerCore`, so the decision is unit-tested without AppKit and `AppDelegate` stays the thin wiring the package was built around.
- The line a person already reads for status is the one they click, so the single action pairing asks of them needs no second place to look. The code is roughly eighty opaque characters, so the clipboard is the only usable way to move it and showing it in full would only crowd the menu.
- Four unpaired states, each saying something true: a held code invites the click, a copied one confirms and stays clickable so a missed clipboard can be retried, an unreachable control plane is named rather than left silent, and no code yet reads as the ordinary unpaired line.
- A paired worker is never offered a code. A test walks every paired status and asserts the line is plain, so a stale action cannot appear on a worker that has nothing to pair.
- "Nothing copies without a click" is proven rather than asserted. The clipboard sits behind a `Pasteboarding` seam, and a test builds the line twice — including the just-copied variant — then checks the fake pasteboard was never written. Copying with nothing held writes nothing and reports `false`, so the menu cannot claim a copy that did not happen.
- `AppDelegate` drops the held code as soon as the status stops being `notPaired`, decided in `refreshStatus()` so no other path has to remember. The real clipboard adapter stays at the AppKit edge.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (8 passed); the second is the whole worker-app suite (201 passed).

- Proof receipt: `Task 6` — scope `Focused` — command `swift test --package-path native/worker-app/MenuBarApp --filter PairingCodeMenuTests` — exit `0`.
- Proof receipt: `Task 6` — scope `Focused` — command `swift test --package-path native/worker-app/MenuBarApp` — exit `0`.

- Directly applicable safety check: `swift build -c release` links the AppKit target, so the menu wiring compiles and not only the Core decisions.
- Failed checks: None.
- Remaining: `Task 7` closes the round trip and publishes `capability:worker-initiated-pairing`.
- Spec updates: `Task 6` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed.

### 2026-08-27 - Task 5 complete: the app holds a live code of its own

- Added `PairingCode`, `PairingCodeResponseParser`, and `PairingCodeHolder` to `SDDOrchestratorWorkerCore`. The holder asks `POST /pairing_codes` for a code when it has none and replaces it a minute before expiry, so a person who walks away and comes back copies something the dashboard still accepts rather than hitting a refusal they did not cause and could not diagnose.
- It sends nothing with the request, and a test asserts the body is empty. The app has no workspace, project, identity, or secret to name, which is the whole reason the endpoint is anonymous.
- A replacement drops the code it replaced in the same step, so the app never holds two and never shows the older one. A test distinguishes them by value rather than by count.
- An unreachable or refusing control plane is its own state, not an absence. `PairingCodeState.unreachable` exists so the menu can say the app cannot reach the control plane instead of silently offering nothing, and a failed refresh clears the held code rather than leaving a stale one on display that would be refused when pasted.
- The holder owns no timer. `AppDelegate` already runs a periodic check, so refreshing is driven from there and the decision stays a plain, testable function. That also keeps the refresh margin explicit rather than buried in a scheduler.
- Refresh margin settled, the second engineering choice `design.md` left open: 60 seconds against the control plane's ten-minute code. Comfortably longer than a fetch and a paste, while still using most of each code's life.
- The parser accepts an ISO 8601 timestamp with or without fractional seconds, so a rendering change on the control plane cannot silently stop pairing.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (11 passed); the second is the whole worker-app suite (193 passed).

- Proof receipt: `Task 5` — scope `Focused` — command `swift test --package-path native/worker-app/MenuBarApp --filter PairingCodeHolderTests` — exit `0`.
- Proof receipt: `Task 5` — scope `Focused` — command `swift test --package-path native/worker-app/MenuBarApp` — exit `0`.

- Failed checks: None.
- Remaining: `Task 6` puts this in the menu bar and on the clipboard. `Task 7` closes the round trip.
- Spec updates: `Task 5` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed; the refresh margin was an open engineering choice and is now recorded above.

### 2026-08-27 - Task 4 complete: the field redeems a real code and the screen waits

- The pairing field now calls `Pairing.bind_pairing/2` with this browser's own device workspace, so the submitted value is the thing that pairs rather than a value that was read and dropped.
- Binding no longer produces a worker, so the screen needed a state it did not have. It shows "Code accepted. Finishing on your Mac…" and hides the pairing form, because re-showing the form after a successful bind reads as nothing having happened and invites the person to paste a code that is already used.
- The screen catches up on its own. A connected LiveView polls `Devices.worker_status/1` every two seconds while a bound code waits, and stops as soon as the worker is detected or the person moves on. Only a connected socket schedules a poll, so the first static render leaks no timer.
- Placeholder corrected. It advertised `4K7Q-2P9X`, a short code the product has never issued; the real code is an attempt id joined to a 43-character secret. It now reads "Paste the code from the worker app", and a test asserts the old example is gone.
- One refusal message covers every rejected code, since `bind_pairing/2` already makes the reasons indistinguishable and saying more here would undo that.
- The local worker stand-in kept its fallback, deliberately. Where it is configured — development and the browser suite, never a production build — a code that fails to bind still drives the flow, because no app exists there to issue a real one and other slices' browser scenarios type a placeholder. A real code binds for real first, in every environment, and a test asserts the bind actually claimed the code rather than the stand-in having quietly stood in for it.
- Three failures during the work were mine, not the product's: the waiting flag was read inside a function component that never declared it; one assertion expected a refusal where re-binding to the same workspace is intentionally harmless; and one matched an apostrophe that HTML-escapes to `&#39;`.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (7 passed); the second is the regression across the local-onboarding flow, device setup, and every pairing suite (62 passed).

- Proof receipt: `Task 4` — scope `Focused` — command `mix test test/sdd_orchestrator_web/live/pairing_redemption_live_test.exs` — exit `0`.
- Proof receipt: `Task 4` — scope `Focused` — command `mix test test/sdd_orchestrator_web/live/pairing_redemption_live_test.exs test/sdd_orchestrator_web/live/local_onboarding_live_test.exs test/sdd_orchestrator_web/live/local_onboarding_flow_test.exs test/sdd_orchestrator_web/live/device_setup_live_test.exs test/sdd_orchestrator/devices/pairing_test.exs test/sdd_orchestrator/devices/pairing_redemption_test.exs test/sdd_orchestrator/devices/unbound_pairing_attempt_test.exs` — exit `0`.

- Directly applicable safety checks: `mix compile --warnings-as-errors` and `mix format --check-formatted` pass, and `mix credo --strict` reports no issues on the changed LiveView.
- Failed checks: None.
- Remaining: `Task 5` and `Task 6` are the worker app's own halves and are next. `Task 7` closes the round trip.
- Spec updates: `Task 4` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed.

### 2026-08-27 - Task 2 complete on the corrected design: binding only

- `Pairing.redeem_pairing/3` is replaced by `Pairing.bind_pairing/2`. It attaches the attempt to the redeemer's workspace with one conditional update and stops. It creates no worker and returns nothing the browser has to hold, which is the whole point of the correction: only the app knows its own versions and only the app should hold its credential.
- The app finishes through `complete_pairing/2` unchanged, which is the endpoint `POST /worker_pairings` already exposes. A test walks the whole path — bind, then complete with the versions only an app can report — and asserts the worker is discoverable in the workspace only after that second step.
- The Task 1 guard is now proven rather than assumed. Completing a code nobody has bound raises `Ecto.InvalidChangesetError`, because the worker would need a workspace the attempt does not have, and no worker row is created. That is the property that makes anonymous issuance safe, so it has its own test.
- Re-submitting a dashboard-issued code for the same workspace is harmless: the conditional update matches the already-bound row and changes nothing, and the code still completes once. This keeps `specs/36`'s deep-link path working when a person also pastes the same code.
- Concurrency is proven by outcome rather than by timing: exactly one of two bindings succeeds, and the attempt ends up owned by that winner. The sandbox shares a connection so the two serialize; atomicity rests on the single conditional update, as recorded when this test was first written.
- Task 2's `Size:` is now `Standard`. Binding alone is one update, so the earlier exception no longer applies.
- Call sites updated with the rename so the tree stays green: the local-onboarding LiveView and two assertions in Task 3's controller test. Task 4 still owns how the screen presents the new waiting state.
- Proof receipts, both confirmed on the main thread by real exit status. The first is the task's own proof (10 passed); the second is the regression check across every device, pairing, and issuance suite (128 passed).

- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/pairing_redemption_test.exs` — exit `0`.
- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/devices/ test/sdd_orchestrator_web/controllers/worker_pairing_controller_test.exs test/sdd_orchestrator_web/controllers/pairing_code_controller_test.exs test/sdd_orchestrator/worker/pairing_test.exs` — exit `0`.

- Directly applicable safety checks: `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `mix dialyzer` pass, and `mix credo --strict` reports no issues on the changed module.
- Failed checks: None. Task 4's own proof is still failing by design and is next.
- Remaining: `Task 4` resumes on the corrected contract and must now show the screen waiting for the app rather than a worker appearing instantly.
- Spec updates: `Task 2` checked complete. No requirement, design decision, acceptance criterion, or task boundary changed beyond the correction already recorded.

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
