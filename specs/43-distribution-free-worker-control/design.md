# Distribution-Free Worker Control Design

## Context

The menu-bar app drives its embedded release through the release's own start script. Two of those calls use `eval`, which boots a short-lived VM and needs nothing running. Five use `rpc`, which reaches the already-booted node:

- `MacPairingRetention` stores the configuration and starts `Worker.Supervisor`.
- `PostPairingSetupCoordinatorImpl` does the same for the deep-link path.
- `ConnectionStatusQuerier` reads `Worker.ConnectionStatus.status/0`.
- `RunStateQuerier` reads `Worker.RunState.load/1`.
- `WorkerProcessController.stop` calls `System.stop()`.

`rpc` is Erlang distribution. It needs `epmd` registered and the node listening on a socket the connecting VM can reach. On a managed Mac the firewall carries an `epmd` block-incoming rule that the person cannot change, so every one of those five calls fails and the app is unusable: the configuration is never stored, so pairing cannot finish at all.

This was found on a real managed machine, not predicted. Two fresh unrelated Erlang nodes with a matching cookie answer `pang` there, which is what distinguished a machine-level condition from a defect in this app.

The two calls that already use `eval` are the shape to copy: the app and the release are a parent and its own child on one machine, and nothing they exchange needs a network.

## Proposed Approach

Remove the need for a live node from each of the five calls, choosing the cheapest mechanism that is honest for what that call actually does.

- **Reads of durable state** need no running node at all. `RunState.load/1` reads a file, so its query moves to `eval`, exactly like the pairing check already does.
- **Reads of live in-memory state** cannot move to `eval`, because a fresh VM has no memory of the running one. `ConnectionStatus` is `:persistent_term`, so the release publishes each transition to a small file beside its configuration and the app reads that file directly, with no subprocess at all.
- **Storing the configuration** is a file write the app can perform itself. It already builds the exact JSON the release reads.
- **Starting the runtime** is what genuinely needs the running node today. Instead the app restarts the release process it already owns and supervises; the release loads its configuration at boot, so a restart is the start.
- **Stopping** is a signal to a child process, not a remote call.

Every mechanism above is a file or a process operation between a parent and its own child.

## Components Affected

- `RunStateQuerier`, `ConnectionStatusQuerier`, `MacPairingRetention`, `PostPairingSetupCoordinatorImpl`, and `WorkerProcessController` in the worker app.
- `SddOrchestrator.Worker.ConnectionStatus`, which gains the publishing side of the status file.
- The worker's storage root, which gains one more owner-only file.

## Data and Access Boundaries

- `RuntimeStatusFile`: the release's own report of its last-known connection state, written beside the worker configuration under the worker's storage root. Holds the state, the reason the release already records for it, and when it changed. It holds no credential, no worker identity, no repository path, and nothing about a run. It is rewritten on every transition and is meaningless once the release stops.

Required boundaries:

- Owner-only, like the configuration beside it. It describes a machine's own worker to that machine's own user and is never uploaded, logged, or sent to the control plane.
- Only the release writes it and only the app reads it. Neither treats it as authoritative for anything but display: the control plane remains the only source of truth for whether a worker is attached.
- A missing, unreadable, or unparseable file reads as unknown. It never reads as connected, because a stale claim of health is worse than admitting ignorance.
- The credential stays only in the configuration file, which this slice does not touch.

## Interfaces

- The release's start script keeps its `start`, `eval`, and `rpc` commands. This slice stops using `rpc`; it does not remove it.
- `ConnectionStatus.status/0` keeps its current shape and callers. The file is written alongside, so the in-process reader and the out-of-process reader agree.
- Nothing in the worker protocol, the gateway connection, or the control plane changes.

## Decisions and Tradeoffs

### The status file is written by the release, not inferred by the app

- Choice: the release writes each connection transition to a file; the app reads it and never guesses.
- Reason: the app cannot see inside the release, and inferring a state from the process being alive would report connected for a worker the control plane has refused. That is the exact confusion `specs/39-mac-scoped-worker-connection` exists to remove, and it must not come back through a new door.
- Consequence: one more file on disk, and a state that can be one write stale. The staleness is bounded by the transition that caused it, which is the same bound the current polling already has.

### Absence reads as unknown

- Choice: a missing or unreadable status file answers unknown.
- Reason: the release may not have started, may have crashed, or may be mid-write. All three mean the app does not know, and unknown is the state the menu already handles.
- Consequence: a person sees `Connecting…` briefly on first launch rather than a stale answer, which is what happens today.

### The app writes the configuration itself

- Choice: the app writes the worker configuration file directly instead of asking the release to write it.
- Reason: it already builds that exact JSON, and a file write does not need another process. Asking a running node to write a file on the same disk was always indirection; here it is indirection that fails.
- Consequence: the file's shape becomes something two codebases write instead of one. The release stays the only reader and keeps validating what it loads, so a malformed write is refused where it always was.

### Starting the runtime becomes a restart of a process the app already owns

- Choice: after storing the configuration the app restarts the embedded release rather than calling into it.
- Reason: the release loads its configuration at boot, so a restart starts the worker with it. The app already starts, supervises, and stops that process, so this uses a relationship that exists rather than adding one.
- Consequence: pairing costs one process restart, a second or two, during a step that already waits on the network. It also removes the idempotency question the current call answers with `already_started`, because a fresh boot has nothing started yet.

### `rpc` is left in the release rather than removed

- Choice: stop calling it; do not remove the capability.
- Reason: it is the release's own start script, it is useful for debugging on an unmanaged machine, and removing it is a change to a shared artifact this slice has no need to make.
- Consequence: nothing stops a future call site from reintroducing the dependency. The end-to-end task's check is what guards against that.

## Risks

- A restart during pairing could leave the worker down if the new boot fails. Reduced by storing the configuration before restarting, so a failed boot is retried by the next launch against a configuration that is already on disk; detected by the menu staying on its setting-up line rather than claiming connected.
- Two writers of the configuration file could drift apart in shape. Reduced by keeping the release the only reader and keeping its validation unchanged; detected by the existing configuration tests, which already refuse a file missing a required field.
- A status file could be read mid-write and parse as garbage. Reduced by writing it atomically the way the configuration already is; detected by the unknown fallback, which is the safe answer either way.
- Someone later adds a sixth `rpc` call and reintroduces the problem on managed machines. Reduced by the end-to-end task asserting the absence rather than trusting review.

## Open Questions

- None.
