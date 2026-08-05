# AI Connections Revocation Presentation Tasks

## Status

Blocked

The required capability is ready and the technical approach is settled, but five product decisions and one technical decision are unresolved. Both tasks are blocked on them, so the slice is blocked on its next executable task. Nothing here is blocked on an unavailable dependency, an environment failure, or a missing implementation surface.

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

- [ ] Task 1 — Present the connection's revocation state in place of its catalog and quota facts.
  - Status: Blocked until the panel-treatment, refresh-state scope, and read-side eligibility decisions are made.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Stop the screen from presenting entitlement facts that read as usable at the same moment it says the connection is being revoked, and make the correct copy it already carries reachable.
  - Owned surfaces: Derived per-connection presentation state shared by the refresh controls and the panel bodies, model catalog panel body, quota panel body, the stored catalog and quota projection reads inside the connection refresh path, asynchronous catalog and quota result handling for a connection whose revocation was requested, the refresh affordance in a suppressed panel, and the focused LiveView catalog and quota assertions.
  - Owns: AC-01, AC-02, AC-03
  - Proof: Focused LiveView tests seed a live catalog and quota through the existing responder, request revocation, and assert that no model, reasoning-effort, provenance, bucket, reset, credit, paid-continuation, or token-activity value remains in either panel, that each panel states the connection's revocation state in the screen's existing wording, that no refresh affordance is offered, and that an asynchronous refresh result arriving after the request restores nothing.

- [ ] Task 2 — Explain the revoked connection's state and remaining options on its entry.
  - Status: Blocked until the listing, pending-worker wording, corrective-action, and refresh-state scope decisions are made.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Replace a silently disabled rename and revoke with an explanation the owner can act on, and say honestly what is still outstanding and what is scheduled to be removed.
  - Owned surfaces: Connections-list entry state explanation, the disabled rename and revoke explanation, the corrective-action line, the outstanding worker-local credential-removal statement, the revoked reference removal-schedule statement, forbidden-value assertions covering the added copy, the desktop and mobile AI Connections browser scenario, and the focused LiveView connections-list assertions.
  - Owns: AC-04, AC-05, AC-06
  - Proof: Focused LiveView tests assert that a revoking and a revoked entry name their state, explain that rename and revocation are unavailable, name the corrective action, state the scheduled removal for a revoked reference, and expose no provider identity, plan detail, credential, worker reference, retry count, or raw adapter error. The desktop and mobile browser matrix runs at slice verification.

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

- Panel treatment once revocation is requested: remove the panels, collapse each to the screen's existing revoking and revoked message, or keep them visible but inert. Recommended: collapse to the existing message. Blocks product requirements, then Task 1.
- Whether a revoked connection stays listed until its existing deletion schedule removes it, and whether the screen states that removal is scheduled. Recommended: yes to both. Blocks product requirements, then Task 2.
- What the screen says when a revocation stays pending because the paired worker is unreachable. Recommended: state that new AI work is already denied and that worker-local credential removal is still outstanding, with no retry count and no adapter error. Blocks product requirements, then Task 2.
- Whether the same correction covers the unavailable and incompatible states, which disable the same controls and leave the same panels populated. Recommended: yes, cover every state in which the screen already refuses a refresh. Blocks product requirements, then the scope of both tasks.
- What corrective action a revoking or revoked entry offers. Recommended: one sentence pointing at linking a replacement connection, with no control that re-enables the revoked one. Blocks product requirements, then Task 2.
- Whether `ModelCatalogs.current_catalog/3` and `Quotas.current_quota/3` also re-check eligibility on read. Recommended: no, keep the fix presentation only, because changing `current_quota/3` alters approved AC-13 owner-projection behavior in a `Verified` slice and would require an `update-spec` this specification has no authority to make. Blocks technical design, then both tasks.

## Progress Log

See [progress.md](progress.md).
