# Local Worker Run Execution Design

## Context

The control plane already owns every contract this slice consumes, all of it merged and verified. `specs/07-guided-specification-delivery` delivered the worker protocol and execution-manifest codec, the durable command outbox and dispatcher, the authenticated worker gateway, the workspace and branch isolation rules, the agent-adapter boundary, the artifact-upload transport, and state reconciliation. `specs/02-local-project-onboarding` delivered workspace-bound pairing, so a local worker can already be authorized for one device workspace and revoked or rotated.

What does not exist is the counterpart. `SddOrchestrator.Delivery.AgentAdapter` has exactly one implementation in the application, `AgentAdapter.Unavailable`, which answers every callback with `agent_unavailable` by design so an unconfigured deployment cannot launch an agent nobody chose. `SddOrchestratorWeb.WorkerSocket.issue/3` mints the gateway credential and has no caller anywhere in `lib/`; its own documentation says provisioning belongs to a worker-setup workflow outside that slice. The worker-side building blocks `Delivery.Worker.Workspace`, `Delivery.Worker.Branch`, `Delivery.Worker.ProcessLock`, and `Delivery.Worker.ArtifactUpload` are implemented and proved, but nothing composes them into a running process, and no code dials the `/worker` socket.

`Delivery.WorkerProtocol` fails a join closed when the announced capabilities omit any of `run.start`, `run.resume`, `run.retry`, `run.cancel`, `run.reconcile`, `evidence.required_checks`, or `workspace.isolated_branch`, and ignores unknown names so a worker cannot widen its own contract. That constraint, not a scoping preference, sets this slice's floor.

## Proposed Approach

Add the missing seam and the missing process, and compose what already exists rather than reimplementing it.

The control plane gains one authenticated exchange: a paired worker presents its credential and a project reference and receives a bounded project-scoped gateway credential from the existing `WorkerSocket.issue/3`. Authorization reuses `Devices.Pairing.authenticate_worker/1` and `Devices.Pairing.authorize_for_workspace/2`, so revocation and rotation already govern it and no new credential concept is introduced.

The worker itself lives in this repository under its own namespace and is started by a dedicated mix task that boots only the worker supervision tree. It reads a worker-local configuration file, holds its credential and durable run state under the operator's own account, dials the gateway over a websocket client, and runs one attempt at a time through a supervised execution process. Each command operation composes the delivered primitives: manifest validation through `ExecutionManifest` and `ProtocolCodec`, isolation through `Workspace.prepare/1` and `Branch.prepare/2`, exclusivity through `ProcessLock.acquire/3` and its stop-request seam, agent launch and observation through the `AgentAdapter` behaviour, and artifact transfer through `Worker.ArtifactUpload.upload/4`.

Two adapters implement the behaviour, one per coding agent, each translating its own command-line agent's streaming output into the adapter's four allowed event types and mapping a resumable session onto the thread reference the boundary already models. The required-check runner executes the attempt's own check contract and is the only source of a verification-completed event.

## Components Affected

- `SddOrchestratorWeb`: one new authenticated worker endpoint that exchanges a pairing credential for a gateway credential. No change to the socket, the channel, the artifact controller, or any existing route.
- `SddOrchestrator.Worker` (new): configuration, credential custody, durable run state, supervision tree, gateway client, command router, attempt executor, and required-check runner.
- `SddOrchestrator.Delivery.AgentAdapter` (new implementations): one adapter per supported coding agent. The behaviour, its input projection, its secret boundary, and its event vocabulary are unchanged.
- `Mix.Tasks`: one task that starts the worker against a configuration file and one that completes pairing from a code.
- `mix.exs`: one websocket client dependency for the gateway connection.
- `Devices.Pairing`, `Delivery.Worker.Workspace`, `Delivery.Worker.Branch`, `Delivery.Worker.ProcessLock`, `Delivery.Worker.ArtifactUpload`, `Delivery.WorkerProtocol`, `Delivery.ProtocolCodec`, `Delivery.ExecutionManifest`, `Delivery.SecretBoundary`: consumed unchanged.

## Data and Access Boundaries

- `WorkerConfiguration`: the worker-local durable record of how this worker reaches the control plane and what it may run. It holds the control-plane address, the device workspace reference, the issued worker credential, the selected agent adapter and its executable reference, and the workspace root. It is created at pairing, updated by the operator, and removed when the operator removes the worker. It exists only on the device.
- `WorkerRunState`: the worker-local durable record of the attempt currently or most recently in flight. It holds the command and attempt references, the manifest digest, the fence token, the last event sequence the control plane accepted, the agent thread reference, and the lifecycle state. It is written before each delivery, read on reconnect to avoid re-delivery, answers a reconcile command, and is cleared when the attempt reaches a terminal state.

Required boundaries:

- Both records live on the device, readable only by the operating-system account that runs the worker. Neither is uploaded, mirrored, backed up, or reconstructable from control-plane data.
- The control plane stores no repository content, absolute path, agent transcript, or provider credential from this worker. Only protocol events, evidence references, and uploaded artifacts cross the boundary, all of them already governed by the delivery slice.
- The agent subprocess environment is an allowlist plus a fixed non-interactive git setting. The worker's own environment, its credential, and the operator's provider credentials are unreachable from it.
- The raw gateway credential is held in memory for the connection's lifetime and never written to disk; only the worker credential issued at pairing is persisted.
- A worker credential authorizes exactly one device workspace, and a gateway credential exactly one project and execution target. Neither widens on reconnect.

## Interfaces

- New: an authenticated worker credential exchange that accepts a worker credential and a project reference and returns a bounded gateway credential. It is the first caller of `SddOrchestratorWeb.WorkerSocket.issue/3`.
- Consumed unchanged: the `/worker` socket and the `worker:PROJECT_ID` channel topic, protocol version 1, with the acknowledgement, heartbeat, event, and reconcile inbound messages and the command outbound message.
- Consumed unchanged: `POST /worker/artifacts` authenticated by the same gateway credential.
- Consumed unchanged: the `AgentAdapter` behaviour callbacks for installed version, start, and observe, and the `Launch` result that reports whether a provider thread was resumed or newly started.
- Compatibility requirement: the worker announces every required capability the protocol defines and no capability it cannot honor, and it must keep working against the existing control plane without any change to the protocol vocabulary.

## Decisions and Tradeoffs

### Developer-run process rather than a signed native application

- Choice: The worker is started from this repository's toolchain by a mix task, using the coding agents already installed on the operator's machine.
- Reason: The protocol client, the isolation rules, and the agent execution are identical in both form factors, and packaging is already a release gate in `specs/02-local-project-onboarding` and `specs/11-ai-runtime-governance`. This makes a real run testable without an installer.
- Consequence: The approved non-developer story is not served yet. Anyone testing this needs the Elixir toolchain and a terminal, and the graphical installation, signing, and auto-update remain release-gated.

### Both coding agents, one adapter per task

- Choice: Claude Code and Codex are each implemented as a separate task behind the unchanged behaviour, selectable by configuration.
- Reason: Two adapter integrations in one task is an explicit task-size split signal, and each fails independently against a different command-line contract.
- Consequence: Two agent surfaces to keep working as their command-line interfaces change. Each adapter checks its installed version before launch so an unsupported version fails closed rather than producing unparsable output.

### The worker honors the protocol's full required-capability set

- Choice: Accepted by the user on 2026-08-05. This slice implements start, resume, retry, cancel, and reconcile, plus isolated-branch and required-check support, and `specs/07-guided-specification-delivery` keeps its required-capability set unchanged.
- Reason: `WorkerProtocol.negotiate/1` fails closed on a missing required capability, so a start-only worker cannot join. Announcing a capability the worker will not honor is exactly what that rule exists to prevent, and narrowing the set would change an approved contract inside a `Verified` slice to buy a smaller first worker.
- Consequence: The slice sits at twelve tasks with a dependency path of eight, the maximum a standard slice allows. Resume and retry are cheap because they reuse the start execution path with the manifest's continuation reason, but cancel, reconcile, and the check runner are genuine additional surfaces.

### The worker shares this repository and is isolated by its supervision tree

- Choice: Worker modules live under `lib/sdd_orchestrator/worker/`, alongside the `Delivery.Worker` primitives that already live here, and the mix task starts only the worker tree.
- Reason: The delivered worker-side primitives are already in this codebase, and a separate repository or an umbrella conversion would duplicate the protocol modules or restructure the project for no behavioral gain.
- Consequence: The worker shares a compiled codebase with the control plane and could in principle reach the repository layer. The boundary is enforced by what the supervision tree starts and by a proof that the worker path opens no database connection and references no control-plane context. Extracting the worker into its own artifact belongs to release packaging.

### A websocket client dependency rather than a hand-written client

- Choice: Add one maintained Phoenix channel client dependency for the gateway connection.
- Reason: Reconnect, rejoin, heartbeat timing, and message framing are exactly where a hand-written client silently diverges from the server's expectations, and the protocol's own guarantees are what this slice must prove.
- Consequence: One more dependency in the audit surface, offset by removing a class of framing and reconnect defects the slice would otherwise have to prove itself.

## Risks

- A coding agent's streaming output format is version-specific and can change without notice. Each adapter checks the installed version before launch and treats an unrecognized shape as a typed drop, so a drifted agent fails closed rather than injecting unreviewed content into project activity.
- A long-running agent can outlive its attempt lease, leaving two processes believing they own one run. The fence token, the durable process lock, and the stop-request seam are all checked before and during execution, and the end-to-end task proves a superseded attempt actually stops.
- The worker mutates a real repository on the operator's machine. It only ever works on the isolated branch the manifest names, never force-updates a branch it did not create for the run, and refuses a working directory that cannot be proven to belong to the run before any process exists.
- An agent can emit credential material or content that claims verification succeeded. The adapter boundary drops both by typed reason, and the check runner is the only source of a verification-completed event.
- Sharing a codebase with the control plane makes an accidental database or context call possible. A focused proof asserts the worker path opens no repository connection.

## Open Questions

- None.
