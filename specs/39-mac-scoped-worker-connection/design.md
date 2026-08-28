# Mac-Scoped Worker Connection Design

## Context

`specs/38-worker-initiated-pairing/` made an unpaired app obtain its own code, show it on the menu bar, and have the dashboard redeem it. It stopped at authorization on purpose: it recorded that the credential is not retained, that the worker has no project, and that giving it one is deferred and would need a credential the flow discards. It also rejected storing the credential with an unset project, because that needs a storage contract for a partially configured worker.

This specification makes that contract, and it changes the scope the contract is written against.

Three facts in the running system explain why:

- `SddOrchestrator.Worker.Configuration` requires a `project_id`, so an app-paired worker has nothing it can store, and `SddOrchestrator.Worker.GatewayConnection` never starts. On a real install, `Configuration.load/1` answers `{:error, :not_paired}` and `Worker.ConnectionStatus.status/0` answers `%{status: :unknown}`.
- `Delivery.CommandTransport.Channel.attach/2` registers in `Delivery.WorkerRegistry` keyed by project, and only a successful join on the project-scoped `worker:` topic reaches it. `Devices.WorkerLivenessRefresher` enumerates exactly that registry, so it can only ever stamp `LocalWorker.last_seen_at` for a worker that has joined a project. `WorkerDiscovery.reachable?/2` answers `false` for a `nil` timestamp, so an app-paired worker is reported unavailable forever. In the development database every real worker row carries `last_seen_at = NULL`; only the LiveView stand-in rows carry a value, because the stand-in calls `Pairing.mark_seen/1` directly.
- `ConnectionStatus.set_connected/0` is called from `GatewayConnection.handle_connect/1`, which fires when the socket connects, before the join is attempted. `handle_topic_close/3` reports a join refusal once and never rejoins, and never calls `set_disconnected/1`. So once a worker is configured, the app can say Connected while the control plane has attached nothing.

The control plane already reasons about workers per Mac: `Devices.worker_status/1` takes a device workspace and asks whether any of its active workers is reachable. Only the transport and the worker's own configuration are per project. That mismatch is the defect, not the symptom.

## Proposed Approach

Move the worker's connection identity from a project to the Mac's project space, and leave execution addressing per project where it already is.

- A stored configuration keeps its credential, worker identity, control-plane address, and coding agent, and drops `project_id` from its required fields.
- The credential a menu-bar redemption issues is retained by the app rather than discarded, which is what makes the rest reachable.
- The gateway credential exchange answers a credential scoped to the worker's device workspace instead of one project.
- The worker attaches on a Mac-scoped topic. The control plane registers that attachment in a registry keyed by device workspace, alongside the existing per-project registry, which is untouched.
- Liveness derives from the Mac-scoped registry, so a connected but idle worker with no project is still stamped seen.
- The app's Connected state is driven by a successful attachment, not by the transport callback.

Per-project run delivery keeps using the existing project-keyed registry and the existing project-scoped `worker:` topic. This slice adds a second, coarser attachment; it does not replace or reroute the first.

## Components Affected

- Worker configuration storage in the worker release, and its required fields.
- The app's post-redemption path and its coding-agent setup step.
- The gateway credential exchange endpoint and the scope of the credential it issues.
- The worker gateway connection, its topic, and its connection-state reporting.
- The command transport's attachment registries.
- Worker liveness refresh and the reachability policy that reads it.
- The menu-bar status derivation.

## Data and Access Boundaries

- `WorkerConfiguration`: the on-device record the worker release stores. Holds the worker identity, the credential, the resolved control-plane address, and the chosen coding-agent executable. After this slice it holds no project and is valid without one. It lives on the person's own machine, with the credential secret held where the platform keeps secrets, and is never uploaded.
- `WorkerAttachment`: the control plane's in-memory record that one worker process is attached for one device workspace. Holds the worker identity, the negotiated protocol version and capabilities, and when it attached. It exists only while an authenticated channel process is alive, is never persisted, and carries no repository path, filename, or source content.

Required boundaries:

- A credential authorizes exactly one device workspace. An attachment aimed at a different one is refused before any negotiation, the same way the project-scoped join already checks its execution target.
- Only the control plane writes `LocalWorker.last_seen_at`, and only from its own record of live attachments. No worker-supplied timestamp is trusted.
- A dashboard reads reachability through the existing device-workspace status function. It never reads an attachment record directly and never receives a worker identity it did not already hold.
- The coding-agent path is a local filesystem path chosen on the person's own machine. It stays on that machine and is not reported to the control plane.
- Neither credential appears in a log, crash report, analytics event, or diagnostic on either side.

## Interfaces

- The gateway credential exchange accepts a worker credential with no project and answers a credential scoped to the worker's device workspace. The existing project-scoped request shape stays accepted and unchanged, so `specs/36-local-worker-native-distribution/`'s deep-link path keeps working exactly as verified.
- A new Mac-scoped attachment topic names the device workspace. The existing project-scoped `worker:` topic, its negotiation, and its message contract are unchanged.
- `Delivery.CommandTransport.Channel`'s project-keyed registry and `deliver/1` are unchanged. The Mac-scoped registry is additive.
- `WorkerDiscovery`'s reachability policy and staleness window are unchanged. Only the source that stamps `last_seen_at` widens.

## Decisions and Tradeoffs

### Connection is scoped to the Mac, execution stays scoped to the project

- Choice: The worker attaches once for its device workspace. Run commands keep being addressed to the project-scoped `worker:` topic through the existing project-keyed registry.
- Reason: The control plane already answers "is this Mac's worker reachable" at workspace level, and every dashboard asks that question. Making the worker's connection identity match removes the mismatch at its source. Scoping execution to the Mac instead would widen what one credential authorizes, which is the opposite of what the trust boundary needs.
- Consequence: A worker holds two kinds of attachment, one coarse and one per project. That is more moving parts than a single topic, and the cost is accepted because collapsing them would either weaken authorization or keep liveness unanswerable for a worker with no project.

### The credential is retained with no project

- Choice: The app stores the credential and worker identity a menu-bar redemption issues, in a configuration that names no project.
- Reason: `specs/38` deferred exactly this and named the reason: the configuration required a project. Once connection is Mac-scoped, a project is no longer a precondition, so the storage contract it declined to invent is now a small change rather than a speculative one.
- Consequence: A credential now exists on disk for a worker that cannot yet run anything for a project. It authorizes attachment and nothing else until a project is chosen, which is the same authority the dashboard already granted at redemption.

### Connected means the control plane attached this worker

- Choice: The app reports Connected only after a successful attachment, and reports a refusal as a refusal. The transport callback stops being the source of that claim.
- Reason: Today `set_connected/0` fires on socket connect, before the join, and a join refusal never withdraws it. That produces the exact contradiction a person hits: the menu bar says Connected while every dashboard says Unavailable, and both are reporting honestly about different things.
- Consequence: Connected appears slightly later than it does now, after a round trip rather than after a socket. That delay is the point: the earlier claim was not true.

### Liveness stays control-plane-derived

- Choice: `last_seen_at` continues to be stamped only from the control plane's own registry, now including Mac-scoped attachments.
- Reason: `specs/02-local-project-onboarding/`'s `Registry-Derived Worker Liveness` decision already established why a worker-initiated liveness call cannot close this: the failing case is a connected but idle worker that emits no heartbeat. Widening the registry the refresher reads preserves that reasoning instead of reopening it.
- Consequence: Liveness accuracy stays bounded by the refresh interval, which the staleness window already tolerates. No new outbound data and no protocol change on the existing execution path.

### The coding agent is chosen once for the Mac

- Choice: The app asks for the coding agent during its own setup, stores it in the configuration, and does not ask again per project.
- Reason: The executable is a property of the machine, not of a repository. Asking per project would repeat a question whose answer does not vary.
- Consequence: A person who wants different agents for different projects cannot express that. No evidence yet suggests they do, and adding it later is additive rather than a change to what is stored.

### The repository folder is not asked for here

- Choice: This slice's setup asks for the coding agent only. It does not ask for a repository folder.
- Reason: With connection scoped to the Mac, a repository belongs to a project, and this slice deliberately delivers no project. `specs/36`'s deep-link setup asks for both because that path pairs against one project; that path is unchanged.
- Consequence: A worker connected this way is reachable but has no repository, so a project still cannot select one until the follow-on lets the dashboard drive the worker's folder picker. That gap is real and is named in the deferred boundary rather than implied.

## Risks

- A person may read Connected as "ready to work" while the worker still has no repository for any project. Reduced by keeping this slice's promise narrow in the app's own wording and by naming the follow-on; detected by a dashboard that shows a reachable worker and still cannot select a repository.
- Two attachment registries invite code that checks the wrong one. Reduced by leaving the project-keyed registry and its delivery path completely untouched and adding the Mac-scoped one beside it; detected by the existing project-scoped delivery tests continuing to pass unchanged.
- Widening the gateway credential exchange could accidentally widen the project-scoped credential too. Reduced by keeping the existing request shape and its answer byte-for-byte unchanged and proving both scopes side by side.
- A credential stored for a worker with no project is a secret with a longer idle life than before. Reduced by keeping it where the platform keeps secrets, by leaving it revocable exactly as it is today, and by proving it never reaches a log or diagnostic.
- Deriving liveness from a coarser registry could keep a worker reported reachable after its project work is impossible. Accepted: reachable has always meant the machine is answering, not that any particular project is ready, and the dashboard states connection separately from repository state.

## Open Questions

- None. Two engineering choices are settled during implementation and recorded here when made: the exact Mac-scoped topic name and the shape of the exchange request that omits a project. Neither changes the approved workflow, the data boundaries, or any acceptance criterion.
