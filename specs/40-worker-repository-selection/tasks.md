# Worker-Driven Repository Selection Tasks

## Status

Verified

## Active Slice

Let a dashboard ask the Mac's attached worker to open its native folder picker and answer with only the repository's identity and folder name, so a hosted project's first local-repository connection and accountless onboarding complete against the real worker app; give every list and action one definition of an available worker; and make the onboarding screen report the worker truthfully and offer to pair again.

## Cross-Specification Dependencies

Requires:

- `capability:mac-scoped-worker-connection` — provider `specs/39-mac-scoped-worker-connection#Task 8` — required before `Task 2`.
- `capability:hosted-local-repository-connection` — provider `specs/37-hosted-local-repository-connection#Task 6` — required before `Task 6`.
- `capability:worker-initiated-pairing` — provider `specs/38-worker-initiated-pairing#Task 8` — required before `Task 8`.
- `capability:distribution-free-worker-control` — provider `specs/43-distribution-free-worker-control#Task 5` — required before `Task 3`.

Provides:

- `capability:worker-repository-selection` — ready after `Task 9`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- The `RepositorySelection` request lifecycle on the control plane: correlation, timeout, cancellation, requester exit, and refusal of foreign answers.
- The `repository_selection` request and `repository_selection_result` messages over the Mac-scoped attachment, with capability negotiation.
- The worker-side pending request, the two owner-only files that carry it between the release and the app, the app's poll and native picker, the app's answer, and the worker's Git check, identity generation, candidate matching, and folder name.
- Request-driven selection in the hosted first connection and machine change, in accountless selection, and in `Locate repository`, with shared waiting, cancel, no-answer, and retry states.
- One availability definition read from the Mac-scoped attachment, used by every worker list and action.
- Truthful `Check again` and a `Pair again` action on the onboarding screen.
- The stand-in as a configured adapter present only under `E2E_MODE` and in tests.

Excluded:

- The Mac-scoped attachment topic, registry, and authorization, owned by `specs/39-mac-scoped-worker-connection/` and consumed here through its capability.
- The project-scoped `worker:` topic, `Delivery.WorkerProtocol`, `ProtocolCodec`, `deliver/1`, and run execution, owned by `specs/33-local-worker-run-execution/`.
- The hosted connect authority gate, exact-match rule, binding replacement, and disconnect, owned by `specs/37-hosted-local-repository-connection/`.
- Pairing issuance and redemption, owned by `specs/38-worker-initiated-pairing/`; revoking or unpairing an old worker.
- Any persistence of a request or a result.

Deferred after this slice:

- Target-folder selection for empty-repository initialization (`specs/16-empty-repository-initialization/`), which reuses the request with an eligibility outcome and keeps the path worker-side for publish and handoff.
- A push channel from the worker release to the app, if two-second polling ever proves too slow.

Release gates:

- Real macOS signing and notarization of a worker app build carrying the picker poll, which needs an Apple signing identity and the notarization service.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Own a selection request from creation to one outcome.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give the dashboard one place that asks a worker for a repository and guarantees exactly one outcome reaches exactly one requester.
  - Owned surfaces: `SddOrchestrator.RepositorySelection` with `request/3`, `cancel/1`, the in-memory request table, the timeout, cancellation on requester exit, delivery of `{:repository_selection, request_id, outcome}`, and refusal of an answer for an unknown, foreign, cancelled, or expired request. The transport push is a behaviour injected by Task 2; this task ships a test transport.
  - Owns: AC-07, entity:SelectionRequest, entity:SelectionResult
  - Proof: Focused tests cover a request answered once and delivered to its requester only, a second answer to the same request being refused, an answer naming another request or worker being refused, a cancelled or expired request ignoring a late answer, and the requester's exit cancelling the request.
  - Delivered: `SddOrchestrator.RepositorySelection` opens a request, pushes it through a configured transport behaviour, and guarantees one `{:repository_selection, request_id, outcome}` message per request. A foreign, repeat, cancelled, or expired answer is refused and changes nothing.

- [x] Task 2 — Carry the request and its result over the Mac-scoped attachment.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let a request reach the one worker attached for a workspace and let only that attachment answer it.
  - Owned surfaces: The `repository_selection` push and `repository_selection_result` inbound event on the Mac-scoped attachment channel, their codec, the `repository_selection` capability declared at attach, refusal of a worker without it as `:worker_needs_update`, refusal of a result from an attachment other than the one pushed to, and the real transport behaviour for Task 1.
  - Owns: AC-08
  - Proof: Focused channel tests cover a request pushed to the attached worker for its workspace, a result accepted only from that attachment, a result from another attachment refused, a worker without the capability refused, and the pushed and received payloads holding identities and a folder name only.
  - Delivered: `RepositorySelection.Transport.Attachment` pushes a request to the named worker attached for its workspace, and the Mac-scoped channel answers with `repository_selection_result` credited to its own authenticated socket. `AttachmentCodec` closes both directions to their allowed fields.

- [x] Task 3 — Answer a request on the worker with identity and folder name only.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Do every path-dependent computation on the Mac so the path never has to leave it.
  - Owned surfaces: `SddOrchestrator.Worker.RepositorySelection` with `pending/0` and `answer/2`, `Worker.GatewayConnection` handling of the inbound request and outbound result, the `pending_selection.json` and `selection_answer.json` file contract under `Configuration.home/1` including their owner-only mode, the deletion of the answer on read and of a stale answer at start, the removal of the pending file when the request ends, the Git check through `Devices.RepositoryValidation`, generation through `Devices.PortableRepositoryIdentity`, candidate matching, the folder name, and the exclusion of the path from every log line on the worker.
  - Owns: AC-04, AC-11, entity:PendingSelectionFile, entity:SelectionAnswerFile
  - Proof: Focused tests cover a pending request published to its file and removed when the request ends, an answered path yielding matches and a new identity, the answer file being gone after the answer is read, a stale answer deleted unread at start, a non-repository folder answering `not_a_git_repository`, an inaccessible folder answering `inaccessible`, a cancellation answering `cancelled`, and a captured log holding no path.
  - Delivered: `Worker.RepositorySelection` holds one request, publishes it to `pending_selection.json`, and answers from `selection_answer.json` after deleting it. The Git check, matching, and identity all run on the Mac, and no path enters state, a payload, or a log line.

- [x] Task 4 — Show the native picker from the app and hand the answer back.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Close the reverse hop the app never had, without Erlang distribution.
  - Owned surfaces: The app's poll of `pending_selection.json` at a two-second interval while attached, `NSOpenPanel` presentation on the main thread through `WorkspaceFolderPicking`, writing `selection_answer.json` with the path or a cancellation, closing the panel when the pending file disappears, and not retaining the path after writing it.
  - Owns: none
  - Proof: Focused Swift tests with the fake picker and a fake file store cover a pending file producing one panel, a chosen folder producing one answer file holding the path, a dismissed panel producing one cancellation answer, the pending file disappearing closing the panel without an answer, no second panel while one is open, and no source invoking the release's `rpc` command.
  - Delivered: The app polls `pending_selection.json` every two seconds, shows one `NSOpenPanel` per request, and writes `selection_answer.json`. It withholds the answer when the request is gone, so no orphan file holds a path.

- [x] Task 5 — Give every list and action one definition of an available worker.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Stop a worker from being offered and then refused inside one minute.
  - Owned surfaces: `Devices.worker_available?/1` read from the Mac-scoped registry, `Devices.WorkerDiscovery.status/2` deriving `:detected` from it, `RepositoryAssessments.authorize_worker/2`, `RepositoryAssessmentLive`'s worker list, the hosted machine picker from `specs/37`, and the stand-in's stub attachment registration under `E2E_MODE` and in tests.
  - Owns: AC-05
  - Proof: Focused tests cover a paired worker with a fresh `last_seen_at` and no attachment being neither listed nor authorized, an attached worker being both, the same refusal wording from the list and the action, `WorkerDiscovery` answering `:unavailable` for the first case, and the stub attachment making the test worker `:detected`.
  - Delivered: `Devices.worker_available?/1` reads the Mac-scoped registry and is the one definition. `WorkerDiscovery.status/2` derives `:detected` from it, so the assessment list and `authorize_worker/2` read one answer and share one refusal wording.

- [x] Task 6 — Connect a hosted project through the worker's picker.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 5
  - Purpose: Make the first hosted local-repository connection work without the stand-in.
  - Owned surfaces: `Portability.HostedLocalRepositoryFolder` requesting a selection with the project's identity as the only candidate and answering the connect gate from the result, `ProjectDashboardLive`'s waiting state with cancel, the no-answer and worker-lost states with retry, the `RepositorySelection.Stub` adapter and its configuration under `E2E_MODE` and in tests, and removal of `picker_available?/0`.
  - Owns: AC-01, AC-03, AC-06
  - Proof: Focused LiveView tests with the test transport cover a matched result connecting the project, a cancelled result storing nothing and returning to the offer, a timeout and a lost worker each showing the retry state with nothing stored, and the stub adapter connecting the browser suite's seeded project as before.
  - Delivered: `HostedLocalRepositoryFolder.request/3` asks the worker with the project's identity as the only candidate, and `proof/2` answers the connect gate from the worker's verdict for that identity only. `ProjectDashboardLive` waits, cancels, and retries. The stand-in is now the `RepositorySelection.Stub` transport.

- [x] Task 10 — Compare a legacy identity on the worker as the control plane would.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Keep the duplicate and locate rules exactly as they are for a workspace whose projects still carry legacy identities.
  - Owned surfaces: Candidate comparison in `Worker.RepositorySelection` and in `RepositorySelection.Stub` dispatching on the identity's own format, portable through `PortableRepositoryIdentity.match/2` and legacy through `match_legacy/3` against the worker's configured device workspace id, matching `Devices.matches_repository?/3`.
  - Owns: none
  - Proof: Focused tests cover a legacy candidate matching its own repository on the worker, the same legacy candidate not matching a different repository, a legacy candidate salted for another workspace not matching, a portable candidate still matching as before, and the stand-in giving the same answers as the worker.
  - Delivered: The worker and the stand-in dispatch on the identity's own format, so a legacy candidate is compared against the workspace salt exactly as `Devices.matches_repository?/3` compares it. The worker reads that salt from its own paired configuration.

- [x] Task 7 — Select and locate an accountless repository through the worker's picker.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 6, Task 10
  - Purpose: Let the accountless path choose a repository against the real app and reuse the states Task 6 built.
  - Owned surfaces: `LocalOnboardingLive`'s `select_folder` and locate mode requesting a selection with the workspace's project identities as candidates, the duplicate outcome from the worker's match list, the folder name as the suggested project name with no location shown, and reuse of the shared waiting, cancel, no-answer, and retry states; removal of the LiveView's own `worker_stub?/0` gate.
  - Owns: AC-02
  - Proof: Focused LiveView tests with the test transport cover a new repository suggesting its folder name and continuing to the storage step, a matched existing project being reported as the duplicate with its link, locate mode reconnecting a moved repository on a match and refusing a different one, and no path in any assign or render.
  - Delivered: Accountless selection and `Locate repository` both ask the worker. The duplicate outcome is the worker's match list, the folder name is the suggested project name, and no path reaches the screen. A legacy project still upgrades, because the other projects ride along as candidates and the worker generates the replacement.

- [x] Task 8 — Report the worker truthfully and offer to pair again.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Remove the two screens that told the person something the control plane did not know.
  - Owned surfaces: `LocalOnboardingLive`'s session flag for an accepted code, `recheck` deriving the waiting state from that flag, the `Pair again` action on the `:unavailable` state revealing the pairing form and deep-link code, and the result of pairing again being shown as the new worker's state.
  - Owns: AC-09, AC-10
  - Proof: Focused LiveView tests cover `Check again` on an unavailable worker staying in the unavailable state, `Code accepted` appearing only after a code is accepted in the session, `Pair again` revealing the form, and a completed re-pairing adding a worker while the old row stays.
  - Delivered: `Check again` reports only what the control plane knows, because the waiting panel now derives from a code accepted in this session rather than from the status. An unavailable worker offers `Pair again`, which reveals the same pairing form and deep link.

- [x] Task 9 — Prove the round trip against the real app and that no path leaks.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4, Task 7, Task 8
  - Purpose: Show the two halves meet and establish `capability:worker-repository-selection`.
  - Owned surfaces: The integration scenario from a selection request through the worker's answer to a connected hosted project and a created accountless project, which establishes `capability:worker-repository-selection`, and the log and diagnostic review on both sides for a path, remote, history, file name, or content.
  - Owns: none
  - Proof: An integration scenario drives a request through a fake app answer to a connected hosted project and to an accountless project with the suggested name, then a log and diagnostic review across the control plane and the worker finds only identities and a folder name.
  - Delivered: An end-to-end scenario drives a real attached worker over a real websocket, answers with the file the Mac app would write, and asserts the leak review as assertions over captured logs and traced channel frames. `capability:worker-repository-selection` is established.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Project-scoped attachment, delivery, and run execution tests pass unchanged.
- [x] The hosted exact-match, binding replacement, and disconnect tests pass unchanged.
- [x] Availability, waiting, cancel, timeout, and worker-lost transitions pass.
- [x] The log, diagnostic, and no-analytics review finds no path, remote, history, file name, or content, and no answer file survives a completed selection.
- [x] Build, formatting, lint, static checks, and logs review pass.
- [x] Required browser scenarios pass through the stub adapter under `E2E_MODE`.
- [x] The worker app's own test suite passes.
- [x] Product proof, accountless half: one click path from `/` in a real browser, worker stand-in off, no `/_e2e` seeding, against the paired worker app, creating a project from the worker's own folder picker. Recorded in `progress.md`.
- [x] Product proof, hosted half: accepted exception. No screen creates a hosted local-repository project in this build, so the path cannot be clicked. See the exception below.

## Blocked Decisions

- None.

## Accepted Exceptions

- The hosted half of the Product Proof Gate is accepted as unproven by clicking, agreed with the user on 2026-08-31. A hosted local-repository project has no creation path in this build: the accountless flow answers "Saving local projects to a hosted account is coming soon", GitHub sign-in creates `github`-provider projects, and the only such project in the repository comes from `/_e2e` seeding, which this gate forbids. The selection code the hosted seam runs is the code the accountless click path proved against the real worker app, and the hosted seam additionally holds domain tests and a passing browser scenario through the stub adapter. What stays unproven by a click is the upstream project-creation path, owned by the hosted-storage slice that message names.

## Release Gate

- [ ] Real macOS signing and notarization of a worker app build carrying the picker poll, on supported macOS hosts.

## Progress Log

See [progress.md](progress.md).
