# Participation Identity Lifecycle Progress Log

### 2026-08-02 — Task 2 complete: revocation former-identity links are bounded

- Completed: Acknowledgement now locks the handoff and clears `former_account_id` and `former_hosted_identity_id` in the acknowledgement transaction. Replays preserve the first consumer reference and acknowledgement time, including cleanup of an already acknowledged legacy row. The shared retention pass now reports `participation_revocation_links` and clears either remaining link at `occurred_at <= now - 30 days`, independently of acknowledgement state.
- Boundary held: Cleanup preserves the revocation identifier, project, participant-history reference, owner fallback, last display label, reason, occurrence time, contract version, claim and acknowledgement state, and consumer reference. The existing invitation and departed-participant rules remain additive and unchanged; active authorization and Slice 07 records are never selected.
- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_revocation_retention_test.exs test/sdd_orchestrator/participation/revocations_test.exs` — exit `0`.
- Failed checks: None. Focused proof passed with 21 tests and real exit status 0. The Spec 25 validator, global 29-specification capability graph, and `git diff --check` are recorded after this write-back.
- Integration note: Existing Task 22 derived-revocation anonymization locates handoffs through the former account link that this task now releases. Task 3 owns the replacement lookup mechanism and historical-attribution tests; Task 2 does not edit `Participation` or `Privacy.Rights`.
- Remaining: Tasks 1 and 3 complete their independent lifecycle repairs; Task 4 reconciles compatibility and publishes `capability:participation-identity-lifecycle`.
- Spec updates: Marked Task 2 complete and recorded its focused proof. Requirements, design, acceptance criteria, ownership, task sizes, proof scope, and capability edges are unchanged.

### 2026-08-02 — Task 1 complete: fresh acceptance restores linked presentation

- Completed: Fresh invitation acceptance now locks the project-and-account profile state, creates one new active participant authorization, reactivates a linked historical participant profile with its stable identifier and newly accepted available label, and creates a new profile only when no linked profile exists. An anonymized row stays unlinked and unchanged.
- Boundary held: Fresh invited-email proof and explicit acceptance remain mandatory. Invalid labels, unavailable labels, and identity-lifecycle conflicts return distinct results; every failure rolls back participant, profile, invitation, and notification writes. Replay and concurrent acceptance leave one active authorization and the correct profile.
- Mechanism recorded: First acceptance keeps the established profile-keyed notification identity. Because re-acceptance deliberately reuses that profile identifier, its fresh invitation identifier keys the new participant and owner outcome notifications so they commit once without being mistaken for a replay of the original join.
- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/participation/reacceptance_test.exs` — exit `0`.
- Remaining: Tasks 2 and 3 may continue independently; Task 4 remains blocked on Tasks 1, 2, and 3 together.
- Failed checks: None. The focused proof passed with 9 tests and real exit status.
- Spec updates: Marked Task 1 complete and recorded its proof. Requirements, design, acceptance criteria, capability ownership, task sizes, proof scope, and dependency edges are unchanged.

### 2026-08-02 — Focused identity-lifecycle child specification created

- Completed: Approved fresh re-acceptance through linked historical-profile reuse, permanent anonymized-history separation, former-identity-link cleanup on acknowledgement or by 30 days, and verified current-participant departure before historical anonymization.
- Scope classification: Standard focused slice with four tasks, three parallel implementation tasks, one compatibility and readiness task, and a two-task critical path.
- Remaining: Implement Tasks 1, 2, and 3 independently, complete Task 4 compatibility proof, and publish `capability:participation-identity-lifecycle`.
- Failed checks: None. The individual validator and coordinated global capability graph pass; implementation has not started.
- Proof receipts: None.
- Spec updates: Created the approved requirements, design, data boundaries, capability ownership, focused proof scope, task ownership, release boundary, and execution sequence for the participation identity lifecycle.
