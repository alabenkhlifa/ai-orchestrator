# Local Worker Run Execution

## Status

Approved

Every product decision is resolved. The worker is a developer-run local process started from this repository's toolchain and installs nothing; both the Claude Code and the Codex command-line agents are supported behind the existing agent-adapter boundary; one run executes from an explicit start through a terminal state; and the worker honors the delivery protocol's complete required-capability set rather than narrowing it, because a worker missing any required capability cannot join at all. `specs/07-guided-specification-delivery` keeps its approved contract unchanged.

## Outcome

An approved development run actually executes on the machine that holds the repository. A paired local worker dials the control plane, prepares an isolated branch, launches a real coding agent, streams normalized progress and evidence back into the feature's activity, runs the attempt's required checks, and reaches a terminal state. The device exposes no inbound port, the agent subprocess holds no credential, and nothing about the repository reaches the control plane beyond the event and evidence contract the delivery slice already approved.

## Users

- A project participant who starts development on a ready feature and reads its progress. This person may be a non-developer and never sees the worker.
- The device operator who runs the worker on the machine that holds the repository. For this slice that person is comfortable running one terminal command; the non-developer graphical installation remains release-gated.

## In Scope

- Issuing a project-scoped gateway credential to a local worker that is already paired to the device workspace and authorized for it.
- A developer-run worker process started from this repository's toolchain, with its own configuration, worker-local credential custody, durable run state, supervision, and restart.
- The worker side of the delivery gateway: dial-out connection, topic join, protocol version and capability negotiation, single acknowledgement, heartbeat, reconnect, and reconciliation snapshot.
- Execution of the delivery protocol's command operations for one execution target: start, resume, retry, cancel, and reconcile, one attempt at a time.
- Execution-manifest validation, isolated workspace and feature-branch preparation at the approved base revision, and a fenced single-process attempt lease.
- Two coding-agent adapters behind the existing agent-adapter boundary: Claude Code and Codex, each selectable by worker configuration.
- Normalized progress, evidence, blocking-question, and agent-failure events, with anything outside the agent's allowed vocabulary dropped by typed reason rather than forwarded.
- Execution of the attempt's required-check contract, and the workspace-ready and verification-completed events that only the worker may emit.
- Evidence artifact upload over the existing authenticated worker artifact endpoint.

## Out of Scope

- The connection between this worker and `specs/11-ai-runtime-governance`: personal AI connections funding a run, model and effort pinning, spending ceilings, and runtime observations. That integration is the deferred Slice 07 lifecycle work named in that slice's task plan.
- The personal-AI worker channel, the Codex App Server adapter, and worker-local provider credential linking.
- Preview deployment requests and screenshot evidence capture.
- Remote, cloud-hosted, and user-managed non-local workers, and any operating system other than macOS.
- Signed native packaging, graphical installation, auto-update, and the non-developer pairing flow.
- Any change to the control plane's run lifecycle, command outbox, dispatcher, event ingestion, reconciliation, or review behavior. This slice implements the counterpart that the approved contract already expects.
- More than one concurrent run on one execution target.

## Primary Workflow

1. A project owner opens the project's device setup and generates a single-use pairing code for the device workspace that holds the repository.
2. On that machine, the operator starts the worker with the control-plane address and the pairing code. The worker completes pairing, receives its credential, stores it worker-locally, and writes it nowhere else.
3. The worker exchanges its credential for a project-scoped gateway credential, dials the control plane, joins its execution target's topic, and announces its protocol version and capabilities.
4. The project shows the worker as reachable, and a participant starts development on a ready feature under the existing guided-delivery rules.
5. The worker receives the start command, validates the execution manifest against the attempt it names, acknowledges it exactly once, and refuses a duplicate or superseded command without acting on it.
6. The worker prepares the isolated workspace and feature branch at the approved base revision, acquires the fenced attempt lease and the single-process lock, and reports the workspace ready.
7. The worker launches the configured coding agent in exactly that directory with only the projected agent input and an allowlisted environment, then streams normalized progress, evidence, and blocking questions while heartbeating its state.
8. The worker runs the attempt's required checks, uploads the resulting evidence artifacts over its own credential, and reports verification completion.
9. The attempt reaches a terminal state, the lease and the process lock are released, and the feature's activity shows the outcome.
10. If the connection drops, the worker reconnects, re-delivers nothing the control plane already accepted, and answers a reconcile command with its authoritative snapshot of the attempt.

## Business Rules

- The worker always dials the control plane. The control plane never dials the worker, and the device exposes no inbound port.
- A gateway credential is issued only to a worker credential that is active, unrevoked, and authorized for the device workspace that owns the named project. It names exactly one project and one execution target, expires, and authorizes nothing else.
- A revoked or rotated worker credential can no longer obtain a gateway credential, and an already issued one stops being accepted once it expires.
- The worker announces and honors the delivery protocol's complete required-capability set: starting, resuming, retrying, canceling, and reconciling a run, isolated-branch execution, and required-check support. It announces no capability it cannot honor.
- The worker refuses to join when the control plane rejects its protocol version or a required capability, and reports that refusal to its operator rather than treating it as a connection.
- Every command is acknowledged exactly once. A repeated command identifier is acknowledged as a duplicate and is not executed a second time.
- A command naming an attempt that is not current, or carrying a fence token lower than the one the worker holds, is refused. A superseded attempt never continues to run.
- One attempt at a time runs on one execution target, enforced by a durable single-process lock rather than by in-memory state alone.
- The agent is launched only in a directory proven to belong to the run. A working directory that cannot be proven is refused before any process exists.
- The agent subprocess receives the projected agent input and an allowlisted environment only. No repository credential, provider credential, control-plane credential, or unrelated worker environment value is reachable from it.
- The agent may report progress, evidence, a blocking question, and its own failure. Anything else it emits, including a claim that verification is complete or a workspace is ready, is dropped with a typed reason and never forwarded.
- Only the worker emits the workspace-ready and verification-completed events, and it emits verification completion only from the attempt's own required-check contract.
- Repository content, absolute paths, agent transcripts, and provider credentials stay on the device. Only the approved event, evidence, and artifact contract crosses the boundary.
- The worker never rewrites shared history: it works on the isolated feature branch named by the manifest and never force-updates a branch it did not create for that run.
- Worker-local configuration and run state are readable only by the operating-system account that runs the worker, and no copy of either is stored in the control plane.
- The worker resolves the coding agent's provider credentials inside its own boundary, from the operator's existing local agent installation.

## Acceptance Criteria

- [AC-01] Given a worker credential that is active and authorized for the device workspace owning a project, when the worker requests a gateway credential for that project, then it receives one that names exactly that project and execution target and expires within its bounded lifetime.
- [AC-02] Given a worker credential that is revoked, rotated, or authorized for a different workspace, when it requests a gateway credential for a project, then the request is refused without disclosing whether the project exists.
- [AC-03] Given a started worker holding a pairing code, when pairing completes, then the credential and the operator's configuration are stored worker-locally under the operator's own account, no credential is written to the project or to the control plane beyond its digest, and restarting the worker reuses the stored credential without a new code.
- [AC-04] Given a configured worker, when it dials the control plane, then it joins its execution target's topic with a supported protocol version and its announced capabilities, and it becomes visible as reachable to the project.
- [AC-05] Given the control plane rejects the worker's protocol version or a required capability, when the join is attempted, then the worker reports the refusal to its operator with the reason and does not retry as if it had connected.
- [AC-06] Given a start command for the current attempt, when the worker receives it, then it validates the execution manifest against that attempt, acknowledges it exactly once, and acknowledges an identical repeated command as a duplicate without executing it again.
- [AC-07] Given a command naming a superseded attempt or carrying a stale fence token, when the worker receives it, then the command is refused, no process is started, and any attempt already running under the superseded fence stops.
- [AC-08] Given a validated start command, when the worker prepares execution, then it creates or reuses the run workspace and the isolated feature branch at the approved base revision, holds the single-process lock, reports the workspace ready, and refuses to proceed when the working directory cannot be proven to belong to the run.
- [AC-09] Given the worker is configured for the Claude Code agent, when an attempt starts, then the installed agent version is checked before launch, the agent runs in the proven directory with only the projected input and allowlisted environment, and its output is observed as normalized events including a resumed or newly started thread.
- [AC-10] Given the worker is configured for the Codex agent, when an attempt starts, then the same version check, launch boundary, environment allowlist, and normalized observation hold, and the choice of agent changes nothing the control plane observes beyond the recorded agent reference.
- [AC-11] Given a running agent produces output, when the worker observes it, then progress, evidence, blocking-question, and agent-failure events are delivered in order with monotonic sequence numbers, and no event is delivered twice across a reconnect.
- [AC-12] Given the agent emits content outside its allowed vocabulary, a claim that verification is complete, a claim that the workspace is ready, or credential-shaped material, when the worker observes it, then the item is dropped with a typed reason and never reaches the control plane.
- [AC-13] Given an attempt carrying a required-check contract, when the agent reaches its own terminal state, then the worker runs those checks, reports each result as evidence, and emits verification completion only from the real check outcomes.
- [AC-14] Given a check or agent step produces an evidence artifact, when the worker uploads it, then it is transferred over the worker's own credential to the artifact endpoint, matched by content digest, and referenced by the evidence event rather than embedded in it.
- [AC-15] Given a cancel, resume, retry, or reconcile command, when the worker receives it, then a cancel stops the running agent and releases the lease and lock, a resume or retry starts from the manifest it carries with its continuation reason, and a reconcile answers with the worker's authoritative snapshot of the attempt.
- [AC-16] Given a paired worker and a ready feature on a real local repository, when a participant starts development, then the run executes end to end on that machine and the feature's activity shows the agent's progress, its evidence, the check outcomes, and the terminal state, with no credential, absolute path, or repository content outside the approved contract.

## Open Questions

- None.
