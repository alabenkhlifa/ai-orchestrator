# Mac-Scoped Worker Connection Tasks

## Status

Verified

All nine tasks are complete and the verification gate passes, including the recovery product-proof click path against the installed Mac app. `capability:mac-scoped-worker-connection` stays ready.

## Active Slice

Let a worker paired from the app's menu bar reach a genuinely connected state: it keeps the credential that redemption issued, stores a configuration that names no project, is set up once with this Mac's coding agent, exchanges its credential for a Mac-scoped gateway credential, attaches to the control plane for its own project space, and is reported reachable by every dashboard for that Mac while the app claims Connected only once the control plane agrees.

## Cross-Specification Dependencies

Requires:

- `capability:worker-initiated-pairing` — provider `specs/38-worker-initiated-pairing#Task 8` — required before `Task 2`.
- `capability:signed-macos-worker-distribution` — provider `specs/36-local-worker-native-distribution#Task 12` — required before `Task 3`.

Provides:

- `capability:mac-scoped-worker-connection` — ready after `Task 8`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- A worker configuration that is valid with no project, and its stored coding-agent choice.
- Retention of the credential and worker identity a menu-bar redemption issues.
- The app's one-time coding-agent setup for the Mac.
- A gateway credential exchange that accepts a request naming no project and answers a credential scoped to the worker's device workspace.
- A Mac-scoped attachment topic, its authorization check, and its registry.
- Worker liveness derived from Mac-scoped attachments.
- The app's connection state driven by attachment rather than by the transport callback, including the refused and lost cases.
- Recovery of the Mac-scoped connection after the control plane is unreachable, and truthful reporting while it is.
- Exclusion of both credentials from every log and diagnostic on both sides.

Excluded:

- The project-scoped `worker:` topic, the project-keyed registry, and `deliver/1`, whose behavior and contract stay exactly as `specs/33-local-worker-run-execution/` and `specs/36-local-worker-native-distribution/` verified them.
- The `Open in App` deep link and its project-scoped post-pairing setup.
- What a connected worker may then execute, owned by `specs/33-local-worker-run-execution/`.
- Hosted-project machine selection and binding, owned by `specs/37-hosted-local-repository-connection/`.
- Re-pairing, credential rotation, and unpairing.

Deferred after this slice:

- Letting the dashboard drive a connected worker's native folder picker, so a project can select a repository without a project-scoped re-pairing. Today `LocalOnboardingLive`'s production path answers `Connect the worker to open the folder picker` and only the development stand-in completes selection, so the accountless path cannot finish against a real worker. This slice makes the worker reachable, which that follow-on requires, and does not itself close it.
- Serving project-scoped run execution through a Mac-scoped attachment, if the two attachments are later shown to be worth collapsing.
- Choosing a different coding agent per project, if evidence ever shows people want one.

Release gates:

- The accountable privacy review of storing a credential for a worker that has no project, including its retention and revocation path, on the same basis `specs/02-local-project-onboarding/` already records for pairing credentials.
- Real macOS signing and notarization of a build carrying this setup step, which needs an Apple signing identity and the notarization service.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Make the stored worker configuration valid with no project.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Remove the precondition that stops an app-paired worker from having anything to store, without weakening what a project-scoped configuration still guarantees.
  - Owned surfaces: `Worker.Configuration`'s required fields, its load and store paths, its optional project, and the migration of an existing stored configuration that names one.
  - Owns: AC-02, entity:WorkerConfiguration
  - Proof: Focused tests cover a configuration with no project loading and validating, a configuration naming a project continuing to load unchanged, an existing stored file surviving the change, and the worker runtime starting from the projectless shape.
  - Delivered: `Worker.Configuration` now derives `@enforce_keys` and `from_map/1`'s decode check from one `@required_keys` list, so the write and read paths cannot disagree about what is required. `project_id` and `workspace_root` default to `nil`; `from_pairing/2` reads them with `Map.get/2` while every still-required field keeps `Map.fetch!/2`. An absent project or repository folder is written as an absent key rather than a `null`, and absent, `null`, and blank all decode to `nil`, so a file written in the old shape keeps its values. `Worker.Supervisor` deletes `:worker_workspace_root` rather than setting it to `nil`, so a root left by an earlier configuration cannot point a projectless worker's runs at a folder it was never given, and it starts `[State]` alone for a projectless configuration while a configuration with a project starts the same children in the same order as before. `GatewayConnection` was not modified: not starting it is sufficient, so none of its connection-state code was touched.

- [x] Task 2 — Retain the credential and worker identity a redemption issues.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Keep the credential `specs/38-worker-initiated-pairing/` deliberately discarded, now that a configuration exists that can hold it.
  - Owned surfaces: The app's post-redemption completion path, its storage of the issued credential and worker identity, and its state transition out of the handed-off-to-dashboard state.
  - Owns: AC-01
  - Proof: Focused tests cover a completed redemption storing the credential and worker identity with no project, the app no longer reporting that the dashboard has taken over once it holds one, a failed completion storing nothing, and the person never being asked for a project.
  - Delivered: A redeemed pairing code now writes the credential and worker identity into the release's own `worker.json` through `MacPairingRetention`, and the app reports `Paired, setting up…` instead of sending the person to the dashboard. `WorkerStatus.handedOffToDashboard` is deleted, because the reason specs/38 added it is the reason Task 1 removed. The coding agent is the one required field this task cannot produce, so it arrives through the `MacCodingAgentResolving` seam that Task 3 implements.

- [x] Task 3 — Set up this Mac's coding agent once.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Resolve the one machine-level thing the worker needs before it can be useful, without asking for a repository this slice does not deliver.
  - Owned surfaces: The app's coding-agent setup step, its auto-detection of a supported executable, its manual-entry fallback, and the stored choice.
  - Owns: AC-03
  - Proof: Focused tests cover auto-detection resolving a supported executable, manual entry offered only when detection finds none, the choice being stored for the Mac, and the step not asking for a repository folder.
  - Delivered: `MacCodingAgentSetup` fills the resolver seam Task 2 left. It auto-detects, reaches the prompt's manual entry only when detection finds none, and answers once per Mac by remembering the first resolved agent. The answer lands in this Mac's one `worker.json` through `MacPairingRetention`, and the step holds no folder picker and takes no project.

- [x] Task 4 — Issue a gateway credential scoped to the Mac's project space.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let a worker with no project obtain the credential it needs to attach, without widening what a project-scoped credential authorizes.
  - Owned surfaces: The gateway credential exchange endpoint, its acceptance of a request naming no project, the device-workspace scope of the credential it answers, and its refusal of a credential that does not authorize the requested space.
  - Owns: AC-04
  - Proof: Focused tests cover an exchange with no project answering a workspace-scoped credential, the existing project-scoped request answering exactly what it answers today, a credential for another workspace being refused, and no credential reaching a log.
  - Delivered: `WorkerSocket` now signs two claim shapes under one salt and one bounded lifetime: `%{project_id, worker_id}` unchanged, and `%{device_workspace_id, worker_id}` for a worker with no project. `issue/3` takes a bare project id or `{:device_workspace, id}`, so a caller names the scope rather than producing one shape while meaning the other. `verify/1` has one clause per shape, each guarded by `map_size(claims) == 2`, so a claim carrying both keys matches neither and no token can be read under a scope it was not signed for. The controller keeps its project clause byte-identical and adds a clause guarded on the absence of `project_id`, which authenticates the credential and issues against the worker's own `device_workspace_id` with no binding lookup; every failure still answers one uniform `403 refused`. A malformed `project_id` does not fall through to the projectless exchange, because answering a question about a project with a different scope would be a silent substitution. `connect/3` was narrowed to match the project claim explicitly and refuse anything else: it previously read `claims.project_id` unconditionally, which a workspace-scoped token would have turned into a `KeyError` crash logging the claim map instead of a refusal. Its workspace-scoped connect path is left to `Task 5`. No change was needed to guard artifact upload: `Delivery.ArtifactUpload.accept/3` matches `%{project_id: ...}` and answers `{:error, :unauthorized_worker}` for every other claim.

- [x] Task 5 — Attach a worker for its Mac and record the attachment.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Give the control plane its own record that this machine's worker is live, which every dashboard question already assumes exists.
  - Owned surfaces: The Mac-scoped attachment topic, its authorization against the credential's device workspace, the workspace-keyed attachment registry, and its accessor.
  - Owns: AC-05, entity:WorkerAttachment
  - Proof: Focused tests cover a valid attachment being registered against its own workspace, an attachment aimed at another workspace being refused before negotiation, a reconnect overlapping its predecessor without stranding the worker, the entry disappearing when the channel process dies, and the project-keyed registry and its delivery path behaving exactly as before.
  - Delivered: A worker with a workspace-scoped credential now opens a socket carrying no project and joins the `worker_workspace:` topic named for the device workspace, which checks the topic against the credential before negotiating anything and registers the live channel process in the duplicate-keyed `WorkspaceWorkerRegistry`. `Delivery.WorkerAttachment` owns that registry and its accessor and delivers nothing. The project-keyed registry, `deliver/1`, and the `worker:` topic are untouched.

- [x] Task 6 — Derive worker liveness from Mac-scoped attachments.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Stop a genuinely running worker from being reported unavailable forever because it has joined no project.
  - Owned surfaces: `Devices.WorkerLivenessRefresher`'s enumeration of the workspace-keyed registry alongside the project-keyed one, and its handling of a worker present in both.
  - Owns: AC-06, AC-09
  - Proof: Focused tests cover one refresher pass stamping a worker attached only for its Mac, a worker attached for both being stamped once, a revoked or deleted row being skipped without failing the pass, `WorkerDiscovery.status/2` moving to detected across a pass with no worker-initiated call, and reverting to unavailable once the staleness window passes with the attachment gone.
  - Delivered: `attached_worker_ids/0` now unions both registries through one shared selection helper, so a worker attached only for its Mac is stamped and a worker attached for both is stamped once. The reachability policy and the staleness window are unchanged: only the source that stamps `last_seen_at` widened. AC-09's user-visible half is carried to the slice's browser proof.

- [x] Task 7 — Report Connected only once the control plane has attached the worker.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Close the contradiction where the menu bar says Connected on a socket the control plane never accepted.
  - Owned surfaces: `GatewayConnection`'s connection-state reporting, its move off the transport callback onto a successful attachment, its refused-attachment state, its lost-attachment state, and the menu-bar status derived from them.
  - Owns: AC-07, AC-08
  - Proof: Focused tests cover a connected transport with no attachment not reading as Connected, a successful attachment reading as Connected, a refused attachment naming the refusal rather than a connection, a lost attachment reading as disconnected, and the refusal not being retried as though it had succeeded.
  - Delivered: `handle_join/3` is now the only place that reports `:connected`. The transport callback reports `:connecting`, a refused join reports `:refused` and is still never retried, and a topic close that loses an attachment reports `:disconnected`. `establish/2` also dials the Mac-scoped scope for a projectless configuration, omitting `project_id` from the credential request so the workspace exchange accepts it. The menu bar gains `Paired, but the control plane refused the connection`.

- [x] Task 8 — Prove the round trip and that neither credential leaks.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 3, Task 6, Task 7
  - Purpose: Show the two halves meet: a code copied from the menu bar and redeemed in the dashboard ends with a worker every dashboard for that Mac reports reachable, and nothing secret is left behind.
  - Owned surfaces: The end-to-end scenario across redemption, retention, setup, exchange, attachment, and reachability that establishes `capability:mac-scoped-worker-connection`, and the diagnostic exclusion of both credentials across the app and the control plane.
  - Owns: AC-10
  - Proof: An integration scenario drives a menu-bar redemption through to a worker reported reachable by the device-workspace status function with no project opened, then a log and diagnostic review across both sides finds no credential, gateway credential, or fragment of either.
  - Delivered: One integration scenario drives redemption, a projectless configuration, the exchange, the Mac-scoped attachment, and one liveness pass through to `Devices.worker_status/1` answering `:detected`, with no project created and `Pairing.mark_seen/1` never called. A second scenario repeats the leak review for a refused join. Both capture at `:debug` and scan a sliding window over each secret, and the review asserts the diagnostics it scans are genuinely present.

- [x] Task 9 — Keep the Mac-scoped connection trying, and stop it reporting a connection nobody holds.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8
  - Purpose: A control plane that goes away for more than a few seconds currently ends the worker's only link for good, and leaves the last `connected` report behind, so the person sees a worker that says it is fine and is not there.
  - Owned surfaces: `Worker.GatewayConnection#handle_continue(:connect_gateway, socket)`'s scope-conditional branch that retries only a transport-level credential-exchange failure for the device-workspace scope, the new retry message and its widening, repeating delay list, and `ConnectionStatus.set_disconnected/1` written before each retry so the report stays truthful while it runs. `handle_disconnect/2`'s existing Slipstream-native reconnect, the project scope's unconditional stop, and `ProjectConnections`' own temporary children are unchanged.
  - Owns: AC-11, AC-12
  - Proof: Focused worker tests prove a transport-level credential-exchange failure for the device-workspace scope retries with a widening, repeating delay instead of stopping the process, that `ConnectionStatus` reports disconnected (never connected) throughout, that a genuine credential refusal still stops the process on both scopes exactly as before, and that a project-scoped connection's existing behavior on every failure path is byte-for-byte unchanged.
  - Delivered: `handle_continue(:connect_gateway, socket)` now branches only on `{:gateway_credential_transport_error, reason}` for a `{:device_workspace, _}` scope; every other shape, and every failure at all for `{:project, _}`, falls through to the unchanged `refuse_gateway_start/3` (the original log text and `{:stop, :normal, socket}`, verbatim). The retriable branch writes `ConnectionStatus.set_disconnected/1`, logs a warning, and schedules `:retry_connect_gateway` at a widening, repeating delay (`@gateway_credential_retry_after_msec`, overridable via `opts` for tests) tracked in `socket.assigns`; a new `handle_info(:retry_connect_gateway, socket)` re-enters `{:continue, :connect_gateway}}`. `handle_disconnect/2`, `handle_topic_close/3`, `ProjectConnections`, and the module's `restart: :temporary` declaration are untouched.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] A configuration naming a project, and the deep-link path that produces one, behave exactly as before.
- [x] Project-scoped attachment, delivery, and run execution tests pass unchanged.
- [x] Cross-workspace attachment and credential-scope isolation tests pass.
- [x] Liveness, staleness, and connection-state transitions pass, including the refused and lost cases.
- [x] The log, diagnostic, and no-analytics review finds no credential or fragment of one.
- [x] Build, formatting, lint, static checks, and logs review pass.
- [x] Required browser scenarios pass.
- [x] Product proof click path, run against the paired worker app with `:device_worker_stub` off and no `/_e2e` seeding: open `/`, click `Work without GitHub`, copy the pairing code from the worker app's menu bar, paste it into `Pairing code`, click `Pair worker`, answer the app's coding-agent step, then click `Check again` and read `Connected` with `Worker connected on this Mac.`
- [x] The worker app's own test suite passes.
- [x] AC-11 and AC-12 pass.
- [x] Product proof click path for recovery, with `:device_worker_stub` off and no `/_e2e` seeding: with the worker attached, stop the control plane, wait past its retry window, start the control plane again, and read `Connected` in the menu bar and a reachable worker in the dashboard without touching the app.

## Blocked Decisions

- None.

## Release Gate

- [ ] The accountable privacy review of storing a credential for a worker that has no project, covering its retention and revocation path.
- [ ] Real macOS signing and notarization of a build carrying this setup step, on supported macOS hosts.

## Progress Log

See [progress.md](progress.md).
