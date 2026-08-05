# AI Runtime Free Model Support Tasks

## Status

Blocked

The technical design is settled and every capability this slice consumes is already ready. Implementation is blocked on six unresolved product decisions recorded under `Open Questions` in `requirements.md`, which is why the requirements status is `Draft`. They decide the registration shape, whether a free model opens a ledger, whether a ceiling stays required, what happens when a free price is withdrawn, whether the user sees freeness before selecting, and whether the registry keeps its all-or-nothing invalidation. Task 1 cannot start until at least the registration-shape and fail-closed-radius decisions are made.

## Active Slice

Let a deployment operator register an officially free provider model price that stays distinguishable from a missing one, and let one personal API-key session reserve, reconcile, pause, and project that model's turns without ever weakening the strict non-exceeding spending ceiling.

## Cross-Specification Dependencies

Requires:

- `capability:ai-runtime-session` — provider `specs/11-ai-runtime-governance#Task 11` — required before `Task 1`.
- `capability:ai-runtime-governance` — provider `specs/11-ai-runtime-governance#Task 6` — required before `Task 2`.
- `capability:ai-runtime-observation` — provider `specs/11-ai-runtime-governance#Task 5` — required before `Task 4`.

Provides:

- `capability:ai-runtime-free-model-pricing` — ready after `Task 4`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- All four tasks are standard. Each owns one independently provable price, reservation, transition, or projection outcome, at most two acceptance criteria, no new entity, one task-boundary commit, and focused proof expected to run in about ten minutes.
- The slice contains four tasks and its longest `Depends on:` path contains four tasks: Task 1, Task 2, Task 3, then Task 4.
- No task-size exception is used. The one atomic change in the slice, the ledger migration that replaces the strictly-positive unit-price rule with the paired rule its new column depends on, lives inside Task 2 together with the column, the changeset, and the privacy coverage that the same schema shape is proven against.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- An explicit proven-free per-model declaration in the versioned official price registry, its pricing mode on the loaded price value, and a conservative maximum of zero for it.
- Continued refusal of a numeric zero unit price, a mixed declaration, an unknown model, an unpublished or expired registration, an untrustworthy registry, and an unconfigured registry.
- One cost-ledger migration adding the persisted pricing mode and replacing the strictly-positive unit-price constraint with the paired priced-or-free rule, plus the matching changeset validation.
- Zero-allocation reservation, zero reconciliation, release, and abandoned-reservation recovery for a free turn, with the existing idempotency, duplicate-key, capacity, and no-over-allocation invariants re-proved against it.
- A resumable pause when a session's free registration is replaced by a priced one, including the extended pause vocabulary in the schema, the database constraint, and the projection mapping.
- An explicitly free cost boundary in the ledger projection and the owner-exact runtime projection, beside the existing unknown and not-applicable states.
- Privacy field-purpose, rights-export, retention, and minimization coverage for the added ledger field.

Excluded:

- Any change to model catalogs, quota normalization, quota policy, personal connections, the personal-worker transport, or the Codex App Server adapter.
- Any change to the pinned runtime-session schema, its immutability trigger, or its ceiling requirement.
- Any change to the participant-safe projection, which continues to carry no cost fact.
- Automatic price discovery from a provider, and the deployment's real price-source values, which stay release-gated.
- ChatGPT-authenticated sessions, subscription quota, scarce-model opt-ins, and provider-paid continuation.
- Project-shared connections, project budgets, and project-funded per-run ceilings.

Deferred after this slice:

- Showing that a model is free before it is selected, in AI Connections, Slice 07, or Slice 12. That change belongs with the focused follow-up that already owns Slice 11's deferred AI Connections presentation work and its desktop and mobile browser proof.
- Free models under a project-shared budget or a project-funded per-run ceiling, which follow Slice 11's deferred shared-funding workflow.
- An operator-facing surface for inspecting or validating the configured price registry, which remains release-gated configuration.

Release gates:

- The deployment's official price-source configuration must record which models are registered free, on what published evidence, and with what renewal date, because a free registration expires exactly like a priced one.
- The price-source evidence must keep recording that a numeric zero is not an accepted registration and that one invalid entry invalidates the entire registry, so a malformed free declaration still refuses every reservation deployment-wide.
- Final accountable privacy, security, and legal review of the extended cost-ledger field remains with Slice 11's release gate rather than being repeated here.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Register proven-free official prices without weakening the fail-closed registry.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Make freeness a positive declaration the operator publishes, so a proven-free price stops being indistinguishable from a missing one.
  - Owned surfaces: Per-model free declaration shape, exact priced-pair shape, numeric-zero refusal, mixed-declaration refusal, unrecognized-marker refusal, pricing mode on the loaded price value, version, source, publication, expiry and currency evidence for a free registration, whole-registry invalidation, unconfigured-registry refusal, stale-registration refusal, conservative maximum of zero with bounded-token validation retained, and price fixtures.
  - Owns: AC-01, AC-02
  - Proof: Focused price-registry tests prove a free declaration loads with full evidence, a numeric zero, a mixed declaration, an unrecognized marker, a negative, unparseable, oversized, or credential-shaped entry each invalidate the whole registry, an unknown model, unpublished registration, expired registration, and unconfigured registry each still fail closed, and a free price yields a conservative maximum of zero while an out-of-range bounded token count is still refused.

- [ ] Task 2 — Reserve and reconcile a free turn inside the strict ceiling.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let a free model consume no approved capacity while every existing ceiling invariant keeps holding against the same ledger.
  - Owned surfaces: Ledger pricing-mode column and migration, paired priced-or-free unit-price constraint in the database and the changeset, ledger opening for a free model, zero-amount reservation entry, idempotent replay, duplicate-key refusal, unchanged remaining capacity, zero reconciliation, over-reconciliation refusal, release, abandoned-reservation recovery, reservation-sum and capacity invariants, ledger fixtures, and the field-purpose and rights-export coverage for the added field.
  - Owns: AC-03, AC-04
  - Proof: Focused cost-boundary tests prove a free session opens a ledger, reserves without moving remaining capacity, replays and refuses a reused key, reconciles only at zero, refuses a nonzero settlement, releases and recovers free entries, keeps the no-over-allocation invariant under concurrency, and refuses at the database a zero-priced row that does not declare free and a priced row that carries a zero; the privacy processing-inventory and rights suites prove the added field has a recorded purpose and an export decision.

- [ ] Task 3 — Pause instead of charging when a free registration is withdrawn.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Prevent a run pinned on a published free model from silently beginning to spend when its registration changes.
  - Owned surfaces: Persisted-mode comparison at reservation time, resumable pause reason for a withdrawn free price, extended pause vocabulary in the schema and the database pause constraint, pause-reason projection mapping, no allocation on the paused turn, preserved pinned configuration, priced-to-free transition proceeding without a pause, and expired-registration refusal remaining unchanged.
  - Owns: AC-05
  - Proof: Focused cost-boundary tests prove a free-to-priced transition allocates nothing and pauses with the withdrawn-free reason, the pinned session and its remaining capacity survive the pause and a later turn resumes, a priced-to-free transition proceeds without a pause, an expired free registration still fails closed as a stale price, and an unrecognized pause reason is still unreachable in the schema, the database, and the projection.

- [ ] Task 4 — Project a free cost boundary as free rather than unknown.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Give authorized consumers a boundary they can read as proven free without inferring it from an amount.
  - Owned surfaces: Explicit free state in the ledger projection with its price evidence, owner-exact runtime projection cost boundary, separation from the unknown and not-applicable states, unchanged participant-safe projection with no cost fact, consumer contract for a downstream presentation slice, `capability:ai-runtime-free-model-pricing` provider, and readiness write-back.
  - Owns: AC-06
  - Proof: Focused projection tests prove an owner sees an explicit free boundary with its price evidence, an unopened ledger still projects unknown, a session with no ceiling still projects not applicable, the three states are distinguishable from each other, the participant-safe projection still carries no cost, price, ceiling, or pricing-mode value, and a downstream consumer obtains the boundary through public functions alone.

## Verification Gate

- [ ] AC-01 through AC-06 pass and no deferred behavior is implemented.
- [ ] Every active acceptance criterion has one primary task owner and this slice introduces no new data entity.
- [ ] Price-registry tests prove a proven-free registration and an unknown price stay distinguishable, and that a numeric zero, a mixed declaration, and an untrustworthy or unconfigured registry all still fail closed.
- [ ] Cost-ledger tests prove zero-allocation reservation, zero reconciliation, release, abandoned recovery, the reservation-sum and capacity invariants, and no concurrent over-allocation, with the database refusing an undeclared zero price.
- [ ] Transition tests prove a withdrawn free price pauses the run resumably, allocates nothing, and preserves the pinned configuration, while a priced-to-free transition proceeds.
- [ ] Projection tests prove free, unknown, and not applicable are distinct owner-visible states and that the participant-safe projection still carries no cost fact.
- [ ] The complete Slice 11 cost, session, observation, projection, lifecycle, and privacy suites still pass unchanged against the extended ledger shape.
- [ ] Privacy field-purpose, rights-export, retention, minimization, no-analytics, and no-secondary-use checks pass locally for the added field.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` passes.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix format --check-formatted`, `python3 .agents/scripts/run_proof.py slice -- mix compile --warnings-as-errors`, `python3 .agents/scripts/run_proof.py slice -- mix credo --strict`, `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `python3 .agents/scripts/run_proof.py slice -- mix deps.audit`, `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config`, and `python3 .agents/scripts/run_proof.py slice -- mix test` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [ ] A fresh database migrates and rolls back the ledger migration cleanly.
- [ ] `python3 .agents/scripts/validate_spec.py specs/31-ai-runtime-free-model-support` passes.
- [ ] `python3 .agents/scripts/validate_spec.py --all specs` passes.
- [ ] `python3 .agents/scripts/split_progress_log.py --check` and `git diff --check` pass.
- [ ] Implementation, local-verification, and release readiness are recorded separately, and the deployment's price-source evidence remains in the release gate.

## Blocked Decisions

- Six product decisions recorded under `Open Questions` in `requirements.md` block implementation. Questions 1 and 6 block Task 1, because they decide the accepted registration shape and whether the registry keeps its all-or-nothing invalidation. Questions 2 and 3 block Task 2, because they decide whether a free model opens a ledger at all and whether an approved ceiling stays required. Question 4 blocks Task 3, because it decides whether a withdrawn free price pauses or charges. Question 5 blocks nothing here; it confirms the scope boundary against the deferred presentation specification.
- No capability is unavailable. `capability:ai-runtime-session`, `capability:ai-runtime-governance`, and `capability:ai-runtime-observation` are all complete and ready in `specs/11-ai-runtime-governance`.

## Progress Log

See [progress.md](progress.md).
