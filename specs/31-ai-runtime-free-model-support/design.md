# AI Runtime Free Model Support Design

## Context

Slice 11 enforces every personal API-key spending ceiling by reserving a conservative maximum before each chargeable turn and reconciling it afterward. The reservation is calculated from a versioned official price registry that is deliberately fail-closed in four ways, all of which are already implemented and proven:

- `SddOrchestrator.AIRuntime.RuntimeCosts.PriceSnapshot` refuses a unit price of exactly zero, because a zero is indistinguishable from a missing, truncated, or unparsed value.
- Its per-entry normalization runs through a halting reducer, so one invalid entry makes the whole registry untrustworthy and refuses every reservation deployment-wide rather than only its own model.
- `SddOrchestrator.AIRuntime.RuntimeCostLedger` repeats the strictly-positive unit-price rule in its changeset, and the `runtime_cost_ledgers_price_check` database constraint repeats it again, so a zero unit price cannot even be stored beside the ceiling it authorized.
- The registry defaults to empty, so an unconfigured deployment refuses everything and the deployment's real price source stays in Slice 11's release gate.

The consequence is recorded in Slice 11's design and task plan: an officially free model cannot be used under an API-key ceiling, and registering one would refuse every reservation for every model. Slice 11 defers the fix and names what it needs, namely a way to register a proven-free price that stays distinct from an unknown one together with its reservation, reconciliation, and ceiling proof.

Two neighbouring behaviors are already compatible and need no change. `agent_runtime_observations_cost_check` already admits an estimated cost of zero, so a free turn's observation is storable today. `SddOrchestrator.AIRuntime.RuntimeProjections` already separates an absent boundary from a real one, reporting an unopened ledger as unknown and a ChatGPT session's absent ceiling as not applicable, which is the shape a third free state has to join rather than blur.

## Proposed Approach

Make freeness a positive declaration that travels with the price rather than a numeric value that has to be inferred.

In the registry, a model is registered either as a priced model with the current exact input and output unit-price pair, or as a free model with one explicit free marker and no unit-price fields at all. Anything else, including a numeric zero, a negative value, a free marker combined with unit-price fields, or an unrecognized marker, stays malformed and keeps invalidating the whole registry. A free registration is otherwise an ordinary registration: it belongs to a versioned snapshot, carries the same source, publication time, expiry time, and currency, and expires the same way. The loaded price value gains one pricing mode so that every caller downstream receives freeness as data instead of deriving it from an amount.

In the ledger, the same pricing mode is persisted beside the price evidence it came from, and the strictly-positive unit-price rule is replaced by a paired rule in the changeset and in the database: a priced ledger must carry strictly positive unit prices, and a free ledger must carry unit prices of exactly zero. A zero unit price therefore remains impossible except in the one state that explicitly declares it, which is what keeps a proven-free ledger distinct from a corrupted one.

The reservation path is otherwise unchanged. A free turn computes a conservative maximum of zero from bounded request inputs that are still validated, allocates a zero-amount reservation entry under its idempotency key, and leaves the remaining approved capacity untouched. Because the entry exists, idempotent replay, duplicate-key refusal, release, abandoned-reservation recovery, and the capacity invariant all keep working with no special case. Reconciliation needs no new rule either: the existing guard that refuses an observed cost above its own reservation already means that the only cost a free reservation can settle at is zero.

The one genuinely new decision is the transition. A session that has been reserving under a free registration and then finds the current registration priced must not quietly start charging. The reservation path compares the ledger's persisted pricing mode with the mode of the price it just resolved and, when free has become priced, allocates nothing and records a resumable pause naming the withdrawn free price. The opposite transition lowers exposure and proceeds. An expired free registration keeps failing closed as a stale price exactly as a priced one does.

Finally, the owner projection reports the boundary as explicitly free with its price evidence, joining the unknown and not-applicable states rather than collapsing into them. The participant-safe projection is untouched and still carries no cost fact.

## Components Affected

- Versioned official price registry and its loaded price value.
- Conservative-maximum calculation for a bounded turn.
- Cost-ledger schema, changeset, and database price and pause constraints.
- Cost-reservation boundary: open, reserve, reconcile, release, and abandoned-reservation recovery.
- Runtime-cost projection and the owner-exact runtime observation projection.
- Privacy processing inventory, field-purpose map, and rights export allowlist for the cost ledger.
- Runtime cost fixtures and the existing focused cost proof.
- Deployment price-source configuration evidence in the release gate.

## Data and Access Boundaries

This slice introduces no new record. It extends two records that Slice 11 owns and remains a consumer of their contracts: the API-key cost ledger gains one pricing mode beside the price evidence it already stores, and the pinned runtime session is unchanged. Slice 11 stays the authority for the ceiling contract, the session pin, and their lifecycles; every invariant it proved stays in force and is re-proved here against the extended shape. The price registry itself is deployment configuration rather than personal data: it holds published official prices, no account reference, and no provider credential.

Required boundaries:

- The pricing mode is derived only from an operator-published official registration. No provider response, worker observation, model output, or user input can set it.
- A ledger row may hold zero unit prices only while its pricing mode declares free, and strictly positive unit prices only while it declares priced. The database enforces the pair, so a corrupted or partially written row is refused rather than read as free.
- The added field is minimized operational cost data. It carries no invoice, payment credential, provider account identity, or raw provider error, and it inherits the ledger's recorded purpose, lawful basis, access boundary, and retention window.
- Freeness is a spend fact and stays inside the connection-owner access boundary. The participant-safe projection continues to expose no cost, price, ceiling, or pricing-mode value.
- The field-purpose map and the rights-export allowlist are both proven equal to the ledger schema's own fields, so the added field must be given a recorded purpose and an export decision in the same change that adds it.

## Interfaces

- Price registry: accepts a per-model registration that is either an exact priced pair or an exact free declaration, returns a price value carrying its pricing mode alongside the existing version, source, publication, expiry, and currency evidence, and keeps returning one fail-closed refusal for a missing, unpublished, malformed, or untrustworthy registry and one for an expired registration.
- Conservative maximum: returns zero for a free price while still validating and refusing an out-of-range bounded token count, so an invalid request stays invalid whether or not the model is free.
- Cost-reservation boundary: unchanged signatures. Opening a ledger for a free model succeeds, reserving allocates a zero-amount entry, reconciling accepts only zero, releasing and recovering behave as today, and remaining capacity is reported unchanged.
- Pause vocabulary: gains one resumable reason for a withdrawn free price, admitted by the ledger schema and the database pause constraint and mapped by the projection, so an unrecognized reason still cannot be produced or read.
- Owner runtime projection: the cost boundary reports an explicit free state with its price evidence beside the existing unknown and not-applicable states, and the participant-safe projection is unchanged.
- Slice 11 capability contracts: `capability:ai-runtime-session`, `capability:ai-runtime-observation`, and `capability:ai-runtime-governance` are consumed. Their existing shapes are extended additively, never redefined, and no consumer that ignores the pricing mode changes behavior.

## Decisions and Tradeoffs

### Freeness Is A Declaration, Not An Amount

- Choice: Register a free model as an exact single free marker with no unit-price fields, and keep refusing a numeric zero anywhere in the registry.
- Reason: The whole difficulty is that a zero can arrive from a typo, a truncated decimal, a dropped field, or a failed parse. A marker cannot arrive by accident, so it is the only encoding under which free and unknown stay separable.
- Consequence: An operator cannot express free by writing zeros, and the registration format gains one shape that has to be documented in the release-gated price-source evidence.

### The Pricing Mode Is Persisted, Not Recomputed

- Choice: Store the pricing mode on the ledger beside the price evidence, and pair it with the unit-price rule in both the changeset and the database.
- Reason: The reservation path must be able to tell, later and under a row lock, what the session had been reserving under. Recomputing it from a stored amount would reintroduce exactly the inference this slice removes.
- Consequence: One migration alters the ledger price constraint from a strictly-positive rule to a paired rule and adds the mode column. A zero unit price stays impossible in every state except the declared one.

### A Free Turn Still Reserves

- Choice: Open the ledger and allocate a zero-amount reservation entry rather than bypassing the ceiling for free models.
- Reason: The entry is what makes idempotent replay, duplicate-key refusal, release, abandoned recovery, the reservation-sum invariant, and the projection work without a second code path, and a bypassed ledger would report the run's boundary as unknown.
- Consequence: A free run holds ordinary ledger rows and reservation entries whose amounts are zero, and the outstanding-reservation limit applies to it as it does to any other run.

### Reconciliation Needs No New Rule

- Choice: Rely on the existing refusal of an observed cost above its own reservation instead of adding a free-specific reconciliation rule.
- Reason: A free reservation authorized zero, so that guard already accepts only zero and already refuses any nonzero settlement as an over-reconciliation.
- Consequence: If a model registered free ever produced a real charge, the runtime refuses to absorb it silently. The turn cannot be settled, the reservation is released by abandoned recovery rather than charged, and the discrepancy surfaces as a refusal rather than as a quiet ceiling movement.

### Withdrawn Freeness Pauses Instead Of Charging

- Choice: When the ledger's persisted mode is free and the newly resolved price is priced, allocate nothing and pause with a distinct resumable reason; allow the opposite transition to proceed.
- Reason: Slice 11 already forbids silently continuing into paid provider usage, and the user selected the model while it was published free. The reverse transition only lowers exposure.
- Consequence: A run can pause for a reason that has nothing to do with its remaining capacity, so the pause vocabulary and every reader of it must carry more than one resumable reason.

### The Fail-Closed Radius Stays Whole

- Choice: Keep one invalid entry invalidating the entire registry.
- Reason: It is a security property, not an ergonomic accident: a registry that is wrong somewhere cannot be trusted anywhere, and scoping invalidity per model would let a corrupted file still authorize spending. The free marker removes the operational pressure to weaken it, because a free model no longer has to be registered as an invalid entry.
- Consequence: A malformed free declaration still refuses every reservation deployment-wide, so the release-gated price-source evidence keeps carrying that operational warning.

### Extending Slice 11 Rather Than Forking It

- Choice: Change the Slice 11 price, ledger, reservation, and projection modules in place instead of adding a parallel free-model path.
- Reason: Slice 11 explicitly deferred this work and named the contract it needs, and two ceiling authorities would be the failure mode the strict boundary exists to prevent.
- Consequence: This slice touches modules another specification owns and must re-run their existing focused proof rather than only its own additions, and it must keep the privacy field-purpose map and rights-export allowlist equal to the changed schema in the same task.

## Risks

- A free marker could be mistaken for a general pricing override and later reused to skip pricing for an unproven model. Keep the marker legal only inside an ordinary versioned registration with full evidence and expiry, and prove that a marker outside that shape is refused.
- Relaxing the database unit-price rule could weaken the strongest existing defence. Replace it with a paired rule rather than a looser one and prove directly at the database that a zero-priced row without the declared mode, and a priced row with a zero price, are both still refused.
- Adding a ledger column silently breaks two proofs that assert the field-purpose map and the rights-export allowlist equal the schema's fields. Treat updating both as part of the same task that adds the column, not as later cleanup.
- Adding a pause reason can crash a reader that pattern-matches only the existing one. Extend the schema vocabulary, the database pause constraint, and the projection mapping together, and prove an unknown reason is still unreachable.
- A free registration could expire unnoticed and turn a working run into a stale-price refusal. Keep the expiry rule identical to a priced registration so the operator has one renewal lifecycle rather than two, and surface the refusal rather than defaulting to free.
- Zero-amount reservations still consume the outstanding-reservation limit, so a long free run could exhaust it. Keep the limit and prove that release and abandoned recovery return free entries as they do priced ones.
- A downstream consumer could read a free boundary as unknown or as zero remaining. Publish an explicit state and prove the projection distinguishes free, unknown, and not applicable from each other.

## Open Questions

- None. The six product decisions this design anticipated are now resolved and recorded in `requirements.md` `Business Rules`, and each was accepted as the design describes, so no mechanism above changed.
