# AI Connections Revocation Presentation Design

## Context

`specs/11-ai-runtime-governance` is `Verified` and merged. Its Task 9 owns the account-level AI Connections workflow and AC-17; its Task 13 owns connection cleanup and credential-revocation reconciliation. Its implementation boundary defers exactly this correction to a focused follow-up specification, and its Task 6 review recorded the evidence. This specification is that follow-up. It changes no Slice 11 file that is not the screen Slice 11 deferred.

The finding, confirmed at the source. `AIConnectionsLive.refresh_connections/1` calls `ModelCatalogs.current_catalog/3` and `Quotas.current_quota/3` for every listed connection and is called again immediately after a successful revocation request. The two per-connection panel blocks are not filtered by revocation state, so the full model list, the reasoning-effort chips, and the provenance line keep rendering beside a "Revocation pending" badge. Only the badge changes and the two Refresh controls become disabled. The screen already carries the correct copy for the correct state, `"This connection is being revoked."` and `"This connection is revoked."`, in `catalog_error_message/1` and `quota_error_message/1`. That copy is unreachable, because only a live refresh attempt can produce those reasons and the disabled controls prevent the attempt.

What is not wrong, and what this specification must not claim is wrong. Slice 11's Task 6 classified this on evidence rather than assertion. The reader is the connection owner reading their own already-stored projection, inside its recorded purpose and inside its at-most-one-hour lifetime; both read functions scope the account, the connection, and the snapshot by account and connection identity, so no other party can reach it; the participant projection carries no quota key at all; and the projection can fund no work, because `PersonalConnections.resolve_for_consumer/3` and `ModelCatalogs.validate_selection/5` both refuse a `revoking` or `revoked` connection before anything else. This is a presentation-correctness defect on one screen, not a privacy, access, or enforcement defect.

The asymmetry that produces it. `ModelCatalogs.current_catalog/3` and `Quotas.current_quota/3` do not call their module's `eligible/1` predicate, while `prepare_refresh/3`, `persist/4`, and `validate_selection/5` all do. Their declared error unions are `:account_unavailable | :not_found | :unknown | :stale`, with no `:revoking` or `:revoked` member. That asymmetry is deliberate for a read of the owner's own stored record; whether to change it is the one open technical decision below.

## Proposed Approach

Derive one presentation state per connection inside the LiveView, from the same `revocation_state` and `availability` fields the two Refresh controls already read, and select the panel body from that state before any stored projection is consulted. A connection in a state the screen refuses to refresh yields the state message; a connection in the active and available state yields the existing fact rendering unchanged.

Because the panel body is chosen by state first, the stored projection for such a connection is never read into socket state and never reaches the rendered document, and an asynchronous refresh result that arrives after a revocation request cannot restore it. The state message reuses the wording `catalog_error_message/1` and `quota_error_message/1` already define, which turns dead copy into reachable copy rather than inventing a second vocabulary for the same state.

The connections-list entry then gains one short explanation of the same state: what is no longer available on that connection, what the owner can do instead, and, for a revoked connection, that its opaque reference is scheduled for removal. The entry keeps its existing badge, controls, and disabled conditions.

No context module, schema, migration, route, adapter, or configuration value changes. The two read functions keep their contracts under the recommended answer to the open technical question below.

## Components Affected

- `lib/sdd_orchestrator_web/live/ai_connections_live.ex`: the derived per-connection presentation state, the model catalog panel body, the quota panel body, the projection read inside `refresh_connections/1`, the asynchronous catalog and quota result handling, and the connections-list entry.
- `test/sdd_orchestrator_web/live/ai_connections_live_test.exs`: the existing focused LiveView proof, extended rather than duplicated.
- `assets/e2e/ai-connections.spec.js`: the existing desktop and mobile scenario, extended rather than duplicated.

Nothing else in `lib/`, no migration, and no test-support fixture is affected.

## Data and Access Boundaries

This specification introduces no data entity, stores no new field, and adds no new read of personal data. Every value it renders is already read by this screen for this owner today.

Required boundaries:

- Only the signed-in owning account reaches this screen, and every projection it reads is already scoped by account and connection identity. This change removes rendered values; it adds no reader and widens no scope.
- Suppression is presentation only. It is not an access control and must not be recorded, tested, or relied on as one. The authority that refuses a revoking or revoked connection stays in `PersonalConnections.resolve_for_consumer/3` and `ModelCatalogs.validate_selection/5`.
- The revocation lifecycle, its state vocabulary, its credential-removal reconciliation, and its deletion schedule remain owned by Slice 11. This specification reads those states and never writes, extends, or reinterprets them.
- The removal-schedule statement renders only the owner's own already-stored lifecycle timestamp. It must not surface a credential-removal attempt count, a typed failure reason, or any adapter text.
- No provider identity, provider account or workspace value, plan detail, credential, worker reference, or raw adapter error may appear in any string this change adds, and the existing forbidden-value assertions must cover the new copy.

## Interfaces

- `ModelCatalogs.current_catalog/3` keeps its signature and its declared error union. Its only caller inside `lib/` is this screen.
- `Quotas.current_quota/3` keeps its signature and its declared error union. Besides this screen it is called by `QuotaPolicy` and by `RuntimeProjections.owner_projection/3`, so its contract is not this specification's to change.
- `PersonalConnections.list_connections/1` keeps returning every connection the account owns in every revocation state. The screen continues to list what the record set contains.
- `capability:ai-runtime-governance` is consumed unchanged. This screen stays inside the fail-closed purpose and recipient routes that capability declares, and this change only narrows what is presented.
- No new capability is provided. A presentation correction publishes nothing downstream.

## Decisions and Tradeoffs

### One Derived Connection State Drives Both The Control And The Panel

- Choice: Compute one presentation state per connection from `revocation_state` and `availability` and use it for both the Refresh control's disabled condition and the panel body selection.
- Reason: The defect exists precisely because two places independently decided the same question and disagreed. A single derivation makes the contradiction unrepresentable rather than merely corrected once.
- Consequence: The disabled condition moves behind the derivation, so any later state added to either vocabulary must be classified once instead of in two places.

### Reuse The Existing Revoking And Revoked Copy

- Choice: Render the wording `catalog_error_message/1` and `quota_error_message/1` already define for `:revoking` and `:revoked` instead of writing new panel copy.
- Reason: The screen's copy for the correct state is already written, reviewed, and shipped; it is only unreachable. Reaching it is the smaller and more honest change, and it keeps one vocabulary for one state.
- Consequence: The two helpers now serve both a transient refresh outcome and a steady state, so their wording must stay true in both readings.

### Do Not Read A Projection The Screen Will Not Present

- Choice: Skip the `current_catalog/3` and `current_quota/3` reads for a connection whose panels will show the state message, rather than reading and then filtering at render time.
- Reason: The entitlement facts then never enter socket state or the rendered document, which is a stronger guarantee than a render-time filter and removes a query that could not be used. It also makes an in-flight asynchronous result harmless, because the panel body no longer depends on the projection map for that connection.
- Consequence: The projection maps are sparse. Any later reader of those assigns must treat an absent entry as "not presented" rather than as "unknown".

### Prove Fact Absence In The LiveView Test And State Collapse In The Browser

- Choice: Prove the absence of real entitlement facts in the focused LiveView test, where a live catalog and quota can be produced through the existing responder before revocation, and prove the collapsed state on desktop and mobile through the existing browser scenario, which already links and revokes a connection.
- Reason: The browser harness negotiates only the `connection/1` capability and answers every request with a connection-shaped result, while the catalog and quota adapters require `catalog/1` and `quota/1`. No catalog or quota snapshot can therefore exist in a browser run, and making one exist would mean extending `e2e_bootstrap_controller.ex`, a known recurring cross-slice conflict surface, for proof the LiveView test already gives more precisely.
- Consequence: The browser matrix proves that the panels present the revocation state and no refresh affordance on both viewports; it does not prove that a populated panel emptied. That stronger claim lives in the focused proof.

### Presentation Only, Leaving The Read Contracts Alone

- Choice: Correct the screen and leave `current_catalog/3` and `current_quota/3` unchanged, pending the open question below.
- Reason: The behavior that must fail closed already fails closed at the enforcement boundary and is proven there. Adding eligibility to `current_quota/3` would change `RuntimeProjections.owner_projection/3`, which is approved AC-13 behavior inside a `Verified` slice, so it is not a change this specification has authority to make.
- Consequence: The two read functions keep an asymmetry with `prepare_refresh/3`, `persist/4`, and `validate_selection/5`. That asymmetry is documented here so a later reader does not mistake it for an oversight.

## Risks

- A later panel or control could be added without consulting the derived state and reintroduce the same contradiction. Keep the derivation the only source for both, and assert in the focused proof that a suppressed panel exposes no fact rather than asserting one message string.
- Suppression could be mistaken for an access control by a later reader or reviewer. State the opposite explicitly in the module documentation and in this design, and keep the enforcement proof where it already is.
- The removal-schedule statement could drift into reporting credential-removal internals. Render only the schedule timestamp and extend the existing forbidden-value assertions to the new copy.
- Collapsing a panel changes its height and the aside's layout on small viewports. Keep the existing desktop and mobile viewport and accessibility scenarios covering the revoked state.
- An accepted answer widening the correction to the unavailable and incompatible states would widen three acceptance criteria without adding a task. Confirm the widened scope in the same decision set rather than discovering it during implementation.

## Open Questions

- None. Resolved: `ModelCatalogs.current_catalog/3` and `Quotas.current_quota/3` keep their current contracts and do not re-check connection eligibility on read; the correction is presentation only. `current_catalog/3` has exactly one caller inside `lib/`, this screen, so changing it would buy nothing the presentation fix does not already give. `current_quota/3` has two further callers: `QuotaPolicy`, where the effect would be inert because it already refuses a revoking connection earlier, and `RuntimeProjections.owner_projection/3`, where a run pinned to a connection whose revocation was just requested would silently drop from real account-wide quota facts to `unknown`. That is approved AC-13 behavior inside a `Verified` slice, so changing it would require an `update-spec` on `specs/11-ai-runtime-governance` that this specification has no authority to make.
