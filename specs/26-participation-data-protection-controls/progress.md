# Participation Data Protection Controls Progress Log

### 2026-08-13 - Task 2 complete

- Completed: Added `SddOrchestrator.Privacy.ParticipationOperationsAccess.metadata_for_project/1`, the new minimized-operations view AC-02 requires — no such view existed before. Owner and participant views were proven, not rebuilt: tests exercise the already-approved `SddOrchestrator.Participation.Boundary.current_member/2` and `SddOrchestrator.Participation.members/3` directly (Slice 08), mirroring the specs/18 Task 2 "prove, don't rebuild" precedent, covering absent/stale/removed/departed/cross-project/unknown-project denial (uniform, non-disclosing) and owner-vs-participant email masking. A telemetry probe proves authorization runs before any `project_member_profiles` lookup for a denied actor.
- Discovery: Task 1's inventory classifies `ParticipationEmailDelivery.recipient_address` and `ProjectInvitation.email_digest/token_digest/token_salt` under the same `recipient_category: :minimized_operations` as the safe diagnostic fields — that classification is a ceiling (an approved-if-shown audience), not a shaping policy by itself. `allowed_fields/0` is deliberately a stricter subset (event/status/failure_code/timestamps only), documented and directly tested. No design.md change needed: this is a legitimate narrowing within Task 2's own scope, not a contradiction of Task 1's contract.
- Scope classification: unchanged.
- Remaining: Implement Tasks 3 through 5 and the verification gate.
- Failed checks: None.
- Proof receipts:
  - Result: 12 passed.
  - Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_access_controls_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- Spec updates: None beyond the Task 2 checkbox and status line.

### 2026-08-13 - Task 1 complete

- Completed: Added `SddOrchestrator.Privacy.ParticipationProcessingRecord` (closed classification vocabulary: basis, hosted-only authority, four recipient categories, processor category, transfer classification, lifecycle owner) and `SddOrchestrator.Privacy.ParticipationProcessingInventory` (reflection-driven, one record per persisted field across `ProjectInvitation`, `ProjectParticipant`, `ProjectMemberProfile`, `ParticipationRevocation`, `ParticipationEmailDelivery`, and the `participation.`-namespaced shared `AccountNotification` schema). `lifecycle_owner` classifications point at specs/25 (ready, authoritative for revocation/departure/rights/anonymization), and forward at not-yet-implemented specs/27 and specs/28 for operational-retention and deletion/backup enforcement, mirroring the specs/18 precedent of approving forward-pointing lifecycle-owner values before their provider slices exist.
- Scope classification: unchanged.
- Remaining: Implement Tasks 2 through 5 and the verification gate.
- Failed checks: None.
- Proof receipts:
  - Result: 45 passed.
  - Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_processing_inventory_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session (not only the implementing sub-agent), same command, same exit status.
- Spec updates: None beyond the Task 1 checkbox and status line above; `entity:ParticipationProcessingRecord` traceability already recorded in `tasks.md`.

### 2026-08-13 - Capability blocker cleared, Task 1 started

- Completed: Confirmed via `capability_index.py` that `capability:project-participation-boundary` (specs/08#Task 4) and `capability:participation-identity-lifecycle` (specs/25#Task 4) are both `ready`. Corrected the stale `Blocked` status and `Blocked Decisions` entry in `tasks.md` to reflect readiness. Started Task 1.
- Engineering mechanism resolved: `design.md`'s "Extend The Shared Processing Inventory" decision said to reuse the generic `DataProcessingRecord` struct, but AC-01 needs closed-vocabulary `authority`, `recipient_category`, `processor_category`, `transfer_classification`, and `lifecycle_owner` fields that struct does not have, and that struct also inlines retention/rights text this slice must not own. Slice 18 hit the identical mismatch and resolved it with a dedicated `DeliveryProcessingRecord`. Updated `design.md` and `tasks.md` (Task 1 owned surfaces, `Owns:` entity, verification-gate line) to use a dedicated `ParticipationProcessingRecord` module instead, mirroring that precedent. Non-behavioral: no AC, scope, or boundary change. Re-ran both validators after the edit; both pass.
- Scope classification: unchanged.
- Remaining: Implement Tasks 1 through 5 and the verification gate.
- Failed checks: None.
- Proof receipts: None yet for Task 1.
- Spec updates: `design.md` "Extend The Shared Processing Inventory" decision and "Components Affected"/"Data and Access Boundaries" naming; `tasks.md` status/blocker text and Task 1 entity naming. No requirements, AC, or scope change.

### 2026-08-02 - Focused participation data-protection specification created

- Completed: Approved the participation processing inventory, project and operations access, exceptional-support elevation, processor and transfer controls, content and credential boundary, purpose limitation, and genuinely anonymous aggregate contract as one focused child specification.
- Scope classification: Standard focused specification with five tasks and a five-task critical path; no slice-size, task-size, or proof-scope exception is used.
- Remaining: Publish the participation identity-lifecycle capability, then implement Tasks 1 through 5 and complete the verification gate.
- Failed checks: None. The individual validator and coordinated global capability graph pass; implementation has not started.
- Proof receipts: None; implementation has not started.
- Spec updates: Moved the outcome formerly assigned to Slice 08 Task 23 and AC-13 into local AC-01 through AC-05 ownership while preserving the established participation boundary and consuming the final identity lifecycle.
