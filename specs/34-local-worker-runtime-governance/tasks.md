# Local Worker Runtime Governance Tasks

## Status

Not Started

Product readiness: `Approved`, no open product question — both accepted forks (observation-only enforcement, optional per-run connection) are recorded in `requirements.md`. Design readiness: `Approved`, no open technical question. Implementation readiness: not started. Verification readiness: not started, blocked on implementation. Release readiness: blocked on implementation and verification; this slice adds no new deployment-specific evidence beyond what `specs/33-local-worker-run-execution` and `specs/11-ai-runtime-governance` already require at their own release gates.

## Active Slice

Attribute a local-worker development run to one of the run initiator's own personal AI connections when one is eligible, pin an immutable runtime session to that run before the worker starts, observe the run's own lifecycle without contacting the Codex App Server, and present the result to the run initiator, project owner, and other current authorized participants — while leaving a run with no eligible connection running exactly as the already-verified `specs/33-local-worker-run-execution` baseline proves.

## Cross-Specification Dependencies

Requires:

- `capability:local-worker-run-execution` — provider `specs/33-local-worker-run-execution#Task 12` — required before `Task 1`.
- `capability:ai-runtime-session` — provider `specs/11-ai-runtime-governance#Task 11` — required before `Task 2`.
- `capability:ai-runtime-observation` — provider `specs/11-ai-runtime-governance#Task 5` — required before `Task 4`.

Provides:

- `capability:local-worker-runtime-governance` — ready after `Task 7`.

## Slice Size Gate

- Slice size: Standard

The slice delivers one coherent outcome through one verification gate: a local-worker run can be attributed, pinned, observed, and presented using capabilities `specs/33-local-worker-run-execution` and `specs/11-ai-runtime-governance` already ship, without either provider being redefined. It contains seven tasks and its longest `Depends on:` path contains five tasks, both well under the standard limits.

## Task Size Gate

- Every task is `Size: Standard`. Each delivers one independently provable outcome, owns at most three acceptance criteria and one data entity, and is expected to produce one task-boundary implementation commit with focused proof running in about ten minutes.
- Session pinning (Task 2) is separate from the observation adapter (Task 3) because one is a control-plane authorization and attribution surface and the other is a new provider-neutral observation source; they fail independently and neither depends on the other to be provable.
- Lifecycle-triggered ingestion (Task 4) is separate from the adapter it calls (Task 3) because the adapter's own fact-derivation and the dispatcher that decides when to call it are independently testable units.
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Eligible-connection resolution for a run's initiator, target device workspace, and configured worker agent, reusing `PersonalConnections.resolve_working_agent_connection/2` unchanged.
- An optional pre-start step in `SddOrchestrator.Delivery.Start` that auto-selects, requires explicit choice, or passes through ungoverned, and pins the session via `RuntimeSessions.pin_session/3` before any worker start command is issued.
- `LocalWorkerRunGovernance`, this slice's own record linking one `AgentRun` to its pinned `AIRuntimeSession` when governed.
- `SddOrchestrator.AIRuntime.ObservationAdapter.LocalWorker`, deriving elapsed time and status from the worker's own attempt lifecycle with tokens and cost always unknown.
- A lifecycle-transition dispatcher that ingests one ordered observation at workspace-ready, a progress heartbeat, verification-completed, and terminal state for a governed run only.
- Runtime-projection presentation next to the run's existing activity view, reusing `RuntimeProjections.owner_projection/3` and `participant_projection/4` unchanged.
- Privacy and security boundary proof for every new record and request shape this slice introduces.

Excluded:

- Any change to how the worker authenticates or launches the coding-agent subprocess, to `Delivery.AgentAdapter`, or to `specs/33-local-worker-run-execution`'s credential-resolution rule.
- Spending-ceiling reservation or quota-exhaustion pause evaluation against a local-worker run's execution.
- A Claude Code usage or quota adapter, or any other new `specs/11-ai-runtime-governance` provider adapter.
- Any change to `specs/07-guided-specification-delivery` or `specs/33-local-worker-run-execution`'s start, cancel, resume, retry, or reconcile authority.
- Project-shared or project-funded API connections and budgets.
- Remote, cloud-hosted, or non-local worker governance.

Deferred after this slice:

- Enforcing the recorded spending ceiling against a local-worker run's actual execution.
- Routing the agent subprocess's own provider authentication through the pinned connection's worker-local profile.
- A Claude Code usage or quota adapter, after which Claude Code local-worker runs gain real quota and cost facts instead of permanently unknown ones.
- Resume-after-quota-reset and explicitly approved linked continuation for a paused local-worker session.

Release gates:

- None beyond what `specs/33-local-worker-run-execution` and `specs/11-ai-runtime-governance` already require at their own release gates; this slice adds no new deployment-specific evidence.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Resolve and select an eligible personal AI connection when starting development.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give a participant starting development the connection choice `specs/11-ai-runtime-governance`'s runtime-session contract requires, without changing `specs/33-local-worker-run-execution`'s start path when no connection is eligible.
  - Owned surfaces: Eligible-connection resolution scoped to the initiator's own account and the run's target device workspace's paired worker, auto-selection when exactly one connection is eligible, required explicit choice when more than one is eligible, and unchanged pass-through when none is eligible.
  - Owns: AC-01
  - Proof: Focused tests prove auto-selection with exactly one eligible connection, required explicit choice with more than one, and an unchanged pass-through with none, all scoped to the initiator's own account and the run's target worker.

- [ ] Task 2 — Pin the run's runtime session before the worker is commanded to start.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Attribute a governed run to one immutable connection, model, and effort before any worker command exists for it, and refuse the start outright on a failed pin instead of starting it silently ungoverned.
  - Owned surfaces: `entity:LocalWorkerRunGovernance`, the `pin_session/3` call and its `consumer_ref` mapping from the run's stable identity, the start-refusal path on pin failure, and the recorded ungoverned state when no connection was selected.
  - Owns: AC-02, AC-03, AC-04, entity:LocalWorkerRunGovernance
  - Proof: Focused tests prove a confirmed connection is pinned and recorded before the worker start command is issued, that a resume, retry, or reject-driven reattempt on the same run reuses the same pinned session, that a pin failure refuses the start and issues no worker command, and that a run with no selected connection is recorded ungoverned and starts and completes exactly as the `specs/33-local-worker-run-execution` baseline.

- [ ] Task 3 — Implement the lifecycle-derived local-worker observation adapter.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Source an honest observation for a run whose real coding work never talks to the Codex App Server, instead of stretching the existing RPC adapter to a process it does not actually observe.
  - Owned surfaces: `ObservationAdapter.LocalWorker`, elapsed-time and status derivation from the worker's own attempt lifecycle state, the always-unknown token and cost fields, and attachment of the connection's most recent quota snapshot as informational context.
  - Owns: none
  - Proof: Focused tests prove elapsed time and status are derived only from the worker's attempt lifecycle, tokens and cost are always reported unknown, and the connection's most recently retrieved quota snapshot is attached without being presented as a per-run measurement.

- [ ] Task 4 — Ingest one ordered observation at each governed run's lifecycle transition.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 3
  - Purpose: Keep a governed run's observation trail current as its attempt actually progresses, and never ingest one for an ungoverned run.
  - Owned surfaces: The lifecycle-transition dispatcher calling `RuntimeObservations.ingest/3` with `ObservationAdapter.LocalWorker` at workspace-ready, a progress heartbeat, verification-completed, and terminal state.
  - Owns: AC-05
  - Proof: Focused tests prove one ordered observation is ingested at each of the four lifecycle transitions for a governed run, in sequence, and that no observation is ever ingested for an ungoverned run.

- [ ] Task 5 — Present the runtime projection next to a governed run's activity.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Let the run initiator, project owner, and other current authorized participants see exactly the view `specs/11-ai-runtime-governance`'s projection contracts already define, and see nothing for an ungoverned run.
  - Owned surfaces: The run activity view's owner-exact and participant-safe runtime-projection rendering, and its absence for an ungoverned run.
  - Owns: AC-06
  - Proof: Focused tests prove the run initiator and project owner see the owner-exact projection, another current authorized participant sees only the safe project-run view, and an ungoverned run's activity renders no projection.

- [ ] Task 6 — Enforce privacy boundaries over the new run-governance and observation records.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 4
  - Purpose: Prove the new surfaces this slice adds carry no repository content, credential, or unrelated identity, and inherit the referenced run's existing retention, deletion, and rights lifecycle rather than opening a new one.
  - Owned surfaces: Field-level allowlist proof for the connection-selection request, the session `consumer_ref`, and ingested observations; retention, deletion, and rights coverage confirmation for `entity:LocalWorkerRunGovernance` alongside its referenced run.
  - Owns: AC-07
  - Proof: Focused tests assert the absence of repository content, absolute paths, agent transcripts, and provider credentials across the new request, reference, and observation shapes, and that deleting or exporting the referenced run also covers its `LocalWorkerRunGovernance` row and observations.

- [ ] Task 7 — Prove one governed and one ungoverned local-worker run end to end, and publish the capability.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5, Task 6
  - Purpose: Show the whole bridge working on a real machine without regressing the already-verified ungoverned baseline, which is the outcome this slice exists for.
  - Owned surfaces: `capability:local-worker-runtime-governance`, the end-to-end governed-run scenario (selection, pin, worker execution, ingested observations, projection) and the end-to-end ungoverned-run scenario, both against a real local fixture repository.
  - Owns: AC-08
  - Proof: A focused integration scenario runs one governed and one ungoverned attempt against a real local fixture repository and asserts the governed run's session, observations, and projections are correct, the ungoverned run's behavior and control-plane writes are unchanged from the `specs/33-local-worker-run-execution` baseline, and the capability publishes only after both pass.

## Verification Gate

- [ ] Acceptance criteria pass
- [ ] Relevant automated tests pass
- [ ] Build and type checks pass
- [ ] Required manual scenario passes
- [ ] New decisions are written back
- [ ] Deferred work is recorded

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
