# Local Worker Runtime Governance Design

## Context

`specs/33-local-worker-run-execution` (`Verified`) launches Claude Code or Codex through `SddOrchestrator.Delivery.AgentAdapter` by resolving the coding agent's provider credentials "inside its own boundary, from the operator's existing local agent installation." It explicitly excludes `specs/11-ai-runtime-governance`, and its own tasks.md records the deferral by name: "a run funded by a personal AI connection, a pinned model and effort, an enforced spending ceiling, and ingested runtime observations."

`specs/11-ai-runtime-governance` (`Verified`) already delivers everything that deferred list needs as reusable capability: `SddOrchestrator.AIRuntime.PersonalConnections.resolve_working_agent_connection/2` resolves an eligible account-owned connection for the `:working_agent` consumer kind; `SddOrchestrator.AIRuntime.RuntimeSessions.pin_session/3` pins an immutable `AIRuntimeSession` from a connection, model, effort, opt-ins, and spending ceiling; `SddOrchestrator.AIRuntime.RuntimeObservations.ingest/3` appends one ordered `AgentRuntimeObservation` through a pluggable `ObservationAdapter` (default `RPC`, which queries the live Codex App Server process); and `SddOrchestrator.AIRuntime.RuntimeProjections` already derives an owner-exact and a participant-safe view, the latter authorized through the existing `capability:project-participation-boundary`. Its own design document names the exact gap this slice closes: "Future Slice 07 interface: consume `capability:ai-runtime-session` and `capability:ai-runtime-observation` only after an approved `update-spec` [that] defines manifest references, pause, resume, stop, cancellation, and continuation mapping."

The two contracts do not compose for free, and not only for the reason first assumed. `RuntimeObservations.ingest/3`'s default adapter drives a live App Server RPC session that has no relationship to the CLI subprocess `specs/33-local-worker-run-execution` actually launches; a local-worker run's real coding work never talks to that App Server at all. The deeper problem surfaces one layer down: `ObservationAdapter.validate_provenance/3`, the gate every call to `ingest/3` runs unconditionally, has exactly one accepting clause — `provider: "openai_codex"`, `source: "official_client"`, with a Codex-CLI-specific `source_version` pattern — and refuses everything else. No local-worker-sourced result, for either agent, can honestly claim that provenance; forging it would misrepresent where the fact came from, and `ingest/3` offers no other path into `AgentRuntimeObservation`. This is `specs/11-ai-runtime-governance`'s own authoritative validation for its own table, not a bug this slice may work around by editing it. Observing a local-worker run honestly means never writing an `AgentRuntimeObservation` row at all: sourcing elapsed time and status live from what the worker already knows about its own attempt, and presenting them next to — not through — the reused projection.

The accepted product scope keeps this slice to exactly that: attribution and observation, never enforcement. The worker's agent launch and credential resolution stay byte-for-byte what `specs/33-local-worker-run-execution` proved; the spending ceiling `specs/11-ai-runtime-governance` may still require to pin an API-key connection is recorded but not evaluated per turn in this slice.

## Proposed Approach

Add one small owned join surface, `LocalWorkerRunGovernance`, that references an `AgentRun` (`specs/07-guided-specification-delivery`'s "Run") and, when governed, the `AIRuntimeSession` pinned to it. This slice does not alter `agent_runs`, `AIRuntimeSession`, or any other provider's schema; it only adds its own row keyed by the run.

Extend the existing start-development action (`SddOrchestrator.Delivery.Start.start/4`) with an optional connection-selection step that runs before the command that tells the worker to start. It lists the initiator's personal AI connections filtered to the run's target device workspace's paired worker, auto-selects when exactly one is eligible, requires explicit choice otherwise, and does nothing when none is eligible. When a connection is confirmed, it calls `RuntimeSessions.pin_session/3` with `consumer: :working_agent` and a `consumer_ref` derived from the run's stable identity, then records the pinned session's reference on a new `LocalWorkerRunGovernance` row. A pin failure aborts the start before any worker command is issued; the run is never created half-governed.

Add one small, specs/34-owned function that computes a live runtime snapshot for a governed run entirely from data that already exists: `elapsed` from the referenced `AgentRun`'s own recorded start time (or its current attempt's, when one is running), `status` from the `AgentRun`/`RunAttempt` state `specs/33-local-worker-run-execution` and `specs/07-guided-specification-delivery` already maintain, and `tokens`/`cost` always `:unknown`. It reads; it writes nothing, opens no App Server connection, and never calls `RuntimeObservations.ingest/3` or `ObservationAdapter` — those stay exactly as `specs/11-ai-runtime-governance` shipped them, untouched and unextended.

Present the result next to the run's existing activity view by combining two independent reads: `RuntimeProjections.owner_projection/3` (for the run initiator and project owner) or `participant_projection/4` (for any other current authorized participant) for the pinned connection, model, effort, and quota — unaffected by the empty observation list they will always see for a local-worker session, since `list_observations/3` returning `[]` and `latest_observation/2` returning nothing are already-handled, ordinary cases those functions degrade to `:unknown` availability for — and the live snapshot above for elapsed time and status. An ungoverned run's activity renders no runtime projection at all, rather than an empty or zeroed one.

## Components Affected

- `SddOrchestrator.Delivery.Start`: gains the optional connection-selection and session-pinning step before a worker start command is issued.
- `SddOrchestrator.Delivery` (new module, e.g. `Delivery.LocalWorkerGovernance`): owns `LocalWorkerRunGovernance`, resolves eligible connections for a run's worker, computes the live runtime snapshot, and assembles the combined projection a governed run presents.
- The run's existing activity LiveView: renders the owner-exact or participant-safe runtime projection when the run is governed, and nothing when it is not.
- Consumed unchanged: `PersonalConnections.resolve_working_agent_connection/2`, `RuntimeSessions.pin_session/3`, `RuntimeProjections.owner_projection/3`, `RuntimeProjections.participant_projection/4`, and every `specs/33-local-worker-run-execution` worker, protocol, and agent-adapter surface. `RuntimeObservations.ingest/3` and `ObservationAdapter` are consumed by nothing this slice adds.

## Data and Access Boundaries

- `LocalWorkerRunGovernance`: one row per governed `AgentRun`, holding the run reference and the pinned `AIRuntimeSession` reference. Created at most once per run, only when a session is actually pinned, and never mutated afterward. A run's absence from this table is what "ungoverned" means; there is no separate boolean to fall out of sync with it.

Required boundaries:

- `LocalWorkerRunGovernance` never duplicates or redefines `AgentRun`, `AIRuntimeSession`, `PersonalAIConnection`, or `AgentRuntimeObservation` data; it only references stable identities, and the live runtime snapshot is computed on read, never persisted.
- Connection eligibility resolution is scoped to the run initiator's own account and the run's target device workspace's paired worker; it never lists or exposes another account's connections.
- The owner-exact projection is readable only by the run's current initiator and the project owner; the participant-safe projection is readable only by a current authorized project participant, exactly as `specs/11-ai-runtime-governance` already enforces.
- No repository content, absolute path, agent transcript, or provider credential is passed into the connection-selection request, the session's `consumer_ref`, or a computed runtime snapshot.
- `LocalWorkerRunGovernance` follows the same project-storage mode, retention, deletion, and rights lifecycle as the `AgentRun` it references; the live snapshot has no lifecycle of its own to govern because nothing about it is stored.

## Interfaces

- New: an optional pre-start step in the existing start-development action that resolves eligible connections, requires explicit choice when more than one exists, and pins a session before the worker start command is issued. Aborting on pin failure is part of this interface's contract, not a separate error path.
- New: a read-only runtime-snapshot function, internal to this slice, taking a governed run's own already-loaded state and returning `elapsed`/`status`/`tokens: :unknown`/`cost: :unknown`. It calls no other specification's interface and introduces no new public ingestion API.
- Unchanged: every `specs/33-local-worker-run-execution` worker protocol, command, event, and evidence contract. The worker is not told whether its run is governed and requires no change to observe or announce that state.
- Unchanged: every `specs/11-ai-runtime-governance` connection, catalog, quota, session, cost-ledger, and observation contract, including `RuntimeObservations.ingest/3` and `ObservationAdapter.validate_provenance/3`, neither of which this slice calls. This slice is a consumer, not a redefinition.

## Decisions and Tradeoffs

### A new owned join entity instead of extending `AgentRun` or `AIRuntimeSession`

- Choice: Add `LocalWorkerRunGovernance` as this slice's own record referencing both provider identities by value.
- Reason: The cross-specification capability rule forbids a consumer from redefining a provider's schema, interface, authoritative data, or lifecycle; `agent_runs` belongs to `specs/07-guided-specification-delivery` and `AIRuntimeSession` belongs to `specs/11-ai-runtime-governance`.
- Consequence: One additional lookup to learn whether a run is governed, in exchange for touching neither provider's table.

### A live computed snapshot instead of a persisted, ingested observation

- Choice: Compute a governed run's elapsed time and status on read, from the `AgentRun`/`RunAttempt` state that already exists, rather than writing an `AgentRuntimeObservation` row through `RuntimeObservations.ingest/3`.
- Reason: Two independent reasons converge on the same answer. `RPC`, the default `ObservationAdapter`, queries the live Codex App Server process, which has no relationship to the CLI subprocess a local worker actually launches. And more fundamentally, `ObservationAdapter.validate_provenance/3` — the gate `ingest/3` runs unconditionally — accepts only `provider: "openai_codex"`, `source: "official_client"` with a Codex-CLI-specific version pattern; a local-worker-sourced result cannot honestly claim that provenance for either agent, so a new adapter module would still fail at the door. Discovered while starting Task 3's implementation, before any code was written; corrected here rather than worked around in code.
- Consequence: Token and cost stay permanently unknown for a local-worker run in this slice, which is the same "unknown rather than guessed" rule `specs/11-ai-runtime-governance` already enforces everywhere else, applied honestly here instead of stretched to fit. No new dependency on `capability:ai-runtime-observation`'s ingestion path exists — only its projection functions, which already degrade gracefully to zero observations.

### Observation only, no launch or ceiling enforcement change

- Choice: Leave the worker's agent launch, credential resolution, and lifecycle authority untouched, and do not evaluate the spending ceiling against a local-worker run.
- Reason: Routing the agent subprocess's own authentication through the pinned connection's worker-local profile, or enforcing a ceiling the worker cannot observe per turn, is a materially larger change to `specs/33-local-worker-run-execution`'s approved credential-resolution rule than an attribution-and-observation bridge, and was explicitly declined for this slice.
- Consequence: A governed run's spending ceiling is recorded but not a safety boundary yet; a user can still overspend locally despite configuring one. This is an accepted, disclosed limitation of this slice, not a silent gap: `specs/33-local-worker-run-execution`'s activity and this slice's projection both continue to label the run by what actually happened, and enforcement remains explicit future work.

### Optional governance, not a required connection

- Choice: A run with no eligible connection starts and completes exactly as the unmodified `specs/33-local-worker-run-execution` baseline, labelled ungoverned.
- Reason: Making a connection mandatory now would block every Claude Code local-worker run today, since `specs/11-ai-runtime-governance` has no Claude Code usage or quota adapter yet, and would break the already-verified local-worker flow for a user without a configured connection.
- Consequence: Governance coverage depends on adoption; an ungoverned run is a normal, clearly labelled outcome in this slice, not a degraded state to hide.

### Session pinned per run, not per attempt

- Choice: Pin one immutable session per `AgentRun` and reuse it unchanged across that run's resume, retry, and reject-driven reattempts.
- Reason: `specs/07-guided-specification-delivery` already keeps the same run and branch across those transitions; only cancellation followed by a new start produces a new run.
- Consequence: `pin_session/3`'s existing idempotency on a repeated `consumer_ref` makes a resume or retry's re-pin attempt a safe no-op rather than new code this slice must add.

## Risks

- A local-worker run's real spend is not visible through the CLI subprocess path, so the live runtime snapshot's token and cost fields will always read unknown in this slice. Label this plainly in the projection and do not let a future change quietly guess a number to fill the gap.
- Recording but not enforcing a spending ceiling could be mistaken for protection. State the limitation in the run's own projection copy, not only in this design document, so a connection owner is not misled into believing the ceiling is already a safety boundary.
- A start-time connection-eligibility query that also touches worker-pairing state could race with a worker being repaired or revoked between listing and pinning. `pin_session/3` already re-validates the connection at pin time and fails closed; the eligibility list is advisory only and never itself authorizes anything.
- `LocalWorkerRunGovernance` could become a second source of truth for run state if it is read anywhere except to answer "is this run governed, and by which session." Keep its read surface to exactly that question.

## Open Questions

- None.
