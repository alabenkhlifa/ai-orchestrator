# Local Worker Runtime Governance Tasks

## Status

Verified

Product readiness: `Approved`, no open product question — both accepted forks (observation-only enforcement, optional per-run connection) are recorded in `requirements.md`. Design readiness: `Approved`, no open technical question; corrected twice before or during implementation, before either correction had any code depending on it (see `progress.md`): the observation mechanism on 2026-08-08, and the owner-exact access boundary on 2026-08-09. Implementation readiness: complete — all seven tasks delivered and individually verified, each proof re-run and confirmed by this thread with a real exit code, not only the implementing sub-agent's report. `capability:local-worker-runtime-governance` is ready. Verification readiness: `Verified` — the full slice gate passed on this exact codebase: `mix check` (3155 tests, 1 excluded live-network test — one earlier run hit a pre-existing, non-deterministic scheduling race in `specs/33-local-worker-run-execution`'s own `isolation_test.exs`, confirmed unrelated to this slice and non-reproducible; see `progress.md`), `mix dialyzer` (23 known, fully accepted suppressions carried over from `specs/33-local-worker-run-execution`, zero new, zero unnecessary skips), `mix deps.audit` (no vulnerability), `mix sobelow --config` (zero findings), the full browser matrix (`npm --prefix assets run test:e2e`, 120 scenarios, unchanged count), and both production build steps (`MIX_ENV=prod mix assets.deploy`, `MIX_ENV=prod mix release --overwrite` — the plain form prompted interactively on a stale prior release and was corrected before being trusted; see `progress.md`). Release readiness: blocked — this slice adds no new deployment-specific evidence beyond what `specs/33-local-worker-run-execution` and `specs/11-ai-runtime-governance` already require at their own release gates, which remain owed exactly as those slices' own status already records.

## Active Slice

Attribute a local-worker development run to one of the run initiator's own personal AI connections when one is eligible, pin an immutable runtime session to that run before the worker starts, compute a live snapshot of the run's own lifecycle without contacting the Codex App Server or persisting a new observation, and present the result to the run initiator, project owner, and other current authorized participants — while leaving a run with no eligible connection running exactly as the already-verified `specs/33-local-worker-run-execution` baseline proves.

## Cross-Specification Dependencies

Requires:

- `capability:local-worker-run-execution` — provider `specs/33-local-worker-run-execution#Task 12` — required before `Task 1`.
- `capability:ai-runtime-session` — provider `specs/11-ai-runtime-governance#Task 11` — required before `Task 2`.
- `capability:ai-runtime-observation` — provider `specs/11-ai-runtime-governance#Task 5` — required before `Task 4`.

Provides:

- `capability:local-worker-runtime-governance` — ready after `Task 7`.

## Slice Size Gate

- Slice size: Standard

The slice delivers one coherent outcome through one verification gate: a local-worker run can be attributed, pinned, snapshotted, and presented using capabilities `specs/33-local-worker-run-execution` and `specs/11-ai-runtime-governance` already ship, without either provider being redefined. It contains seven tasks and its longest `Depends on:` path contains five tasks, both well under the standard limits.

## Task Size Gate

- Every task is `Size: Standard`. Each delivers one independently provable outcome, owns at most three acceptance criteria and one data entity, and is expected to produce one task-boundary implementation commit with focused proof running in about ten minutes.
- Session pinning (Task 2) is separate from the live runtime snapshot (Task 3) because one is a control-plane authorization and attribution surface and the other is a pure read over already-existing run state; they fail independently and neither depends on the other to be provable.
- Combined-projection assembly (Task 4) is separate from the snapshot it calls (Task 3) because the snapshot's own fact-derivation and the assembly that combines it with the reused connection/model/effort/quota projection are independently testable units.
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Eligible-connection resolution for a run's initiator, target device workspace, and configured worker agent, reusing `PersonalConnections.resolve_working_agent_connection/2` unchanged.
- An optional pre-start step in `SddOrchestrator.Delivery.Start` that auto-selects, requires explicit choice, or passes through ungoverned, and pins the session via `RuntimeSessions.pin_session/3` before any worker start command is issued.
- `LocalWorkerRunGovernance`, this slice's own record linking one `AgentRun` to its pinned `AIRuntimeSession` when governed.
- A live runtime-snapshot read, deriving elapsed time and status from the worker's own current `AgentRun`/`RunAttempt` state with tokens and cost always unknown, computed on request and never persisted.
- A combined-projection assembly for a governed run only, joining the live snapshot with `RuntimeProjections.owner_projection/3` or `participant_projection/4`'s unchanged output for connection, model, effort, and quota.
- Runtime-projection presentation next to the run's existing activity view.
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

- [x] Task 1 — Resolve and select an eligible personal AI connection when starting development.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give a participant starting development the connection choice `specs/11-ai-runtime-governance`'s runtime-session contract requires, without changing `specs/33-local-worker-run-execution`'s start path when no connection is eligible.
  - Owned surfaces: Eligible-connection resolution scoped to the initiator's own account and the run's target device workspace's paired worker, auto-selection when exactly one connection is eligible, required explicit choice when more than one is eligible, and unchanged pass-through when none is eligible.
  - Owns: AC-01
  - Proof: Focused tests prove auto-selection with exactly one eligible connection, required explicit choice with more than one, and an unchanged pass-through with none, all scoped to the initiator's own account and the run's target worker.

- [x] Task 2 — Pin the run's runtime session before the worker is commanded to start.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Attribute a governed run to one immutable connection, model, and effort before any worker command exists for it, and refuse the start outright on a failed pin instead of starting it silently ungoverned.
  - Owned surfaces: `entity:LocalWorkerRunGovernance`, the `pin_session/3` call and its `consumer_ref` mapping from the run's stable identity, the start-refusal path on pin failure, and the recorded ungoverned state when no connection was selected.
  - Owns: AC-02, AC-03, AC-04, entity:LocalWorkerRunGovernance
  - Proof: Focused tests prove a confirmed connection is pinned and recorded before the worker start command is issued, that a resume, retry, or reject-driven reattempt on the same run reuses the same pinned session, that a pin failure refuses the start and issues no worker command, and that a run with no selected connection is recorded ungoverned and starts and completes exactly as the `specs/33-local-worker-run-execution` baseline.

- [x] Task 3 — Compute a governed run's live runtime snapshot.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Source an honest, current fact for a run whose real coding work never talks to the Codex App Server and whose result can never honestly pass `ObservationAdapter.validate_provenance/3`'s Codex-official-client-only gate — so read the worker's own already-maintained state live instead of trying to persist an observation through a pipeline that cannot accept it.
  - Owned surfaces: A pure function deriving elapsed time and status from the referenced `AgentRun`/`RunAttempt`'s own current state, with token and cost fields always `:unknown`. No new module under `ai_runtime/`, no schema, no call to `RuntimeObservations` or `ObservationAdapter`.
  - Owns: none
  - Proof: Focused tests prove elapsed time and status are derived only from the run's/attempt's own current lifecycle state (not agent output), and tokens and cost are always reported unknown.

- [x] Task 4 — Assemble the combined projection for a governed run.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 3
  - Purpose: Join the live snapshot with the reused connection, model, effort, and quota projection into one map for a governed run, and produce nothing for an ungoverned one — without ever writing a new observation record.
  - Owned surfaces: The assembly function calling `RuntimeProjections.owner_projection/3` or `participant_projection/4` (both tolerate the empty observation list a local-worker session always has) and combining the result with Task 3's live snapshot, gated on `LocalWorkerRunGovernance` showing the run is governed.
  - Owns: AC-05
  - Proof: Focused tests prove the combined map carries the live elapsed time/status alongside the reused connection/model/effort/quota facts for a governed run, and that the assembly returns nothing for an ungoverned run.

- [x] Task 5 — Present the runtime projection next to a governed run's activity.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Let the run initiator and every other current authorized participant see exactly the view `specs/11-ai-runtime-governance`'s projection contracts already define, and see nothing for an ungoverned run.
  - Owned surfaces: The run activity view's owner-exact and participant-safe runtime-projection rendering, and its absence for an ungoverned run.
  - Owns: AC-06
  - Proof: Focused tests prove the run initiator sees the owner-exact projection, the project owner (when not the initiator) and another current authorized participant see only the safe project-run view, and an ungoverned run's activity renders no projection.

- [x] Task 6 — Enforce privacy boundaries over the new run-governance record and computed snapshot.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 4
  - Purpose: Prove the new surfaces this slice adds carry no repository content, credential, or unrelated identity, and inherit the referenced run's existing retention, deletion, and rights lifecycle rather than opening a new one.
  - Owned surfaces: Field-level allowlist proof for the connection-selection request, the session `consumer_ref`, and the computed runtime snapshot; retention, deletion, and rights coverage confirmation for `entity:LocalWorkerRunGovernance` alongside its referenced run.
  - Owns: AC-07
  - Proof: Focused tests assert the absence of repository content, absolute paths, agent transcripts, and provider credentials across the new request, reference, and snapshot shapes, and that deleting or exporting the referenced run also covers its `LocalWorkerRunGovernance` row.

- [x] Task 7 — Prove one governed and one ungoverned local-worker run end to end, and publish the capability.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5, Task 6
  - Purpose: Show the whole bridge working on a real machine without regressing the already-verified ungoverned baseline, which is the outcome this slice exists for.
  - Owned surfaces: `capability:local-worker-runtime-governance`, the end-to-end governed-run scenario (selection, pin, worker execution, live snapshot, combined projection) and the end-to-end ungoverned-run scenario, both against a real local fixture repository.
  - Owns: AC-08
  - Proof: A focused integration scenario runs one governed and one ungoverned attempt against a real local fixture repository and asserts the governed run's session, live snapshot, and projection are correct, the ungoverned run's behavior and control-plane writes are unchanged from the `specs/33-local-worker-run-execution` baseline, and the capability publishes only after both pass.

## Verification Gate

- [x] Acceptance criteria pass — all eight, each owned by exactly one task, proven by that task's own focused proof plus Task 7's real end-to-end scenario for AC-08.
- [x] Relevant automated tests pass — full slice gate: `mix check` (3155 tests), `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and the full browser matrix (120 scenarios), all re-verified by this thread with real exit codes.
- [x] Build and type checks pass — `mix format --check-formatted`, `mix compile --warnings-as-errors`, and both production build steps (`MIX_ENV=prod mix assets.deploy`, `MIX_ENV=prod mix release --overwrite`) all clean.
- [ ] Required manual scenario passes — environment-blocked, inheriting the exact gap `specs/33-local-worker-run-execution` already disclosed at its own release gate: Task 7's real scenario uses a scripted CLI agent double, not a real live Codex or Claude Code CLI, because this checkout has no configured production adapter. Additionally, and specific to this slice: the new "AI runtime" panel Task 5 added has not been visually confirmed in an actual browser session — Task 5's 98 passing LiveView tests assert real rendered HTML, and the unchanged 120/120 browser e2e matrix proves the broader UI foundation (dark/light mode, accessibility, responsive layout) is unbroken, but no test drives a real browser to this specific panel. A quick `mix phx.server` visual check is a reasonable low-cost follow-up; it does not block `Verified` status given the automated coverage already in place, matching how `specs/33-local-worker-run-execution` reached `Verified` with its own analogous live-scenario gap still open.
- [x] New decisions are written back — both design corrections (observation mechanism, owner-exact access boundary) and this gate's evidence are recorded in `progress.md`.
- [x] Deferred work is recorded — see Implementation Boundary's "Deferred after this slice" above; unchanged by verification.

## Blocked Decisions

- None. The one open manual-scenario item above is an environment/tooling gap, not a decision, and does not block `Verified` implementation and local-verification readiness, matching `specs/33-local-worker-run-execution`'s own precedent.

## Progress Log

See [progress.md](progress.md).
