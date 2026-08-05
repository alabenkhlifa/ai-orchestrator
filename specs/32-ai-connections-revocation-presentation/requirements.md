# AI Connections Revocation Presentation

## Status

Draft

Five product decisions are unresolved and are recorded under `Open Questions`. The acceptance criteria state the recommended answer so the draft is specific enough to review, not because the answer is settled. Implementation must not begin until those questions are decided.

## Outcome

A connection owner who has asked to revoke a personal AI connection sees a screen that agrees with itself. The connection's model catalog and quota panels stop presenting entitlement facts that read as usable, each panel states that connection's own revocation state instead, and the connection's entry explains what is no longer possible and what the owner can do next.

## Users

- The connection owner: the signed-in individual who linked the personal AI connection and asked to revoke it. This screen is account-level and reaches no project, participant, or other account.

## In Scope

- Suppressing the per-connection model, reasoning-effort, catalog provenance, quota bucket, reset, credit, paid-continuation, and token-activity values on the account-level AI Connections screen once revocation has been requested or acknowledged.
- Making the screen's existing revoking and revoked panel wording reachable as a steady state instead of only as the outcome of a refresh the screen already prevents.
- Explaining, on the connection's own entry, why rename and revocation are no longer offered for it and what the owner can do instead.
- Stating that a revoked connection's opaque reference is scheduled for removal, and letting the existing schedule stop listing it.
- Extending the existing AI Connections LiveView proof and the existing desktop and mobile browser scenario rather than adding a parallel proof surface.

## Out of Scope

- The revocation lifecycle itself. The requested and acknowledged transitions, worker-local credential removal, its bounded acknowledgement, retry and reconciliation, the terminal deletion schedule, and account erasure stay owned by `specs/11-ai-runtime-governance`.
- Which connections may fund AI work. Refusal of a revoking or revoked connection is already enforced and proven at the runtime boundary and is not restated, duplicated, or re-implemented here.
- Stored model-catalog and quota snapshots, their lifetimes, their expiry sweep, their retention, and their rights export.
- Owner-exact and participant-safe runtime-observation projections and their consumers.
- Any new provider, worker, adapter, route, schema, migration, stored field, or configuration value.
- Linking, labelling, worker selection, and availability guidance for connections whose revocation has not been requested, except where an accepted answer to the scope question widens the same correction to the unavailable and incompatible states.

## Primary Workflow

1. The owner opens AI Connections holding at least one connection whose catalog and quota were refreshed recently enough that the stored projections have not expired, so its panels currently carry real entitlement facts.
2. The owner revokes one connection and confirms. New AI work on that connection is denied immediately.
3. The screen re-reads the account's connections. The revoked connection's badge changes, and its model catalog and quota panels stop presenting entitlement facts and state its revocation state instead.
4. The connection's entry in the list explains that it can no longer be renamed or revoked again and points at linking a replacement connection.
5. Once the paired worker acknowledges credential removal, the entry reports the revoked state and that the opaque reference is scheduled for removal.
6. When the existing schedule removes the record, the entry stops being listed and the panels stop showing it.

## Business Rules

- The screen must never present an entitlement fact as usable at the same moment it tells the owner that the connection cannot be used.
- Panel content and control availability are decided from one connection state, so a disabled refresh control and a populated panel can never disagree.
- The revoking and revoked wording the screen already carries is the wording used. No new state vocabulary is introduced for a state the screen already names.
- Suppression is presentation. It must not be described, implemented, or relied on as an access control. The enforcement that refuses a revoking or revoked connection stays exactly where it already is.
- A record that still exists is still listed. The screen does not hide a connection that the owner's right of access would still export.
- Nothing this screen adds may name a provider identity, provider account or workspace value, plan detail, credential, worker or worker-profile reference, credential-removal retry count, or raw adapter error.
- A catalog or quota refresh already in flight when revocation is requested must not restore suppressed facts when it returns.
- The screen states only what the system actually knows. A revocation that stays pending because the paired worker is unreachable must not be presented as completed credential removal.

## Acceptance Criteria

- [AC-01] Given a connection whose revocation has been requested or acknowledged and whose stored catalog or quota projection has not expired, when the owner opens or returns to AI Connections, then that connection's model catalog and quota panels present no model, reasoning-effort, catalog provenance, quota bucket, reset, credit, paid-continuation, or token-activity value.
- [AC-02] Given a connection whose revocation has been requested or acknowledged, when its catalog and quota panels render, then each panel states that connection's own revocation state using the screen's existing revoking and revoked wording and offers no control that implies the suppressed facts can be refreshed.
- [AC-03] Given a revocation request succeeds while the screen is open, when the screen updates, then that connection's panels collapse in the same update that reports the revocation result, and a catalog or quota refresh that was already in flight cannot restore the suppressed facts when it returns.
- [AC-04] Given a connection is being revoked or is revoked, when the owner reads its entry in the connections list, then the entry names that state, explains that rename and revocation are no longer available for it, and names the action the owner can still take.
- [AC-05] Given a revoked connection is still listed, when the owner reads its entry, then the screen states that its opaque reference is scheduled for removal and stops listing the connection once the existing schedule removes the record, without the screen hiding a record that still exists.
- [AC-06] Given any suppressed panel, revocation-state message, or removal-schedule statement renders, when the screen is inspected on the supported desktop and mobile layouts, then no provider identity, plan detail, credential, worker reference, retry count, or raw adapter error appears and the screen stays keyboard-usable inside both viewports.

## Open Questions

- Once revocation is requested, what replaces the connection's catalog and quota panels: removing them entirely, collapsing each to the screen's existing revoking and revoked message, or keeping them visible but visibly inert? Recommended: collapse each panel to the existing message, because it makes wording the screen already carries reachable, keeps the panel list parallel with the connections list, and removes the facts that read as usable, whereas removing the panels would make the panel list silently disagree with a connection the list still shows. Blocks: product requirements, then Task 1.
- Should a revoked connection stay listed until its existing deletion schedule removes it, and should the screen say that removal is scheduled? Recommended: yes to both, because the record still exists and the owner's right of access still exports it, so hiding it would make the screen disagree with the data, and the schedule is already enforced so stating it adds transparency without adding a stored fact. Blocks: product requirements, then Task 2.
- What should the screen say when a revocation request stays pending because the paired worker is unreachable and no credential removal has been acknowledged? Recommended: state that new AI work is already denied and that worker-local credential removal is still outstanding until the paired worker is reachable, naming no retry count and no adapter error, because "Revocation pending" alone reads as a transient delay while the owner's real question is whether the credential is gone, and the lifecycle deliberately leaves it pending rather than claiming a removal that did not happen. Blocks: product requirements, then Task 2.
- Should this correction also cover the unavailable and incompatible connection states, which disable the same refresh controls and leave the same panels populated? Recommended: yes, extend AC-01, AC-02, and AC-04 to every state in which the screen already refuses a refresh, because the identical contradiction and the identical unreachable wording exist for those two states and fixing two of four leaves the same defect in place. Blocks: product requirements, then the scope of Tasks 1 and 2.
- What corrective action, if any, should a revoking or revoked entry offer? Recommended: one plain sentence pointing at linking a replacement connection, with no control that re-enables the revoked one, because the workflow is required to show corrective actions and a disabled rename and revoke with no explanation is the gap, while re-enabling anything would contradict the rule that a connection is never rebound and the owner links a new one instead. Blocks: product requirements, then Task 2.
