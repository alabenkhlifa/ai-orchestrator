# Worker-Driven Repository Selection Design

## Context

Three dashboard surfaces offer `Open folder picker`, and every one of them is answered by the development stand-in or not at all. `LocalOnboardingLive.select_folder/3` and `RepositoryInitializationLive` gate on `:device_worker_stub` and otherwise answer `Connect the worker to open the folder picker.` `Portability.HostedLocalRepositoryFolder.picker_available?/0` is that same flag. In each case a plain path comes back from a synchronous in-process call and the Git check, the portable identity, and the duplicate match all run on the control-plane node, which is only correct while the control plane and the repository share one machine.

The transport cannot carry the request yet. Control plane to worker is fire-and-forget: `Delivery.CommandTransport.Channel.deliver/1` looks a worker up in the project-keyed registry and the channel pushes a `command`; the worker answers with its own `acknowledge` and `event` pushes, correlated by `command_id`. The envelope types and operations are closed lists. `Worker.GatewayConnection` drops any event it does not know. `specs/39-mac-scoped-worker-connection/` adds a Mac-scoped attachment with its own workspace-keyed registry and deliberately carries no commands over it.

The embedded worker computes no repository identity. `Devices.RepositoryValidation` (which shells out to `git -C`) and `Devices.PortableRepositoryIdentity` (an HMAC over sorted root commits with a random salt) are plain modules inside the same OTP application the worker release ships, so the worker can run them without a database.

The worker app has a native picker (`WorkspaceFolderPicking`, implemented with `NSOpenPanel` on the main thread), but no path from Elixir to Swift exists. `specs/43-distribution-free-worker-control/` removed every `bin/worker rpc` call the app made, because a managed Mac's firewall blocks incoming `epmd` and each one fails there; a guard test fails the app's suite if a source reintroduces one. What replaced them is the shape available here: the release publishes owner-only files under `SddOrchestrator.Worker.Configuration.home/1`, and the app reads them without a socket, a node name, or a cookie.

Availability has two readings today. `WorkerDiscovery.status/2` answers `:detected` from `last_seen_at` within 90 seconds, stamped every 30 seconds from the project-keyed registry. The assessment page lists and authorizes on that reading, so a worker can be listed and then refused inside the same minute when nothing is attached. The onboarding screen shows the pairing form only for `:missing` and `:incompatible`, and its `recheck` sets the waiting state from the status alone, so an unavailable worker turns into `Code accepted` on a click.

## Proposed Approach

Turn folder selection into an asynchronous request the control plane makes of one attached worker, answered by the worker with the repository's identity and folder name and nothing else.

- A `RepositorySelection` context on the control plane owns the request lifecycle. `request/3` takes the requesting scope (a device workspace or a hosted project owner acting through its selected worker), the worker, the identities the worker should compare against, and whether a new identity is wanted. It records an in-memory `SelectionRequest` bound to the requesting process, pushes the request to the worker's Mac-scoped attachment, and answers `{:ok, request_id}`. The answer, a cancellation, a timeout, or the loss of the attachment reaches the requesting process as one `{:repository_selection, request_id, outcome}` message. An answer for an unknown, foreign, cancelled, or expired request is refused before it reaches anyone.
- The request rides the Mac-scoped attachment from `specs/39`, not the project-scoped `worker:` topic, because a worker being asked to pick a repository has, by definition, no project binding yet. The attachment gains `repository_selection` and `repository_selection_cancel` outbound and `repository_selection_result` inbound, with its own small codec. The worker declares a `repository_selection` capability at attach, which means that name is added to `Delivery.WorkerProtocol`'s optional capabilities and to the worker's hardcoded twin, because `negotiate/1` is the only attach-time capability mechanism and it drops any announced name outside its vocabulary. Nothing else in that module changes and `ProtocolCodec` is untouched: run commands and picker requests are different things and stay in different codecs.
- The worker's `Worker.RepositorySelection` holds the one pending request, exposes it to the app, and accepts the app's answer. Once the app hands it a path or a cancellation, it runs the Git check, generates a new identity when asked, matches the folder against every candidate identity it was given, takes the folder name, and sends the result. The path is used inside that process and never written, logged, or sent.
- The app and the release exchange the request through two owner-only files under the worker's storage root, the same way the connection status already crosses that boundary. The release writes `pending_selection.json` while one request is open and removes it when the request ends. The app polls that file every two seconds, shows `NSOpenPanel` on the main thread when one appears, and writes `selection_answer.json` holding the request id and either the chosen path or a cancellation. The release watches for that answer while its request is open, reads it, deletes it at once, and only then runs the Git check. Erlang distribution is not available and a request a person answers in tens of seconds does not justify inventing a third transport shape for the app.
- The three dashboard seams become request-driven. `HostedLocalRepositoryFolder.select/1` stops returning a proof closure over a path and instead requests a selection with the project's identity as the only candidate; the result already says whether it matched. `LocalOnboardingLive` requests a selection with the workspace's project identities as candidates and a new identity wanted, so the duplicate check `Devices.select_repository/2` performs today is answered by the worker's match list. `Locate repository` sends the project's identity. Every seam renders one shared waiting state with cancel, and one shared no-answer state with retry.
- The stand-in survives as an adapter, not a flag inside each LiveView. Under `E2E_MODE` a `RepositorySelection.Stub` answers a request at once from the stub folder and registers a stub attachment, so the browser suite drives the same code path. A plain development server has no stand-in.
- One availability definition. `Devices.worker_available?/1` answers whether the worker is attached now, read from the Mac-scoped registry. `WorkerDiscovery.status/2` derives `:detected` from it, and the assessment list, the assessment authorization, the hosted machine picker, and the selection request all ask it. `last_seen_at` remains for display and for the staleness rule that reports `:unavailable`.
- The onboarding screen tracks whether a code was accepted in this session and shows `Code accepted` only then. The `:unavailable` state gains a `Pair again` action that reveals the same pairing form the `:missing` state shows, including the deep-link code, and pairing again adds a worker as it does today.

## Components Affected

- `SddOrchestrator.RepositorySelection` (new): request lifecycle, correlation, timeout, cancellation, refusal of foreign answers, the `Stub` adapter.
- `SddOrchestratorWeb` Mac-scoped attachment channel from `specs/39`: outbound `repository_selection` push, inbound `repository_selection_result` event, capability negotiation for `repository_selection`.
- `SddOrchestrator.Worker.RepositorySelection` (new) and `Worker.GatewayConnection`: receiving the request, holding it for the app, computing the answer, sending the result.
- `Devices.RepositoryValidation` and `Devices.PortableRepositoryIdentity`: called on the worker; no behavior change.
- Worker app (`native/worker-app`): pending-selection file poll, `NSOpenPanel` presentation, the answer file write, and no retained path.
- `Portability.HostedLocalRepositoryFolder` and `ProjectDashboardLive`: request-driven hosted connection with waiting, cancel, no-answer, and retry states.
- `LocalOnboardingLive`: request-driven selection and locate, folder-name suggestion, truthful `recheck`, `Pair again`.
- `Devices`, `Devices.WorkerDiscovery`, `RepositoryAssessments.authorize_worker/2`, `RepositoryAssessmentLive`, and the hosted machine picker: one availability definition.
- `config/dev.exs` and `config/test.exs`: the stand-in adapter is selected under `E2E_MODE` and in the test environment only.

## Data and Access Boundaries

- `SelectionRequest`: one in-memory record per open request, holding the request id, the requesting process, the requesting device workspace and, for a hosted connection, the project, the worker asked, the candidate identities sent, whether a new identity was wanted, and the expiry time. It is never persisted and disappears on answer, cancellation, expiry, or requester exit.
- `SelectionResult`: the worker's answer, holding the request id, an outcome (`selected`, `cancelled`, `not_a_git_repository`, `empty_repository`, `inaccessible`), the folder name, the list of candidate references that matched, and a newly generated portable identity when one was asked for. It is delivered to the requester and not stored by this slice; the flows that consume it store only what their own specifications already allow.
- `PendingSelectionFile`: the release's report that one request is open and the app should show a panel, written as owner-only JSON under `Configuration.home/1` beside the worker configuration. It holds the request id and its expiry, and nothing else: the candidates and the identities stay in the release's memory, because the app has no use for them. It exists only while the request is open, is removed when the request ends by any route, and is meaningless once the release stops.
- `SelectionAnswerFile`: the app's answer for one request, written as owner-only JSON in the same directory. It holds the request id and either the chosen path or a cancellation. It is the only place a path is ever written, it exists for at most one poll interval, and the release deletes it as soon as it reads it. A stale file left by a release that stopped between the write and the read is deleted unread at the next start, because it can only answer a request that no longer exists.

Required boundaries:

- A request may be made only by the scope that owns the worker: the device workspace the worker is paired to, or a hosted project owner whose selected worker is authorized for their device workspace under `specs/37`. The channel accepts a result only from the attachment the request was pushed to, and `RepositorySelection` delivers it only to the process that made the request.
- Candidate identities are portable repository identities (salt and digest), never paths or names. They are sent only to a worker paired to the requesting workspace. The result carries the folder name (the last path segment) and identities. No path, remote URL, Git history, file name, or content is placed in a request, a result, a log, a diagnostic, or an analytics event on either side.
- The worker uses the path only inside the answering process. The app does not retain the chosen path after answering, and the file it wrote is deleted by the release on read, so no path survives a completed selection.
- Both worker files are owner-only, like the worker configuration and the connection status beside them. They describe one machine's own pending question to that machine's own user. Neither is uploaded, logged, or sent to the control plane, and neither holds a credential, a worker identity, a remote, or anything about a run.
- The dev stand-in exists only under `E2E_MODE` and in the test environment. A production build has no stand-in module configured.

## Interfaces

- Attachment message `repository_selection` (control plane to worker): `request_id`, `candidates` (a list of `ref` plus identity), `generate` (boolean), `expires_at`. Attachment message `repository_selection_cancel` (control plane to worker): `request_id`, so a panel closes when the requester leaves or the window ends. Attachment message `repository_selection_result` (worker to control plane): `request_id`, `outcome`, `folder_name`, `matches` (list of `ref`), `identity` (or absent). A worker declares the `repository_selection` capability on attach; a request to a worker without it is refused with `:worker_needs_update`.
- `RepositorySelection.request/3`, `cancel/1`, and the `{:repository_selection, request_id, outcome}` message to the requester, with outcomes `{:selected, result}`, `:cancelled`, `{:refused, reason}`, `:timeout`, and `:worker_lost`.
- The release's own API behind the files: `Worker.RepositorySelection.pending/0` answers the pending request id or `nil`, and `answer/2` takes the request id and a path or `:cancelled`. The app never calls either directly; the files are the crossing.
- Worker storage files under `Configuration.home/1`, owner-only, beside `connection_status.json`: `pending_selection.json` written by the release while a request is open, holding `request_id` and `expires_at`; `selection_answer.json` written by the app, holding `request_id` and either `path` or a cancellation. The release deletes the answer as soon as it reads it and removes the pending file when the request ends.
- `Devices.worker_available?/1` and the unchanged categories of `WorkerDiscovery.status/2`.
- Compatibility that must hold: the project-scoped `worker:` topic, `Delivery.WorkerProtocol`, `ProtocolCodec`, `deliver/1`, run execution, the hosted connect authority gate `HostedLocalRepositoryConnection.connect/6` and its exact-match rule, and the accountless duplicate and naming rules stay as their specifications verified them. The stand-in keeps the browser suite's existing scenarios passing.

## Decisions and Tradeoffs

### The request rides the Mac-scoped attachment

- Choice: Push the selection request over the workspace-keyed attachment `specs/39` introduces, and add one message pair to it.
- Reason: The worker being asked has no project binding yet; that is the whole reason the person is picking a folder. The project-scoped topic cannot exist before the answer.
- Consequence: Slice 40 extends an attachment slice 39 kept command-free, and is blocked until that attachment exists. `specs/39`'s topic, registry, and authorization are consumed through its capability and not redefined here.

### The worker computes and the control plane only compares references

- Choice: The request carries candidate identities; the worker answers which matched and, when asked, a new identity. The Git check and identity generation run on the worker.
- Reason: The path must never leave the Mac, and the duplicate check and the exact-match proof both need the path. Sending references down and verdicts up keeps every existing rule intact without moving the path.
- Consequence: The worker release now runs `RepositoryValidation` and `PortableRepositoryIdentity`, which shell out to `git`. A Mac without `git` on the worker's path answers `inaccessible`, and that is reported as such.

### The app and the release exchange the request as files

- Choice: Two owner-only JSON files under the worker's storage root, polled at two seconds. The release writes the pending request, the app writes the answer, and the release deletes the answer as soon as it reads it.
- Reason: `bin/worker rpc` is not available. `specs/43-distribution-free-worker-control/` removed every one of the app's rpc calls because a managed Mac's firewall blocks incoming `epmd`, and a guard test fails the app's suite if a call site returns. `eval` is no help either: a pending request lives in the release's memory, so a fresh VM would answer that nothing is pending, which is the same reason the connection status needed a file. Files are the mechanism that slice left behind, between a parent and its own child on one machine.
- Consequence: The chosen path is written to disk for at most one poll interval. That is a real widening of where the path exists, and it is why the deletion on read is an acceptance criterion rather than an implementation detail. A polling cost while a request is open, and a small delay before the panel appears. If a later feature needs the app to react faster, a push channel replaces the poll without changing the request contract.

### One availability definition, read from attachment

- Choice: `Devices.worker_available?/1` answers from the Mac-scoped registry, and every list and action uses it.
- Reason: A list that says `Available` and an action that says `no longer available` inside one minute is a product defect, not two views of the truth.
- Consequence: `:detected` now requires an attachment, so the stand-in must register a stub attachment for the browser suite. `last_seen_at` becomes display and staleness only.

### The stand-in becomes an adapter

- Choice: Replace the per-LiveView `worker_stub?/0` gates with a `RepositorySelection` adapter chosen by configuration, present only under `E2E_MODE` and in tests.
- Reason: Three copies of the same gate hid that the real path never worked. One adapter behind the real contract keeps the browser suite honest and a plain dev server real.
- Consequence: The browser suite's onboarding and hosted-connection scenarios keep passing through the stub adapter, and they remain domain proof; the product proof is a click path with the adapter absent.

### Empty-repository initialization is deferred

- Choice: `RepositoryInitializationLive` keeps its stand-in gate in this slice.
- Reason: It picks a target folder for a repository that does not exist yet, keeps the path for later publish and handoff steps, and needs an eligibility check rather than an identity. That is a different answer shape.
- Consequence: The empty-repository flow still cannot run against a real worker until its follow-on reuses the request with an eligibility outcome.

## Risks

- The Mac-scoped attachment shape is settled during `specs/39` Task 5. Task 2 here is blocked until `capability:mac-scoped-worker-connection` is ready and must consume the registry accessor as delivered, not a guess.
- Running `git` on the worker inside the app may hit a sandbox or PATH difference from the developer's shell. The worker answers `inaccessible` with the reason kept worker-local, and the product proof runs against the real app to catch it.
- A request can outlive its requester (a closed tab). The request is bound to the requesting process and is cancelled on its exit, and the app is told so the panel closes.
- The chosen path is on disk between the app writing it and the release reading it. It is owner-only and deleted on read, and AC-11 proves the deletion, but a release that stops in that window leaves the file behind. The release deletes a stale answer unread at its next start, because it can only name a request that no longer exists.
- The stub adapter could drift from the real contract. It implements the same `RepositorySelection` behaviour and is exercised by the same LiveView code, and the browser suite runs it.

## Open Questions

- None.
