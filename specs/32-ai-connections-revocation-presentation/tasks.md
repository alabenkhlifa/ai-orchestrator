# AI Connections Revocation Presentation Tasks

## Status

Not Started

The requirements are `Approved`, the required capability is ready, and every decision is resolved. Each suppressed panel collapses to the wording the screen already carries; a revoked connection stays listed until its existing deletion schedule removes it and says so; an indefinitely pending revocation states that new AI work is already denied while worker-local credential removal remains outstanding, naming no retry count or adapter error; each entry offers one plain sentence pointing at linking a replacement, with no control that re-enables a revoked connection; and the correction covers all four states in which the screen already refuses a refresh. The fix stays presentation only. Task 1 is executable.

## Active Slice

Make the account-level AI Connections screen agree with itself once a connection's revocation has been requested: suppress that connection's catalog and quota entitlement facts, state its own revocation state in their place using the wording the screen already carries, and explain on its entry what is no longer available, what the owner can do instead, and that a revoked reference is scheduled for removal.

## Cross-Specification Dependencies

Requires:

- `capability:ai-runtime-governance` — provider `specs/11-ai-runtime-governance#Task 6` — required before `Task 1`.

Provides:

- None.

## Slice Size Gate

- Slice size: Standard

The slice delivers one primary outcome through one screen and one verification gate. It contains two tasks and its longest `Depends on:` path contains two tasks.

## Task Size Gate

- Both tasks are `Size: Standard`. Each delivers one independently provable presentation outcome on one surface, owns three acceptance criteria and no data entity, and is expected to produce one task-boundary implementation commit with focused proof running in about ten minutes.
- The two surfaces are disjoint: the catalog and quota panels in the facts aside, and the connection's entry in the connections list. Each fails independently and is asserted independently.
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One derived per-connection presentation state inside `AIConnectionsLive`, used by both the refresh controls and the panel bodies.
- Model catalog and quota panel bodies that present the connection's revocation state instead of entitlement facts whenever the screen refuses a refresh for that connection.
- Skipping the stored catalog and quota projection reads for a connection whose panels will not present facts, including after a successful revocation request and for an asynchronous refresh result that arrives afterwards.
- A connections-list entry that names the revocation state, explains that rename and revocation are no longer available for that connection, names the corrective action, and states that a revoked reference is scheduled for removal.
- Extension of the existing focused LiveView proof and the existing desktop and mobile browser scenario.

Excluded:

- Every `specs/11-ai-runtime-governance` surface other than the screen it deferred here: the revocation lifecycle, credential-removal reconciliation and retry, the deletion schedule, the connection schema, the catalog and quota contexts, their adapters, their snapshots, their expiry sweep, and their retention and rights behavior.
- Any change to `ModelCatalogs.current_catalog/3` and `Quotas.current_quota/3`, their declared error unions, or their other callers.
- Any change to the owner-exact or participant-safe runtime-observation projections.
- Any new route, schema, migration, stored field, adapter, worker capability, or configuration value.
- Any change to `e2e_bootstrap_controller.ex` or the shared browser harness.

Deferred after this slice:

- None. This specification is itself the focused follow-up that `specs/11-ai-runtime-governance` deferred, and it carries no further deferral.

Release gates:

- None. Nothing here depends on deployment configuration, a packaged worker, a live provider, or an accountable review that the implementation contract does not already contain. Slice 11's own release gates are unaffected by this change.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Present the connection's own state in place of its catalog and quota facts.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Stop the screen from presenting entitlement facts that read as usable at the same moment it says the connection cannot be used, in every state where it already refuses a refresh, and make the correct copy it already carries reachable.
  - Owned surfaces: Derived per-connection presentation state shared by the refresh controls and the panel bodies, model catalog panel body, quota panel body, the stored catalog and quota projection reads inside the connection refresh path, asynchronous catalog and quota result handling for a connection whose revocation was requested, the refresh affordance in a suppressed panel, and the focused LiveView catalog and quota assertions.
  - Owns: AC-01, AC-02, AC-03
  - Proof: Focused LiveView tests seed a live catalog and quota through the existing responder, then drive each of the four refused states — revoking, revoked, unavailable, and incompatible — and assert that no model, reasoning-effort, provenance, bucket, reset, credit, paid-continuation, or token-activity value remains in either panel, that each panel states that connection's own state in the screen's existing wording, that no refresh affordance is offered, and that an asynchronous refresh result arriving after a revocation request restores nothing.

- [ ] Task 2 — Explain the connection's state and remaining options on its entry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Replace a silently disabled rename and revoke with an explanation the owner can act on, and say honestly what is still outstanding and what is scheduled to be removed.
  - Owned surfaces: Connections-list entry state explanation for every refused state, the unavailable-action explanation, the corrective-action line naming a replacement link, the outstanding worker-local credential-removal statement for an indefinitely pending revocation, and the focused LiveView connections-list assertions for those statements.
  - Owns: AC-04, AC-07
  - Proof: Focused LiveView tests assert that an entry in each refused state names that state and which actions are unavailable, that a revoking and a revoked entry name linking a replacement as the remaining action and offer no control that re-enables the revoked connection, and that a revocation left pending by an unreachable worker states both that new AI work is already denied and that worker-local credential removal remains outstanding, without presenting it as completed and without naming a retry count or adapter error.

- [ ] Task 3 — State the revoked reference's scheduled removal and prove the added copy stays safe.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2
  - Purpose: Tell the owner that a revoked reference is scheduled for removal without hiding a record that still exists, and prove that everything this slice added to the screen carries no forbidden value and stays usable on both supported layouts.
  - Owned surfaces: The revoked reference removal-schedule statement, the transition that stops listing a connection once the existing schedule removes the record, forbidden-value assertions covering every statement this slice adds, and the desktop and mobile AI Connections browser scenario.
  - Owns: AC-05, AC-06
  - Proof: Focused LiveView tests assert that a revoked entry states its scheduled removal, that a connection disappears from the list only once the record is actually gone rather than being hidden while it still exists, and that no suppressed panel, state message, corrective-action line, outstanding-removal statement, or schedule statement exposes a provider identity, plan detail, credential, worker reference, retry count, or raw adapter error. The desktop and mobile browser matrix runs at slice verification.

## Verification Gate

- [ ] AC-01 through AC-06 pass and no criterion or entity is deferred or release-classified.
- [ ] Every active acceptance criterion has exactly one primary task owner.
- [ ] Focused LiveView proof shows a populated catalog and quota panel emptying on revocation with no entitlement value left rendered, and an in-flight refresh result restoring nothing.
- [ ] The existing AI Connections LiveView, catalog, quota, personal-connection, revocation, projection, and privacy suites still pass unchanged, proving no Slice 11 contract moved.
- [ ] `ModelCatalogs.current_catalog/3` and `Quotas.current_quota/3` are unchanged in signature, declared error union, and behavior, and no other `specs/11-ai-runtime-governance` surface is modified.
- [ ] Desktop and mobile AI Connections browser scenarios prove the revoked-state panels, entry explanation, keyboard focus, viewport fit, and absence of provider identity and credential material, with no serious or critical accessibility violation.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` passes.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix format --check-formatted`, `python3 .agents/scripts/run_proof.py slice -- mix compile --warnings-as-errors`, `python3 .agents/scripts/run_proof.py slice -- mix credo --strict`, `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `python3 .agents/scripts/run_proof.py slice -- mix deps.audit`, and `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [ ] `python3 .agents/scripts/validate_spec.py specs/32-ai-connections-revocation-presentation`, `python3 .agents/scripts/validate_spec.py --all specs`, `python3 .agents/scripts/split_progress_log.py --check`, and `git diff --check` pass.
- [ ] Product, design, implementation, verification, and release readiness are recorded separately, and every resolved open question is written back before the slice is marked verified.

## Blocked Decisions

- None. All five product decisions are resolved and recorded in `requirements.md`, and the technical decision is settled in `design.md`: the read functions keep their current contracts and the correction stays presentation only, because changing `Quotas.current_quota/3` would alter approved AC-13 owner-projection behavior inside a `Verified` slice and would require an `update-spec` on `specs/11-ai-runtime-governance` that this specification has no authority to make.

## Progress Log

See [progress.md](progress.md).
