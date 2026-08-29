# Distribution-Free Worker Control Progress Log

### 2026-08-29 - Slice gate: proved on the machine that could not run the app at all

- `capability:distribution-free-worker-control` is ready.
- The product proof ran under the real condition rather than a simulation of it. Erlang distribution was confirmed broken first, by two fresh unrelated nodes with a matching cookie answering `pang`, and only then was the app installed and paired. This is the same machine on which the previous build could not finish pairing at all.
- States seen, in order: the menu offering a pairing code; the code redeemed in the dashboard; the app's own coding-agent step; `worker.json` written by the app itself; `connection_status.json` reading `connected`; the menu reading `Connected`; and after Quit, no worker process left. That covers AC-01, AC-02 and AC-03 on a machine where every one of them failed before.
- The negative half of AC-05 holds two ways: a direct search for an rpc argument array across both targets' sources returns nothing, and the guard test that enforces it was proved to fail by mutation rather than assumed to work.
- Verification gate result: every item passes. `mix check` `4681 passed`, the worker app suite `261 passed`, and the product proof above.
- Runner receipts:
- Proof receipt: slice — scope `Broad` — command `mix check` — exit `0`.
- Proof receipt: slice — scope `Broad` — command `swift test` — exit `0`.
- Release readiness is separate and unchanged. This slice adds no release gate; distributing a build carrying it stays governed by `specs/36-local-worker-native-distribution`'s signing and notarization gate, and the build proved here is unsigned.

### 2026-08-29 - Task 5 complete: the last call is gone and a guard keeps it that way

- `capability:distribution-free-worker-control` is ready. No call the app makes into its embedded release needs a name service, a listening socket, or an incoming connection.
- The rpc line was the entire graceful-shutdown path, so removing it changed the mechanism and not just the transport. SIGTERM is now the graceful step, which the BEAM already handles as an orderly shutdown, with SIGKILL as the last resort. `timeout` became the whole budget: grace is `max(timeout - 1, 0.5)` and the kill gets a one second reap, so the default stop dropped from ten seconds to five. On a distribution-blocked Mac this also removes the timeout every pairing restart used to pay.
- The `CommandRunning` dependency left `WorkerProcessController` entirely, which made a stronger test possible than a fake would have: the tests run a real child, a shell stand-in that logs its own arguments, so `start` being the only invocation is observed rather than asserted against a double.
- The guard is not decorative. It walks both targets' `Sources` from the test file's own path, matches an argument array whose first element is the literal `rpc` rather than the substring, and refuses to pass if it cannot find the sources or sees implausibly few files. It was proved three ways by mutation: reintroducing an rpc call failed it and named the file, pointing it at a missing directory failed it loudly rather than vacuously, and deleting the SIGKILL line failed the stop test.
- Discovery worth keeping: because `start` deliberately inherits the app's stdio, a child that survives a stop holds that pipe open, so with SIGKILL removed the test run hung rather than merely failing. The shipped code always fires SIGKILL, so this cannot happen in the product, but it explains why the last resort matters beyond tidiness.
- Recorded limit: the quit ordering, that the active-run check happens before the stop, lives in `AppDelegate` behind an `NSAlert` and `.terminateLater`. The decision itself is unit-tested; the wiring belongs to the slice's product proof.
- Focused proof, confirmed on the main thread by real exit status `0` with `Executed 261 tests, with 0 failures`, and `swift build` exit `0`. A direct search for `["rpc"` across both targets' sources returns nothing. Runner receipt:
- Proof receipt: `Task 5` — scope `Focused` — command `swift test` — exit `0`.

### 2026-08-29 - Task 3 complete: the menu reads the state from the file

- The status path is now distribution-free end to end. Reading is a plain file read: no subprocess, no command runner, no Elixir expression, so nothing here can be refused by a firewall.
- Every failure answers unknown, and each failing case also asserts it is not connected: missing file, unreadable file, bytes that are not JSON, an empty file, a JSON array rather than an object, an object with no `status`, a non-string `status`, and an unrecognised status string. A stale claim of health is the one outcome this must never produce.
- The two sides are pinned to one byte shape by a fixture taken from the Elixir encoder rather than written by hand, which caught two things a guess would have got wrong: `Jason.encode!(pretty: true)` sorts the keys, and it emits no trailing newline.
- The file path comes from `WorkerPaths.workerHome/1`, and a test asserts the status file lands in the same directory as the configuration, so the app's mirror of the release's storage root cannot drift silently.
- One test skips as root, because root can read a `0600`-denied file and the case would then fail for a reason unrelated to the code. It did not skip in this run.
- Focused proof, confirmed on the main thread by real exit status `0` with `Executed 252 tests, with 0 failures`, and `swift build` exit `0`. Runner receipt:
- Proof receipt: `Task 3` — scope `Focused` — command `swift test` — exit `0`.

### 2026-08-29 - Task 4 complete: pairing no longer calls into the running node

- The call whose failure made the app unusable rather than merely uninformative. Both pairing paths now write `worker.json` themselves through one `WorkerConfigurationStore`, which holds the single app-side copy of the permission rules, and then restart the release. `MacPairingRetention` runs no command at all any more and lost its binary path, command runner, and rpc timeout.
- The storage root is one owned value. `WorkerPaths.workerHome/1` mirrors `Configuration.home/1` and resolves `$HOME` first, because the release reads `System.user_home!/0` from the environment and is this app's own child, so both sides agree by construction rather than by coincidence.
- Two changes inside `WorkerProcessController` that the restart forced, both worth keeping. A `Process` is single use, so the child became a per-launch `var` rather than one instance built in `init`. And the single `expectedStop` flag became a set keyed by child identity, because a restart starts the new child while the old child's termination handler may still be in flight, and one flag would either let the new child inherit the old expectation or blame the old child's exit on nobody.
- Both RPC expression builders and their tests are deleted; nothing else referenced them.
- Honest limit of the assertion here: with no command runner left, `MacPairingRetention`'s "nothing reaches `rpc`" is an argument from the type's shape rather than a runtime check. The executable version lives in the deep-link path's tests, which still have a command runner for agent detection and assert that nothing that ran carried `rpc`, a credential, a repository path, or a project id.
- Known slowness until `Task 5`: `WorkerProcessController.stop` still calls `rpc "System.stop()"` first, so on a distribution-blocked Mac every pairing restart waits out that call's timeout before falling through to a signal. AC-01 is still reached, just slowly, and `Task 5` removes it.
- Recorded difference, not a defect: the app writes `worker.json` compact while the release writes it pretty. Same content, and the release stays the only reader and still validates what it loads.
- Focused proof, confirmed on the main thread by real exit status `0` with `Executed 246 tests, with 0 failures`, and `swift build` exit `0`. Runner receipt:
- Proof receipt: `Task 4` — scope `Focused` — command `swift test` — exit `0`.

### 2026-08-29 - Task 2 complete: the release reports its connection state to a file

- `connection_status.json` sits beside `worker.json` under `Configuration.home/1`, reached through a new `ConnectionStatus.path/1` that mirrors `Configuration.path/1` rather than resolving the path a second way. It carries the state, the reason, and when it changed, and nothing else.
- The reason is an arbitrary term today, such as `{:topic_closed, :normal}`, so it is rendered with `inspect/1` into a display string instead of being forced into structured JSON. A string reason passes through untouched.
- The write is a temporary file renamed over the target, so a reader sees either the previous file or the complete new one. Correction to `design.md`, which claimed this copied `Configuration.store/2`: that function is a plain write and is not atomic. The status file is deliberately the stricter of the two, and raising the configuration to the same bar is recorded as a separate decision rather than done here.
- A publish failure never reaches the caller. These writers are side effects of `GatewayConnection` callbacks and must keep returning `:ok`, so the failure is rescued and logged by reason alone, never by path.
- Fixed on the main thread, found by the sub-agent and outside its owned paths: the change made `gateway_connection_test.exs` and `mac_scoped_connection_end_to_end_test.exs` write into the developer's real `~/.sdd_orchestrator/worker`, because they drive the real callbacks and never redirected `:worker_home`. Both now point at a temp directory for the duration of the test, so running the suite can no longer disturb a worker actually running on the machine.
- Focused proof, confirmed on the main thread by real exit status `0` with `Result: 33 passed`, run across the status suite and both suites that drive the real callbacks. Runner receipt:
- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/worker/connection_status_test.exs test/sdd_orchestrator/worker/gateway_connection_test.exs test/sdd_orchestrator/worker/mac_scoped_connection_end_to_end_test.exs` — exit `0`.
- Directly applicable safety checks: `mix format --check-formatted` exit `0`, `mix compile --warnings-as-errors` exit `0`.

### 2026-08-29 - Task 1 complete: the run state needs no live node

- The cheapest of the five calls, and it confirms the pattern: `RunState.load/1` reads a file under `Configuration.home/1`, which falls back to the worker's home directory when the application env is unset, so a fresh `eval` VM sees exactly what the running release sees. No behavior changed.
- The test asserts the negative as well as the positive: across all four answer shapes, `rpc` never appears in the arguments. The repository-wide version of that assertion stays `Task 5`'s.
- One reference was disambiguated rather than deleted: the doc comment cited `AC-05` for the quit warning, which belongs to `specs/36-local-worker-native-distribution`, and this specification now has its own unrelated `AC-05`. Both are named with their specification.
- Focused proof, confirmed on the main thread by real exit status `0` with `Executed 257 tests, with 0 failures`. `swift build` exit `0`. Runner receipt:
- Proof receipt: `Task 1` — scope `Focused` — command `swift test` — exit `0`.
