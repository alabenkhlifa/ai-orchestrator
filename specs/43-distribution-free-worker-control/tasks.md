# Distribution-Free Worker Control Tasks

## Status

Verified

## Active Slice

Remove Erlang distribution from every call the worker app makes into its embedded release, so pairing, status, the active-run check, and quitting all work on a Mac whose firewall blocks it.

## Cross-Specification Dependencies

Requires:

- None.

Provides:

- `capability:distribution-free-worker-control` — ready after `Task 5`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- The five app-to-release calls that use `rpc` today, and the mechanism each moves to.
- The release's publishing of its connection state to a file, and that file's lifecycle.
- The app's own writing of the worker configuration, and its restart of the release process it already supervises.

Excluded:

- The worker's outbound websocket to the control plane, which is ordinary outbound networking and is unaffected.
- What the menu shows and when. `specs/42-worker-menu-status-presentation` owns the presentation and `specs/39-mac-scoped-worker-connection` owns the states themselves; both stay exactly as they are.
- The embedded release's supervision tree, run execution, and worker protocol.
- The `rpc` command in the release's start script, which stays available for debugging.
- Everything on the control-plane side.

Deferred after this slice:

- Removing `rpc` from the release's start script, if it is ever shown that nothing should be able to reach the node that way.

Release gates:

- None of its own. Distributing any build carrying this stays governed by `specs/36-local-worker-native-distribution`'s signing and notarization gate.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Read the run state without a live node.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Take the cheapest of the five calls off distribution first, and confirm the pattern the others follow.
  - Owned surfaces: `RunStateQuerier`'s invocation of the release start script.
  - Owns: AC-04
  - Proof: Focused tests cover the querier reading a run state through the command that needs no running node, the same lifecycle answers as today for an active run, no run, and an unreadable state, and the quit-time active-run check behaving unchanged.
  - Delivered: `RunStateQuerier` now uses `eval`. The run state is a file under `Configuration.home/1`, so a fresh VM reads what the running release would. Expression and parsing are unchanged.

- [x] Task 2 — Publish the connection state to a file the app can read.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give the app the one piece of live in-memory state it cannot get from a fresh VM, without a socket.
  - Owned surfaces: `Worker.ConnectionStatus`'s writing of the status file, the file's location and owner-only permissions, and its atomic replacement on each transition.
  - Owns: entity:RuntimeStatusFile
  - Proof: Focused tests cover every state transition writing the file, the file carrying the same state and reason `status/0` reports, the write being atomic and owner-only, and `status/0`'s own in-process answer staying unchanged.
  - Delivered: `ConnectionStatus` publishes `connection_status.json` beside `worker.json` on every transition, written to a temporary file and renamed over the target so only a complete file is ever visible. `status/0` still reads `:persistent_term` and is unchanged. A publish failure is rescued and the caller still gets `:ok`.

- [x] Task 3 — Read the connection state from that file instead of the node.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Complete the status path so the menu shows the truth on a machine where the node cannot be reached.
  - Owned surfaces: `ConnectionStatusQuerier`'s source of truth, and its handling of a missing, unreadable, or unparseable file.
  - Owns: AC-02
  - Proof: Focused tests cover each written state being read back as the matching connection state, a missing file reading as unknown, an unreadable or malformed file reading as unknown, and no state ever reading as connected without the file saying so.
  - Delivered: `ConnectionStatusQuerier` is a file read with no subprocess, no command runner, and no Elixir expression. Every failure answers unknown and each failing case also asserts it is not connected. The path comes from `WorkerPaths.workerHome/1`, so it cannot drift from the release's.

- [x] Task 4 — Store the configuration and start the runtime without a live node.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Unblock pairing itself, which is the call whose failure makes the app unusable rather than merely uninformative.
  - Owned surfaces: `MacPairingRetention`'s and `PostPairingSetupCoordinatorImpl`'s writing of the worker configuration, and their restart of the release through `WorkerProcessController`.
  - Owns: AC-01
  - Proof: Focused tests cover a completed pairing writing a configuration the release accepts, the file being owner-only with no credential anywhere else, the release being restarted rather than called into, a failed write leaving nothing behind, and the deep-link path storing the same shape it stores today.
  - Delivered: Both pairing paths write `worker.json` themselves through one `WorkerConfigurationStore`, then restart the release through a `WorkerRuntimeRestarting` seam instead of calling into it. `MacPairingRetention` now runs no command at all. Both RPC expression builders are deleted.

- [x] Task 5 — Stop the release by signal, and prove nothing needs distribution.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 3, Task 4
  - Purpose: Close the last call and establish that the app as a whole no longer depends on a service a managed machine can refuse.
  - Owned surfaces: `WorkerProcessController`'s stop path, the check that no app-to-release call uses the release's `rpc` command, and the end-to-end scenario that establishes `capability:distribution-free-worker-control`.
  - Owns: AC-03, AC-05
  - Proof: Focused tests cover the release stopping without a remote call, a run in progress still being noticed before the stop, and an assertion across the app's sources that no call site invokes the release's `rpc` command.
  - Delivered: `stop` is now SIGTERM, then SIGKILL, with `timeout` as the whole budget. SIGTERM is the graceful step the BEAM already handles, so removing the rpc call changed the mechanism rather than only the transport. A guard walks both targets' sources and fails if any call site passes `rpc` to the release; it was proved to fail by mutation and to fail loudly if it cannot find the sources.

## Verification Gate

- [x] Acceptance criteria pass.
- [x] The worker app's own test suite passes.
- [x] The worker release's own tests pass, including the configuration and connection-status suites.
- [x] Build, formatting, lint, and static checks pass.
- [x] Product proof, run on a machine with Erlang distribution unavailable, because that is the condition this slice exists for: pair the app from the menu bar, watch the menu reach `Connected`, then quit and confirm the release stops. Record the states seen in `progress.md`.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
