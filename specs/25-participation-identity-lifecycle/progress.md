# Participation Identity Lifecycle Progress Log

### 2026-08-09 — Task 4 complete: compatibility proven, capability ready

- Completed: Added `test/sdd_orchestrator/participation/identity_lifecycle_compatibility_test.exs` (11 focused tests) proving Tasks 1-3 compose: a profile identifier and each revocation's `project_participant_id` stay stable across two departures and a reacceptance; an unrelated account's current authorization is unaffected by another account's reacceptance or anonymization elsewhere in the project; a rolled-back re-acceptance leaves no partial state; acknowledgement cleanup is unaffected by a concurrent reacceptance; verified anonymization still reaches a derived revocation whose identity links acknowledgement already cleared; the Slice 07 revocation consumer applies a post-reacceptance removal and self-leave exactly as an ordinary one; acceptance/removal notifications after a full round trip stay singular, targeted, and minimized; unverified/unapproved anonymization and owner self-leave stay fail-closed; and one project's lifecycle events never touch another project's rows for the same account.
- No production code changed — Tasks 1-3's shipped behavior composed correctly on the first attempt.
- Proof receipt: `Task 4` — scope `Focused` — command `mix test test/sdd_orchestrator/participation/identity_lifecycle_compatibility_test.exs` — exit `0`.
- Failed checks: None. Confirmed by independent re-run with real exit status.
- Remaining: Slice verification gate (`mix check` and the explicit code-quality commands, browser matrix, production proof, specification and capability-graph validators) through `run_proof.py slice`.
- Spec updates: Marked Task 4 complete, recorded `capability:participation-identity-lifecycle` as ready, and set the slice status to reflect all four tasks complete pending the verification gate.

### 2026-08-09 — Task 3 complete: derived-revocation anonymization survives acknowledgement

- Completed: `Participation.anonymize_profile/2`'s derived-revocation step now correlates through `project_participant_id` — via a subquery joining `ProjectParticipant` to `hosted_identity` and matching `account_id` — instead of the no-longer-reliable `former_account_id`. `anonymize_project_attribution/2` (the unrelated bulk project-deletion sweep) is unchanged. Updated the one stale pre-condition assertion in `historical_attribution_test.exs` that assumed `former_account_id` survives acknowledgement; every downstream assertion (`derived_revocations: 1`, label anonymized, both former-identity fields nil) is unchanged and still passes.
- Boundary held: `identity_rights_workflow_test.exs` needed no change — its former-identity assertions were already post-anonymization checks, not pre-conditions.
- Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator/participation/identity_rights_workflow_test.exs test/sdd_orchestrator/participation/historical_attribution_test.exs` — exit `0`.
- Failed checks: None. Confirmed by independent re-run with real exit status.
- Remaining: Task 4 compatibility proof and `capability:participation-identity-lifecycle` publication.
- Spec updates: Marked Task 3 complete.

### 2026-08-09 — Resolved the Task 3 derived-revocation data boundary

- Completed: Approved correlating derived-revocation anonymization through `ParticipationRevocation.project_participant_id` instead of `former_account_id`. `project_participant_id` names the exact departed authorization row and is never cleared by acknowledgement or the 30-day retention rule, so it survives the case that broke the integrated proof. No new identifier is stored, no retention is extended, and Task 2's shipped acknowledgement and retention contract is unchanged.
- Rebase: Rebased `slice/25-participation-identity-lifecycle` onto latest `main` (94 commits ahead at divergence). One conflict in `lib/sdd_orchestrator/privacy/retention.ex` — both branches had additively extended the same moduledoc list and `prune_all/1` map (main with personal-AI-connection and runtime-observation retention rules from merged slices, this branch with the participation-revocation-link rule). Resolved by keeping both sets of entries; re-ran Task 1 and Task 2 focused proof after rebase and both still pass (9 and 21 tests, exit 0), confirming the resolution.
- Earliest unblocked stage: Technical design. Task 3 is reopened for implementation against the approved boundary; Task 4 remains blocked only on Task 3's integrated proof.
- Failed checks: None new. `python3 .agents/scripts/validate_spec.py specs/25-participation-identity-lifecycle` and `python3 .agents/scripts/validate_spec.py --all specs` are re-run after this write-back.
- Spec updates: Resolved design.md's Open Question, added the "Correlate Derived Revocations Through The Departed Authorization" decision, updated the affected data boundaries and components-affected entries, set the slice back to `In Progress`, cleared `Blocked Decisions`, and reopened Task 3's owned surfaces to name the approved correlation.

### 2026-08-02 — Integrated proof blocked Task 3 on post-acknowledgement correlation

- Completed: Merged the independently proven Task 1, Task 2, and Task 3 commits onto `slice/25-participation-identity-lifecycle` and reconciled their checkboxes and progress entries. Task 1 passes with 9 tests and Task 2 passes with 21 tests on the combined branch.
- Invalidated: Task 3's isolated receipt no longer proves the integrated contract. Its required focused command exits `2` with 34 of 35 tests passing because `Revocations.acknowledge/3` correctly returns `former_account_id: nil`, while `Participation.anonymize_member_attribution/3` still selects the derived revocation through that cleared field. Task 3 is reopened and Task 4 remains blocked.
- Earliest blocked stage: Technical design. Requirements stay approved; the missing choice changes personal-data linkage and retention, so implementation cannot invent it during reconciliation.
- Remaining: Resolve the design question through `update-spec`, reimplement or adjust Task 3 within the approved boundary, rerun its focused proof, then execute Task 4 and the slice verification gate.
- Failed check: `MIX_TEST_PARTITION=253 python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/participation/identity_rights_workflow_test.exs test/sdd_orchestrator/participation/historical_attribution_test.exs` — exit `2`; failure at `historical_attribution_test.exs:293` because the acknowledged revocation's former account link is correctly absent.
- Spec updates: Set the slice to `Blocked`, reopened Task 3, recorded the missing data boundary in `design.md`, and preserved the successful Task 1 and Task 2 receipts and implementation history.

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
