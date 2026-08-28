# Mac-Scoped Worker Connection

## Status

Approved

## Outcome

A worker paired from the app's menu bar connects for the Mac it runs on, without being given a project first. Every dashboard for that Mac shows it reachable, and the app claims Connected only once the control plane agrees.

## Users

- The person who installed the worker app on the Mac holding their repositories. They paired it by copying a code from the menu bar. They are not expected to open a terminal, know what a project space is, or understand why a worker would need a project before it can connect.
- The project owner reading a dashboard for that Mac. On the accountless path this is the same person in a browser on the same machine.

## In Scope

- Retaining the credential and worker identity that a menu-bar redemption issues, for a worker that has no project.
- A stored worker configuration that is valid with no project.
- Choosing the coding agent for this Mac once, in the app, with auto-detection and manual entry only as a fallback.
- Exchanging that credential for a gateway credential scoped to the Mac's project space rather than to one project.
- Attaching to the control plane for that Mac, and the control plane recording the attachment.
- Deriving worker reachability from the control plane's own record of live attachments, so a real worker stops being reported unavailable while it is running.
- Reporting Connected in the app only after the control plane has attached the worker, and withdrawing that claim when the attachment is refused or lost.

## Out of Scope

- Serving project-scoped run execution through the Mac-scoped attachment. What a connected worker may then do stays owned by `specs/33-local-worker-run-execution/`.
- Letting the dashboard drive the worker's native folder picker so a repository can be chosen. That is the next follow-on and is named in the deferred boundary.
- The `Open in App` deep link and its project-scoped post-pairing setup, which stay exactly as `specs/36-local-worker-native-distribution/` verified them.
- Re-pairing, credential rotation, and unpairing.
- Hosted-project connection and machine selection, owned by `specs/37-hosted-local-repository-connection/`.
- Windows and Linux workers.

## Primary Workflow

1. The person pairs the app from its menu bar and redeems the code in the dashboard, as `specs/38-worker-initiated-pairing/` defines.
2. The app obtains the credential and worker identity that redemption issues, and stores them. It has no project and does not ask for one.
3. The app asks once which coding agent this Mac uses. It auto-detects a supported executable and offers manual entry only when detection finds none.
4. The app exchanges its credential for a gateway credential scoped to this Mac's project space, and attaches to the control plane.
5. The control plane records the attachment. Every dashboard for that Mac shows the worker reachable, without anyone opening a project first.
6. The menu bar shows Connected from that point. If the attachment is refused, it says the control plane refused it. If the attachment drops, it says disconnected.

## Business Rules

- A worker credential authorizes exactly one Mac project space and nothing outside it.
- A stored worker configuration is valid with no project. A project is not a precondition for connecting.
- The coding agent is chosen once for the Mac, not once per project.
- The app must never report Connected on the strength of a transport connection alone. Connected means the control plane has attached this worker and can see it.
- A refused attachment is reported as refused. It is never presented as a connection, and never retried as though it had succeeded.
- Reachability shown in a dashboard is derived from the control plane's own record of live attachments, never from a worker's self-report.
- A worker that stops running stops being reported reachable within the established staleness window, without deleting or hiding any project.
- The credential and the gateway credential are secrets. Neither, nor any fragment of either, is written to a log, crash report, analytics event, or diagnostic on either side.
- Auto-detecting the coding agent reads only whether a supported executable exists at a known location. It does not inventory the machine's software.

## Acceptance Criteria

- [AC-01] Given the dashboard redeemed this app's pairing code, when the app completes pairing, then it stores the issued credential and worker identity and reports no project, without asking the person for one.
- [AC-02] Given a stored configuration that names no project, when it is loaded, then it is valid and the worker runtime starts from it.
- [AC-03] Given the worker is starting for the first time after pairing, when it resolves the coding agent, then it auto-detects a supported executable and offers manual entry only when detection finds none, and the choice is stored for the Mac.
- [AC-04] Given a stored credential and no project, when the worker exchanges it for a gateway credential, then the exchange succeeds and the credential it receives is scoped to the Mac's project space.
- [AC-05] Given a gateway credential scoped to a Mac's project space, when the worker attaches, then the control plane records the attachment against that project space and refuses any attachment aimed at another.
- [AC-06] Given a worker is attached, when any dashboard for that Mac is opened, then it shows the worker reachable, with no project opened first and no worker self-report involved.
- [AC-07] Given the worker's transport has connected but the control plane has not attached it, when the menu bar is read, then it does not say Connected.
- [AC-08] Given the control plane refuses the attachment, when the app reports its state, then it names the refusal and does not present it as a connection.
- [AC-09] Given an attached worker stops running, when the staleness window has passed, then dashboards report it unavailable and every project on that Mac remains visible.
- [AC-10] Given a pairing, an exchange, an attachment, or a refusal has occurred, when the app's and the control plane's diagnostics are inspected, then no credential, gateway credential, or fragment of either appears in any of them.

## Open Questions

- None.
