# Distribution-Free Worker Control Progress Log

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
