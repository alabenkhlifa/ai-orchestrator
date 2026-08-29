# Distribution-Free Worker Control Progress Log

### 2026-08-29 - Task 1 complete: the run state needs no live node

- The cheapest of the five calls, and it confirms the pattern: `RunState.load/1` reads a file under `Configuration.home/1`, which falls back to the worker's home directory when the application env is unset, so a fresh `eval` VM sees exactly what the running release sees. No behavior changed.
- The test asserts the negative as well as the positive: across all four answer shapes, `rpc` never appears in the arguments. The repository-wide version of that assertion stays `Task 5`'s.
- One reference was disambiguated rather than deleted: the doc comment cited `AC-05` for the quit warning, which belongs to `specs/36-local-worker-native-distribution`, and this specification now has its own unrelated `AC-05`. Both are named with their specification.
- Focused proof, confirmed on the main thread by real exit status `0` with `Executed 257 tests, with 0 failures`. `swift build` exit `0`. Runner receipt:
- Proof receipt: `Task 1` — scope `Focused` — command `swift test` — exit `0`.
