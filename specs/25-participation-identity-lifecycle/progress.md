# Participation Identity Lifecycle Progress Log

### 2026-08-02 — Task 3 complete: the verified workflow ends participation before anonymizing

- Completed: An approved verified anonymization request now has an ordered route from current participation to anonymous historical attribution. `Privacy.Rights.anonymize_verified_participation/4` accepts project, account, and hosted-identity scope, commits the existing authoritative self-departure transition (`Participation.Revocations.leave/3`) when the requester is a current participant, and only then invokes the verified historical-attribution anonymization, including the derived revocation copy. AC-05 and AC-06 are satisfied; the direct active-anonymization refusal, the verified pending-handoff override after departure, and unverified necessity denial are unchanged.
- Identity verification alone is not the legal disposition. The orchestration refuses anything less than both recorded facts — `verified_request: true` and `approved: true` — with `:unverified_request` or `:approval_required` before any state changes; unverified processing continues through `anonymize_participation_attribution/3` and still respects pending-handoff necessity.
- The scope check is load-bearing, not decorative: self-departure claims the participant row by hosted identity, so the orchestration first proves the hosted identity belongs to the requesting account and fails closed with `:not_found` otherwise. A wrong identity can never end another person's membership, a cross-project request is not found, and the immutable owner is refused with `:owner_cannot_leave` because owner departure is out of scope.
- Departure is never rolled back. A failure after a committed departure returns an explicit `%{status: :retryable_incomplete, participation: :ended, retry: :anonymization}` result instead of success, access stays fail-closed, and a later run completes only the remaining anonymization — proven by retrying after a committed departure with no second handoff and an unchanged `departed_at`. A requester departed concurrently folds into `:already_ended` rather than an error.
- Integration note for Task 2: a participant departing with no presentation profile leaves the fresh revocation's `former_account_id` and `former_hosted_identity_id` with nothing for profile-driven anonymization to reach; the workflow reports that as retryable-incomplete, and acknowledgement or the 30-day retention rule owned by Task 2 remains the backstop for those links. No revocation module was modified; `Revocations` was consumed through its public interface only.
- Linkability stays negative: the anonymous label is the fixed `Former participant` constant, never derived from an email, account, or hosted-identity value, and the anonymized profile and handoff dumps contain neither the requester's email fragments nor their stable identifiers.
- Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator/participation/identity_rights_workflow_test.exs test/sdd_orchestrator/participation/historical_attribution_test.exs` — exit `0`.
- Failed checks: None. The focused proof passed with 35 tests and real exit status 0 through the proof runner under `MIX_TEST_PARTITION=253`; the individual specification validator, the global capability graph, and `git diff --check` pass after this write-back. The slice gate, browser matrix, and production proof remain the slice's own gate.
- Spec updates: Marked Task 3 complete for AC-05 and AC-06. Requirements, design, capability ownership, task sizes, proof scope, and dependency edges are unchanged; Tasks 1, 2, and 4 remain with their own owners.

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
