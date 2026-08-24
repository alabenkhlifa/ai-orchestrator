# Participation Completion Progress Log

### 2026-08-24 - Reconciled the AC-30 consumer proof with the identity release specs/25 made intentional

- Defect: `test/sdd_orchestrator/delivery/revocation_consumer_test.exs` failed on `[AC-30]`'s "a full consumer pass mutates no participation record". It was reported as a pre-existing unrelated failure by `specs/36-local-worker-native-distribution` and again by `specs/37-hosted-local-repository-connection`, and was still unowned; this slice owns the test, so the fix belongs here.
- Root cause, traced rather than guessed: the proof compared every handoff field except the four delivery markers and required them byte-identical across a consumer pass. `former_account_id` and `former_hosted_identity_id` were non-nil before the pass and `nil` after. `ParticipationRevocation.acknowledge_changeset/3` pipes through `identity_release_changeset/1`, which nils both on acknowledgement, and `Revocations.ensure_identity_released/1` re-asserts it as an invariant on a repeated acknowledgement. `Privacy.Retention` documents the same rule, noting that acknowledgement "releases the very `former_account_id` a second consumer would need".
- That behaviour arrived with `specs/25-participation-identity-lifecycle` (commit `6dd7979`, 2026-08-02), which added its own proofs but did not reconcile this consumer test written earlier. So the assertion, not the code, was stale: acknowledging a handoff is allowed to release the two identity links, because an applied departure must stop naming a person.
- No production defect. Nothing in `lib/` changed.
- Fix: `handoff_shape/1` now also excludes the two released identity links, and the release is asserted explicitly instead of merely excluded — the proof captures both links before the pass, asserts they were genuinely set, and asserts both are `nil` afterwards. The assertion is stronger than before: removing the release would now fail this test, where previously it was the release itself that failed it.
- Failed checks: None after the fix.
- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/revocation_consumer_test.exs` — exit `0`.
- 16 tests passed. Confirmed on the main thread by real exit status. This slice's `Verified` status is unchanged.
- Spec updates: this entry only; no requirement, design decision, acceptance criterion, or task boundary changed.

### 2026-08-14 - Verification gate: one Dialyzer fix, accepted exception, clean otherwise

- Fixed a real Dialyzer finding in `ParticipationGovernance.capability_set_mismatch_reasons/1`: `MapSet.difference/2` on a compile-time-literal set and a runtime-built one triggered a `call_without_opaque` type mismatch. Replaced with plain list `Enum.reject/2` diffing — simpler and avoids the issue entirely; behavior and all 17 tests unchanged.
- `mix test`: 4038/4042 passed, 4 failed — 2 the same already-documented pre-existing, unrelated failures accepted for specs/25/26/27/28 on the same basis and evidence (`SddOrchestrator.Delivery.LocalWorkerRuntimeProjectionTest`, `SddOrchestrator.Delivery.RevocationConsumerTest`); 2 further failures (`StagingWorkspaceTest`) confirmed pure test-pollution — pass cleanly in isolation, not real failures.
- Format, compile --warnings-as-errors, credo --strict, dialyzer (after the fix above), deps.audit, and sobelow --config all pass with zero issues.
- Remaining: Browser matrix (desktop + mobile), production proof, validators, then mark Verified and merge.
- Spec updates: None — accepted gate exception, not a specification change.

### 2026-08-14 - Browser matrix: one pre-existing, unrelated e2e failure accepted

- `npm --prefix assets run test:e2e`: 135/138 passed, 2 skipped, 1 failed — `e2e/repository-kits.spec.js` "the owner inspects the catalog, opens one package, and sees supersession" — the same fixed-digest kit-package seed collision already documented in `specs/25-participation-identity-lifecycle/progress.md` and `specs/27-participation-operational-retention/progress.md`. Owned by specs/15/30, not this specification, and nothing in Task 1 touches repository-kit seeding. Accepted under the same exception policy.
- Remaining: Production proof, validators, then mark Verified and merge.
- Spec updates: None — accepted gate exception, not a specification change.

### 2026-08-14 - Task 1 complete: participation governance published

- Completed: Added `SddOrchestrator.Privacy.ParticipationGovernance` — a literal, hand-copied registry of the seven required `{capability, specification, task}` triples from this specification's own `Requires:` list (`project-participation-boundary`/`project-owner-display-profile`/`project-participation-recipient-routing` from specs/08, `participation-identity-lifecycle` from specs/25, `participation-processing-controls` from specs/26, `participation-operational-retention` from specs/27, `participation-deletion-recovery` from specs/28), plus `validate_providers/1` (rejects malformed entries, duplicate capability names including stale superseded-task variants, duplicate `{specification, task}` references, and any capability-set mismatch) and `readiness/1` (staged: `implementation_readiness`/`local_verification_readiness` driven by registry validity, `release_readiness` always literal `:deferred_to_release_gate`, independently of registry state — AC-03).
- Deliberately does NOT parse `.md` spec files or re-implement `capability_index.py` in application code — that mechanical check is the orchestrating agent's and the SDD tooling's job, confirmed separately (all seven capabilities independently re-verified `ready` via `capability_index.py` before this task started). This module's job is the registry's own structural integrity plus real cross-provider compatibility.
- Cross-provider compatibility proven with one substantive integration test exercising real code (no mocks) across all seven providers in sequence: invite → accept (specs/25) → boundary authorization (specs/08) → processing inventory stays valid, purpose-limitation and content-boundary and operations-view all correct against live rows (specs/26) → owner self-leave refusal audited (specs/27's security log) → departure → immediate access denial (specs/08/25) → propagation issued and reconciled independent of access-denial outcome (specs/28) → retention prunes departed-link/revocation-link/email-diagnostic/security-event rules together in one `prune_all/1` pass at +31 days (specs/27) → a late acknowledgement arriving after retention already cleared the links → tombstone-first recovery still refuses even with a stale snapshot (specs/28). No single provider's own test suite proves this composition.
- Proof receipts:
  - Result: 17 passed.
  - Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_governance_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- `capability:project-participation-governance` is now ready (implementation and local-verification readiness only; release readiness remains deferred, per AC-03 and this slice's Release gates). Downstream consumer: specs/12 Task 9.
- Remaining: Slice verification gate (full mix check pieces, desktop+mobile browser matrix, prod release, validators).
- Failed checks: None.
- Spec updates: Task 1 checkbox/status line; slice Status updated to reflect Task 1 complete and the capability ready.

### 2026-08-02 - Final participation coordination specification created

- Completed: Approved acyclic provider reconciliation, full slice-scoped deterministic verification, staged readiness, and sole final governance-capability publication.
- Scope classification: Standard focused coordination slice with one task and a one-task critical path.
- Remaining: Complete every named provider, implement Task 1 through focused proof, run the full verification gate, and publish final readiness.
- Failed checks: None. The individual validator and coordinated global capability graph pass; implementation has not started.
- Proof receipts: None.
- Spec updates: Added final capability ownership, compatibility proof, task proof scope, downstream publication boundary, and release classification.
