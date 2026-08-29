# Distribution-Free Worker Control

## Status

Approved

## Outcome

The worker app works on a Mac whose firewall blocks Erlang distribution. Pairing finishes, the menu reports the real connection state, and quitting stops the worker, none of it depending on a network service the machine's owner may not allow.

## Users

- The person who installed the worker app on a Mac they do not administer. Their employer manages the firewall, and they cannot grant a background binary permission to accept incoming connections. They should never have to.

## In Scope

- Every call the app makes into its already-running embedded release.
- The way the release reports state the app needs to read.
- The way the app asks the release to store a configuration, start its runtime, and stop.

## Out of Scope

- The worker's outbound websocket to the control plane. That is ordinary outbound networking, is not affected by this problem, and stays exactly as it is.
- Any change to what the app shows, when it shows it, or what any status line says. Behavior is identical; only the mechanism beneath it changes.
- The embedded release's own supervision tree, run execution, and protocol.
- Anything on the control-plane side.

## Primary Workflow

1. The person installs the worker app on a managed Mac and opens it.
2. They pair it from the menu bar, exactly as they do today.
3. The app stores the configuration and the worker starts running, without asking the operating system for permission to accept a connection.
4. The menu reports connecting, connected, refused, or disconnected as the real state changes.
5. Quitting stops the worker cleanly, and a run in progress is still noticed first.

## Business Rules

- The app and its embedded release run on the same machine as a parent and its own child process. They must communicate as such, never as two networked peers.
- Nothing the app needs from the release may require a name service, a listening socket, or an incoming connection.
- Any state the app reads from the release is written by the release itself. The app never infers a state the release did not report.
- A state file is a report, not a contract with anyone else. It lives beside the worker's own configuration, is readable only by its owner, and holds no credential.
- When the release is not running, every read answers plainly that it is unknown, exactly as an unreachable release does today. Absence is never read as a working state.

## Acceptance Criteria

- [AC-01] Given Erlang distribution is unavailable, when a person pairs the app from the menu bar, then the configuration is stored, the worker runtime starts, and the worker connects.
- [AC-02] Given Erlang distribution is unavailable, when the menu is read, then it shows the same connection state it would show today, including connecting, connected, refused, and disconnected.
- [AC-03] Given Erlang distribution is unavailable, when the person quits the app, then the embedded release stops.
- [AC-04] Given Erlang distribution is unavailable, when the app checks whether a run is active before quitting, then it gets the same answer it gets today.
- [AC-05] Given the app is running normally, when its calls into the release are inspected, then none of them needs a name service, a listening socket, or an incoming connection.

## Open Questions

- None.
