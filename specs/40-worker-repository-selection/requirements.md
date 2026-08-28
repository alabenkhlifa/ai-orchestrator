# Worker-Driven Repository Selection

## Status

Draft

## Outcome

A person whose worker app is connected on this Mac can point a project at a repository folder from the dashboard. The dashboard asks the Mac's worker to open its native folder picker, the worker checks the folder and reports only the repository's identity and folder name, and the dashboard finishes the connection. This works for a hosted project's first local-repository connection and for accountless onboarding, against the real worker app and not only the development stand-in. The onboarding screen also tells the truth about the worker and offers a way to pair again.

## Users

- Project owner: a signed-in person who owns a hosted project whose repository is a local Git repository on this Mac. Not assumed to be comfortable with a terminal.
- Accountless person: someone on this Mac who works without an account and keeps project work on the device.
- Local worker: the paired macOS worker app on this Mac, which opens the folder picker and proves the repository without disclosing its path.

## In Scope

- Dashboard-initiated folder selection through the connected Mac worker, for the hosted first connection and machine change (`specs/37-hosted-local-repository-connection/`), for accountless repository selection, and for accountless `Locate repository` (`specs/02-local-project-onboarding/`).
- The worker's own checks on the chosen folder: that it is a Git repository, its portable repository identity, and its folder name. Nothing else about the folder leaves the Mac.
- The dashboard's waiting state while the Mac shows the picker, with cancel, no-answer, and worker-lost outcomes.
- One definition of an available worker, shared by every list that offers a worker and every action that uses one.
- Truthful onboarding states: `Check again` shows only what the control plane knows now, and an unavailable worker can be paired again.

## Out of Scope

- Choosing a target folder for a new empty repository (`specs/16-empty-repository-initialization/`). That folder is empty, not a repository, so its check differs. It is deferred to its own follow-on that reuses this slice's picker request.
- Pairing, the Mac-scoped attachment, and worker liveness stamping, owned by `specs/38-worker-initiated-pairing/` and `specs/39-mac-scoped-worker-connection/`.
- What a connected project then runs, owned by `specs/33-local-worker-run-execution/`.
- Unpairing or revoking an old worker record. Pairing again keeps the old record, as `specs/38-worker-initiated-pairing/` already does.
- Removing the development stand-in. It stays for the browser suite under `E2E_MODE` and is off for a plain development server.
- Windows and Linux workers.

## Primary Workflow

1. The owner opens a hosted local-repository project that is not connected, chooses to connect this Mac, and picks the machine when more than one is available.
2. The dashboard shows that the worker app on that Mac should now be showing a folder picker, and offers to cancel.
3. The worker app brings its native folder picker to the front on that Mac.
4. The person picks a folder. The worker checks that it is a Git repository, computes its portable identity, and sends back only that identity and the folder's name.
5. The dashboard completes the flow that asked: the hosted project proves the exact match and becomes connected; accountless onboarding checks for a duplicate, suggests the folder name as the project name, and continues to the storage step.
6. If the person cancels in the picker or in the dashboard, nothing is stored and the dashboard returns to the offer.
7. If the folder is not a Git repository, the dashboard says so and asks for a different folder. Nothing is stored.
8. If the worker gives no answer in the wait window, or disconnects while the picker is open, the dashboard says the worker did not answer and offers to try again. Nothing is stored.

## Business Rules

- Only a worker attached to the control plane right now can be asked to open a picker. Every list that offers a worker and every action that uses one apply this one test. A worker that was seen recently but is not attached now is not offered and is refused with the same wording.
- The folder's path, remote URL, Git history, file names, and content never leave the Mac. The worker reports only the portable repository identity and the folder name, meaning the last path segment. The dashboard may show and suggest the folder name and never a path.
- A selection request belongs to one requesting session, one workspace or project, and one worker. The worker answers only the request it was given. An answer for another request, workspace, or worker is refused and changes nothing.
- One selection request is open per requesting session at a time. A late answer to a request that was cancelled or timed out is ignored.
- Nothing is stored until the dashboard's own validation succeeds. The hosted exact-match rule and the accountless duplicate and naming rules stay exactly as their specifications already state.
- Selection never changes repository content, branches, remotes, or Git configuration.
- `Check again` reports only the state the control plane knows at that moment. The `Code accepted` state appears only after a code was accepted in the current session.
- An unavailable worker state offers to pair again. Pairing again follows the normal pairing flow and authorizes another worker for the same workspace. The old record is kept.
- Copy never claims to see the Mac. The dashboard says what it asked the worker to do and what it heard back.

## Acceptance Criteria

- [AC-01] Given a hosted local-repository project with no connected machine and a worker attached on this Mac, when the owner connects this Mac and picks the exact repository in the worker's folder picker, then the project becomes connected and its page shows it, with the stand-in off.
- [AC-02] Given accountless onboarding on a Mac with an attached worker, when the person chooses the repository through the worker's folder picker, then the folder name is suggested as the project name, no path is shown or stored, and the flow continues to the storage step. The same selection serves `Locate repository` for a moved repository.
- [AC-03] Given a picker is open, when the person cancels in the picker or in the dashboard, then nothing is stored and the dashboard returns to the connection offer.
- [AC-04] Given a picker is open, when the person picks a folder that is not a Git repository, then the dashboard says so and asks for a different folder, and nothing is stored.
- [AC-05] Given a worker that was paired but is not attached now, when a dashboard lists workers or asks one to open a picker, then that worker is not offered and the action is refused with one actionable wording.
- [AC-06] Given a picker request with no answer inside the wait window, or a worker that disconnects while the picker is open, when the window ends or the loss is detected, then the dashboard says the worker did not answer, offers to try again, and nothing is stored.
- [AC-07] Given an open request, when an answer arrives for a different request, workspace, or worker, or after the request was cancelled or timed out, then it is refused or ignored and changes nothing.
- [AC-08] Given a completed selection, when the transported payload and the logs on both sides are inspected, then they carry the repository identity and folder name only and no path, remote, history, file name, or content.
- [AC-09] Given an unavailable worker on the onboarding screen, when the person presses `Check again`, then the screen shows the state the control plane knows now and never `Code accepted` unless a code was accepted in this session.
- [AC-10] Given an unavailable worker on the onboarding screen, when the person chooses to pair again and completes pairing, then a new worker is authorized for the workspace, the old record is kept, and the screen reports the new worker's state.

## Open Questions

- None.
