# Local Worker Run Execution Tasks

## Status

In Progress

The requirements are `Approved`, the design carries no open question, and the required capability is ready. The worker honors the delivery protocol's full required-capability set, which is what this twelve-task plan is sized for. Every control-plane contract the slice consumes is merged and verified. Task 1 is complete and verified; Task 2 is executable and independent of it.

## Active Slice

Deliver the local worker that the approved delivery contract already expects: pair it to a device workspace, let it exchange its credential for a project-scoped gateway credential, dial the control plane, and execute one approved development run at a time on the machine that holds the repository, from an explicit start through workspace and branch isolation, a real coding agent, normalized events, the attempt's required checks, and uploaded evidence, to a terminal state and a reconcilable snapshot.

## Cross-Specification Dependencies

Requires:

- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 1`.

Provides:

- `capability:local-worker-gateway-client` — ready after `Task 3`.
- `capability:local-worker-run-execution` — ready after `Task 12`.

## Slice Size Gate

- Slice size: Standard

The slice delivers one coherent outcome through one verification gate: a paired local worker executes an approved run end to end. It contains twelve tasks and its longest `Depends on:` path contains eight tasks, both at the standard limit. The size is set by the protocol rather than by preference, because `Delivery.WorkerProtocol` fails a join closed when any required capability is missing, so a worker delivering fewer operations cannot connect and has no independently verifiable outcome to split off.

## Task Size Gate

- Every task is `Size: Standard`. Each delivers one independently provable outcome, owns at most three acceptance criteria and at most one data entity, and is expected to produce one task-boundary implementation commit with focused proof running in about ten minutes.
- The two agent adapters are separate tasks because two command-line integrations in one task is an explicit split signal and each fails independently against a different external contract.
- The gateway credential exchange is separate from the client that consumes it because one is a control-plane authorization surface and the other is worker runtime behavior, with different proof and different failure modes.
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One authenticated control-plane exchange that turns an active workspace-authorized worker credential into a bounded project-scoped gateway credential through the existing `WorkerSocket.issue/3`.
- A worker runtime under `lib/sdd_orchestrator/worker/` with its own supervision tree, worker-local configuration and credential custody, durable run state, and the mix tasks that pair and start it.
- A gateway client that dials the `/worker` socket, joins the execution target's topic, negotiates protocol version and capabilities, acknowledges, heartbeats, reconnects, and answers reconcile.
- Command execution for start, resume, retry, cancel, and reconcile, one attempt at a time, composing `ExecutionManifest`, `ProtocolCodec`, `Delivery.Worker.Workspace`, `Delivery.Worker.Branch`, and `Delivery.Worker.ProcessLock`.
- Two `Delivery.AgentAdapter` implementations, one for Claude Code and one for Codex, each with its own installed-version check and output normalization.
- Agent event normalization, ordered delivery with monotonic sequences, typed drops for anything outside the agent vocabulary, the required-check runner, and evidence artifact upload through `Delivery.Worker.ArtifactUpload`.
- One websocket client dependency in `mix.exs`.

Excluded:

- Every existing control-plane surface this slice consumes: the worker socket and channel, the command outbox and dispatcher, event ingestion, reconciliation, the artifact controller and store, run transitions, review, and the delivery protocol vocabulary itself. This slice adds the counterpart and changes none of them.
- `Delivery.AgentAdapter`'s behaviour, input projection, secret boundary, and event vocabulary, and `AgentAdapter.Unavailable`, which stays the default for an unconfigured deployment.
- `Devices.Pairing` and every `specs/02-local-project-onboarding` surface other than consuming its authorization functions.
- Every `specs/11-ai-runtime-governance` surface: the personal-AI channel, the Codex App Server, personal connections, catalogs, quotas, cost ledgers, and runtime observations.
- Preview requests, screenshot evidence, remote and cloud workers, and any operating system other than macOS.

Deferred after this slice:

- The `specs/11-ai-runtime-governance` lifecycle integration that slice deferred: a run funded by a personal AI connection, a pinned model and effort, an enforced spending ceiling, and ingested runtime observations.
- Preview deployment requests and screenshot evidence capture on the worker.
- Concurrent runs on one execution target, and worker-side scheduling between projects.
- The personal-AI worker client, which is a separate outcome with its own verification gate.

Release gates:

- Signed native worker packaging, graphical installation, auto-update, and the non-developer pairing flow that `specs/02-local-project-onboarding` already lists as release-gated.
- The supported coding-agent versions recorded for the deployment, so an operator cannot silently run an agent whose output contract was never proved.
- A live end-to-end run against a real repository with real provider credentials on a machine that is not the development machine.
- Accountable privacy and security review of the worker boundary: credential custody at rest, the agent environment allowlist, and the absence of repository content in control-plane records.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 - Issue a project-scoped gateway credential to a paired worker.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give the first caller to the credential the gateway already verifies, so a paired worker can connect without inventing a second credential concept.
  - Owned surfaces: The authenticated worker credential exchange route and controller, worker authentication through `Devices.Pairing.authenticate_worker/1`, workspace authorization for the named project through `Devices.Pairing.authorize_for_workspace/2`, bounded credential lifetime, refusal for revoked, rotated, expired, and cross-workspace credentials, existence non-disclosure, and its fixtures.
  - Owns: AC-01, AC-02
  - Proof: Focused controller and context tests prove an active authorized credential receives a gateway credential that verifies to exactly the named project and execution target, that its lifetime is bounded, and that a revoked, rotated, cross-workspace, or unknown credential is refused identically without revealing whether the project exists.

- [x] Task 2 - Establish the worker runtime, configuration, and credential custody.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give the worker somewhere to live, something to read, and somewhere to keep its credential before anything tries to connect or execute.
  - Owned surfaces: `WorkerConfiguration`, the worker supervision tree, the pairing mix task, the start mix task, worker-local file custody and permissions, agent-adapter selection and executable reference, workspace-root resolution, configuration validation and typed startup refusal, restart without re-pairing, and the worker test fixtures.
  - Owns: AC-03, entity:WorkerConfiguration
  - Proof: Focused tests prove pairing stores the credential and configuration worker-locally under owner-only permissions, that a restart reuses them without a new code, that an invalid or incomplete configuration refuses startup with a typed reason rather than partially starting, and that the started tree opens no database connection and calls no control-plane context.

- [x] Task 3 - Connect and negotiate the delivery gateway.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2
  - Purpose: Make the worker reachable to the control plane on the terms the protocol already fails closed on, so every later task has a real channel to answer.
  - Owned surfaces: `capability:local-worker-gateway-client`, the websocket client dependency and gateway connection process, credential exchange on start, topic join for the execution target, protocol version and capability announcement, acknowledgement and heartbeat emission, reconnect and rejoin with backoff, typed refusal reporting to the operator, and the connection test harness against the real socket.
  - Owns: AC-04, AC-05
  - Proof: Focused tests against the real `WorkerSocket` and `WorkerChannel` prove the worker joins its own execution target with a supported version and the full required-capability set, that it becomes visible as reachable, that an unsupported version or a withheld required capability is reported to the operator with its reason and not retried as a success, and that a dropped connection rejoins the same topic without widening its authorization.

- [x] Task 4 - Accept commands and own the attempt lease and durable run state.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Make command handling exactly-once and single-attempt before any process can be started by it.
  - Owned surfaces: `WorkerRunState`, the command router, execution-manifest validation through `ExecutionManifest` and `ProtocolCodec`, single acknowledgement and duplicate detection, fence-token and current-attempt checks, superseded-attempt refusal and stop, durable run-state persistence and recovery on restart, last-accepted-sequence tracking, and the command fixtures.
  - Owns: AC-06, AC-07, entity:WorkerRunState
  - Proof: Focused tests prove a start command is validated against the attempt it names and acknowledged exactly once, that an identical repeated command is acknowledged as a duplicate without executing again, that a command naming a superseded attempt or carrying a stale fence token is refused with no process started, that an attempt already running under a superseded fence stops, and that run state survives a worker restart.

- [x] Task 5 - Prepare the isolated workspace and feature branch.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Guarantee that whatever the agent later does happens inside a directory and a branch that provably belong to this run.
  - Owned surfaces: Composition of `Delivery.Worker.Workspace.prepare/1`, `Delivery.Worker.Branch.prepare/2`, and `Delivery.Worker.ProcessLock.acquire/3`; base-revision validation; branch creation and reuse; the workspace-ready event; unproven-working-directory refusal before any process exists; lock release on every exit path; and a real local git fixture repository.
  - Owns: AC-08
  - Proof: Focused tests against a real fixture repository prove the run workspace and isolated branch are created at the approved base revision and reused on a second command for the same attempt, that the single-process lock is held for the attempt and released on success, failure, and crash, that the workspace-ready event is emitted only by the worker, and that a working directory failing the manifest proof is refused before a process is created.

- [x] Task 6 - Implement the Claude Code agent adapter.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Give the agent-adapter boundary its first real implementation without changing the boundary.
  - Owned surfaces: The Claude Code `Delivery.AgentAdapter` implementation, installed-version resolution and refusal, headless launch in the given directory, the projected agent input, the environment allowlist enforcement, streaming output decoding, session resume mapped onto the thread reference with new-thread fallback, process failure and exit handling, and a deterministic recorded-output double.
  - Owns: AC-09
  - Proof: Focused tests prove the installed version is checked before launch and an unsupported version is refused, that the process is started only in the given directory with the allowlisted environment and no other value, that recorded streaming output decodes into the boundary's allowed event types in order, that a resumable session is reported as resumed and an unresumable one falls back to a new thread, and that a launch failure and an unexpected exit return their own typed errors.

- [ ] Task 7 - Implement the Codex agent adapter.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Prove the boundary is genuinely provider-neutral by carrying a second command-line agent through the same contract.
  - Owned surfaces: The Codex `Delivery.AgentAdapter` implementation, installed-version resolution and refusal, non-interactive launch in the given directory, the environment allowlist enforcement, its own output decoding, thread resume and fallback, process failure and exit handling, adapter selection by configuration, and a deterministic recorded-output double.
  - Owns: AC-10
  - Proof: Focused tests prove the same version check, directory boundary, environment allowlist, event vocabulary, thread-resume behavior, and typed failures hold for the Codex adapter, and that switching the configured adapter changes nothing the control plane observes beyond the recorded agent reference.

- [ ] Task 8 - Normalize and deliver agent events.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5, Task 6
  - Purpose: Put the agent's output on the wire in the protocol's own shape without letting unreviewed content or a false completion claim through.
  - Owned surfaces: The observation loop, mapping adapter events onto protocol event envelopes with their agent source, monotonic sequence assignment, ordered delivery, no re-delivery of an accepted sequence across reconnect, typed drops for unknown types and for verification-complete and workspace-ready claims from an agent, credential-shaped content refusal, heartbeat state transitions during a run, and the terminal-state transition.
  - Owns: AC-11, AC-12
  - Proof: Focused tests prove progress, evidence, blocking-question, and agent-failure events reach the channel in order with monotonic sequences, that a reconnect mid-run re-delivers nothing the control plane already accepted, that an agent claim of verification completion or workspace readiness is dropped with its own reason, that credential-shaped content is refused, and that the attempt reaches its terminal state with the lease and lock released.

- [ ] Task 9 - Run the attempt's required checks.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8
  - Purpose: Make verification completion something the worker proves from real command outcomes rather than something the agent asserts.
  - Owned surfaces: The required-check runner over the attempt's own check contract, per-check execution in the proven working directory, per-check evidence events, timeout and failure handling, the verification-completed event as the worker's exclusive emission, and the check fixtures.
  - Owns: AC-13
  - Proof: Focused tests prove each check in the attempt's contract runs in the proven directory and reports its own evidence event, that a failing check produces a failed outcome rather than a completion, that a timed-out or unrunnable check is reported with its own reason, and that verification completion is emitted only from real check outcomes and never from agent output.

- [ ] Task 10 - Upload evidence artifacts.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 9
  - Purpose: Get evidence bytes across the boundary the approved way, by reference and by digest, rather than inside an event.
  - Owned surfaces: Composition of `Delivery.Worker.ArtifactUpload.upload/4` with the worker's own gateway credential, content-digest computation and match, evidence events referencing the uploaded artifact, oversized and rejected upload handling, retry on transient transport failure, and the upload fixtures.
  - Owns: AC-14
  - Proof: Focused tests against the real artifact endpoint prove an artifact is transferred over the worker's own credential, that the stored content matches the computed digest, that the evidence event references it rather than embedding it, that an oversized or refused upload produces a typed evidence outcome instead of a silent loss, and that a transient transport failure is retried without duplicating the artifact.

- [ ] Task 11 - Handle cancel, resume, retry, and reconcile.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4, Task 8
  - Purpose: Honor the remaining required capabilities the worker announced, so its contract with the control plane is true.
  - Owned surfaces: Cancel handling through the process stop-request seam with lease and lock release, resume and retry execution through the start path carrying the manifest's continuation reason and thread reference, the reconciliation snapshot answer built from durable run state, snapshot emission after reconnect, and the fixtures for each operation.
  - Owns: AC-15
  - Proof: Focused tests prove a cancel stops the running agent and releases the lease and lock, that a resume and a retry execute from the manifest they carry with the recorded continuation reason and resume the provider thread when one is available, that a reconcile answers with the worker's authoritative attempt snapshot, and that a snapshot after reconnect agrees with the last sequence the control plane accepted.

- [ ] Task 12 - Prove one real run end to end on a local repository.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 7, Task 10, Task 11
  - Purpose: Show the whole path working on a real machine against a real repository, which is the outcome this slice exists for and the one no single earlier task can demonstrate.
  - Owned surfaces: `capability:local-worker-run-execution`, the end-to-end integration scenario driving pairing, connection, start, isolation, agent execution, events, checks, artifact upload, and terminal state against a real local fixture repository with a recorded agent; the operator runbook for starting the worker; and the boundary assertions over everything the run wrote to the control plane.
  - Owns: AC-16
  - Proof: A focused integration scenario runs a complete attempt against a real local fixture repository and asserts the feature's activity shows the agent's progress, its evidence, the check outcomes, and the terminal state, that the isolated branch carries the work and no other branch moved, and that nothing the run wrote to the control plane contains a credential, an absolute path, or repository content outside the approved contract.

## Verification Gate

- [ ] AC-01 through AC-16 pass and no criterion or entity is deferred or release-classified.
- [ ] Every active acceptance criterion has exactly one primary task owner and both data entities are owned.
- [ ] A real run completes end to end on a local repository with each supported coding agent, and the feature's activity shows its progress, evidence, check outcomes, and terminal state.
- [ ] The worker announces exactly the protocol's required capabilities, honors every one of them, and announces nothing it cannot honor.
- [ ] No control-plane record produced by a run contains a credential, an absolute path, an agent transcript, or repository content outside the approved event, evidence, and artifact contract.
- [ ] The agent subprocess environment is proved to be the allowlist alone, and no provider, repository, or control-plane credential is reachable from it.
- [ ] The existing delivery, worker gateway, artifact, pairing, and privacy suites still pass unchanged, proving no consumed contract moved.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` passes.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix format --check-formatted`, `python3 .agents/scripts/run_proof.py slice -- mix compile --warnings-as-errors`, `python3 .agents/scripts/run_proof.py slice -- mix credo --strict`, `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `python3 .agents/scripts/run_proof.py slice -- mix deps.audit`, and `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [ ] `python3 .agents/scripts/validate_spec.py specs/33-local-worker-run-execution`, `python3 .agents/scripts/validate_spec.py --all specs`, `python3 .agents/scripts/split_progress_log.py --check`, and `git diff --check` pass.
- [ ] Product, design, implementation, verification, and release readiness are recorded separately, and every resolved open question is written back before the slice is marked verified.

## Blocked Decisions

- None. The required-capability question is resolved in `requirements.md`: the worker honors the protocol's full required set and `specs/07-guided-specification-delivery` keeps its approved contract. No decision blocks product agreement, technical design, active implementation, or required verification.

## Progress Log

See [progress.md](progress.md).
