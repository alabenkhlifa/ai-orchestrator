# AI Runtime Free Model Support

## Status

Draft

## Outcome

A deployment operator can publish an officially free provider model price that stays distinguishable from a missing one, and a user can run that model under a personal API-key spending ceiling without the ceiling ever losing its strict non-exceeding meaning or the runtime ever treating an unpriced model as free.

## Users

- Individual users who linked a personal API-key connection and want to run a model the provider publishes as free.
- The deployment operator who maintains the versioned official price registration every API-key reservation is calculated from.
- Authorized runtime consumers, including the connection owner inspecting one run's cost boundary.

## Primary Workflow

1. The operator publishes a versioned official price registration in which one or more models are declared explicitly free, carrying the same version, source, publication time, expiry time, and currency evidence as a priced model.
2. A user pins an API-key runtime session on that model with a personal spending ceiling, exactly as today.
3. Before the first chargeable turn, the runtime opens the session's ceiling state and records that the pinned model's current official price is a proven-free registration rather than an unknown one.
4. Each turn is authorized without allocating any of the remaining approved capacity and reconciles at zero, so the remaining capacity never moves.
5. If the free registration expires or is replaced by a priced registration, the run does not silently begin spending; it stops before the turn and reports a resumable condition.
6. The connection owner inspecting the run's projection sees an explicit free cost boundary rather than an unknown, zero, or unlimited one.

## In Scope

- An explicit proven-free declaration inside the existing versioned official price registration, with the same evidence and expiry lifecycle as a priced model.
- Continued refusal of a numeric zero unit price, a missing model, a missing price field, and an unconfigured registry.
- Cost-ledger state that records a free registration as proven-free price evidence rather than as an unknown price.
- Zero-allocation reservation, zero reconciliation, release, and abandoned-reservation recovery for a free turn.
- Fail-closed behavior when the free registration a session was reserving under expires or is replaced by a priced registration.
- An owner-visible runtime projection that states a free cost boundary explicitly.
- Privacy field-purpose, rights-export, retention, and minimization coverage for every field this slice adds.

## Out of Scope

- Presenting free-model facts in the AI Connections screen, Slice 07, or Slice 12. Those presentation surfaces stay with their owning specifications; Open Question 5 records the boundary decision.
- Discovering prices from a provider automatically. The registry stays operator-published and release-gated.
- ChatGPT-authenticated sessions, subscription quota buckets, scarce-model opt-ins, and provider-paid continuation.
- Provider billing, invoices, credit purchase, and any payment surface.
- Project-shared connections, project budgets, and project-funded per-run ceilings, which remain deferred with Slice 11's shared-funding work.
- Weakening any Slice 11 invariant that is not required to keep a proven-free price distinct from an unknown one.

## Business Rules

- A proven-free price and an unknown price must stay distinguishable at every layer that can authorize spending. Nothing in this slice may let an unpriced model behave as a free one.
- Free is a positive declaration the operator makes inside a versioned official registration. It carries the same version, source, publication time, expiry time, and currency evidence as a priced model, and it expires the same way.
- A unit price of exactly zero remains refused. A registration that expresses free as a numeric zero, or that mixes a free declaration with unit-price fields, is malformed.
- A malformed, unparseable, oversized, negative, or credential-shaped entry keeps invalidating the registry as a whole, so a registry that cannot be trusted anywhere is trusted nowhere. A malformed free declaration is such an entry.
- An unconfigured registry keeps refusing every reservation. Absence of pricing is never freeness.
- An officially free model does not remove the personal API-key spending ceiling. An API-key session keeps carrying an approved positive ceiling and currency, so a later priced turn always has an approved boundary to be measured against.
- A free turn allocates nothing from the remaining approved capacity and reconciles at zero. A nonzero observed cost reported against a free reservation is refused, because the reservation is still the only amount the ceiling ever authorized.
- The runtime must not silently begin spending under a price the session was not reserving under. A free registration that expires or becomes priced stops the next turn and pauses the run as a resumable condition.
- A priced registration that becomes free lowers the approved exposure and needs no new decision. It applies to the next turn without a pause.
- Freeness is a spend fact. It is visible to the connection owner, and the participant-safe projection continues to carry no cost fact at all.
- A free cost boundary must be projected as explicitly free. It must never be reported as unknown, and an unknown boundary must never be reported as free.
- Runtime cost data added by this slice stays inside the approved runtime purpose, its recorded lawful basis, its access boundary, and its existing retention window. It carries no provider invoice, payment credential, provider account identity, or raw provider error.

## Acceptance Criteria

- [AC-01] Given an operator publishes a versioned official registration that declares one model explicitly free, when a price is loaded for that model, then the free registration is returned as a proven price with its own version, source, publication, expiry, and currency evidence, while a numeric zero unit price, a free declaration mixed with unit-price fields, an unknown model, an unpublished registration, and an expired registration each keep failing closed.
- [AC-02] Given a registry contains one entry that is malformed, negative, unparseable, oversized, or credential-shaped, including a malformed free declaration, when any price is loaded, then the whole registry is refused and no reservation is authorized for any model, and an unconfigured registry still refuses every reservation.
- [AC-03] Given a session is pinned on a model whose current official registration is proven free, when its ceiling state is opened and its next bounded turn is reserved, then the turn is authorized while allocating nothing from the remaining approved capacity, and the ledger records proven-free price evidence rather than an unknown price.
- [AC-04] Given a free turn holds an outstanding reservation, when it is reconciled, released, or recovered as abandoned, then the observed cost is zero, the remaining approved capacity is unchanged, and a nonzero observed cost reported against that reservation is refused.
- [AC-05] Given a session has been reserving under a proven-free registration, when the next turn is evaluated after that registration expired or was replaced by a priced registration, then nothing is charged for that turn and the run reports a resumable pause naming the withdrawn free price, while a priced registration that became free applies to the next turn without a pause.
- [AC-06] Given an authorized connection owner requests the runtime projection of a session running under a proven-free registration, then its cost boundary is stated explicitly as free with its price evidence, an unopened or unknown boundary is still stated as unknown, and the participant-safe projection still carries no cost fact.

## Open Questions

1. Registration shape: should free be declared as an explicit per-model marker inside the same versioned official registration, rather than as a separate free-model allowlist or as a numeric zero? Recommended: one explicit marker inside the same registration, because it keeps a single price authority, a single expiry lifecycle, and a single release-gated configuration while leaving an accidental numeric zero refused. Blocks product requirements, then AC-01.
2. Ceiling state: should a free model still open the session's cost ledger and reserve zero, or bypass the ceiling entirely? Recommended: open the ledger and reserve zero, because bypassing it would report the run's cost boundary as unknown, which is exactly the free-versus-unknown conflation this slice removes, and it would fork the reconciliation, pause, retention, and rights paths. Blocks product requirements, then AC-03 and AC-06.
3. Ceiling requirement: should a free model be usable in an API-key session that carries no spending ceiling at all? Recommended: no, keep requiring an approved positive ceiling, because the pinned configuration is immutable while the registry is not, so a ceiling-free session would have no approved boundary left if its model ever became priced. Blocks product requirements, then AC-03.
4. Withdrawn free price: when a session's free registration expires or becomes priced, should the run pause for an explicit decision, or reserve at the new price when it fits inside the already-approved ceiling? Recommended: pause as a resumable condition, because Slice 11 already forbids silently continuing into paid provider usage and the user chose the model while it was published free. Blocks product requirements, then AC-05.
5. Visibility: should the user see that a model is free before selecting it? Recommended: not in this slice; publish the owner-visible contract here and leave the AI Connections, Slice 07, and Slice 12 presentation to the focused follow-up that already owns Slice 11's deferred presentation change, because it is an independently verifiable outcome with its own browser proof and this slice's outcome is provable without it. Blocks scope, then the deferred presentation specification.
6. Fail-closed radius: should one invalid registry entry keep invalidating the whole registry? Recommended: keep it unchanged, because it is a deliberate security property and the explicit free marker removes the operational reason to weaken it, since a free model no longer has to be registered as an invalid entry. Blocks risk acceptance, then AC-02.
