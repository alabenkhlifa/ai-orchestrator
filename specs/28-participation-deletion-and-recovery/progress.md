# Participation Deletion And Recovery Progress Log

### 2026-08-14 - Task 2 complete; capability ready

- Completed: Added `SddOrchestrator.Privacy.ParticipationCleanupRequest` (Ecto schema, table `participation_cleanup_requests`, opaque caller-minted `subject_ref` only — never a raw account/hosted-identity/participant id, email, or display name; closed `action`/`destination`/`state`/`failure_reason` vocabularies enforced by DB check constraints; unique `(subject_ref, action, destination)` index) and `SddOrchestrator.Privacy.ParticipationPropagation` (`propagate/3` issues one idempotent request per each of the four fixed destinations `Rights.anonymize_participation_attribution/3`'s `pending_propagation` already declares — `:configured_processors`, `:caches`, `:indexes`, `:exports`; `acknowledge/2`, `fail/3`, and `reconcile/2` under a dedicated advisory lock mirroring `RetentionPruner.prune_with_lock/1`).
- No live destination adapters are configured yet (deferred per tasks.md's "Deferred after this slice"); the default stub adapter honestly reports `:destination_unavailable` (retryable) rather than fabricating acknowledgement.
- AC-03 proven directly: `Participation.member_role/3`/`Boundary.current_member/2` deny a departed participant identically regardless of propagation completion state (all-pending, partially-acknowledged, fully-acknowledged) — the propagation module never reads or writes the primary authorization boundary at all.
- Discovery: `Rights.deletion_propagation/1` (account/project erasure) does not itself list the four external destinations — only `anonymization_propagation/0`'s `pending_propagation` does. Per AC-02's own wording and this task's brief, `propagate/3` applies the same four destinations to both `:delete` and `:anonymize` actions; participation has no separate deletion-propagation function in `rights.ex` to diverge from. Non-behavioral clarification, no scope change.
- Proof receipts:
  - Result: 23 passed.
  - Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_propagation_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- `capability:participation-deletion-recovery` is now ready (Task 2 complete, proof passed). Downstream consumers: specs/12 Task 9, specs/29 Task 1.
- Remaining: Slice verification gate.
- Failed checks: None.
- Spec updates: Task 2 checkbox/status line; slice Status updated to reflect both tasks complete and the capability ready.

### 2026-08-14 - Task 1 complete: backup expiry and tombstone-first recovery

- Completed: Added `SddOrchestrator.Privacy.ParticipationBackupLifecycle`. The 35-day/encrypted/recovery-only contract is read directly from the existing `DeploymentPrivacyProfile.backup_lifecycle_contract/0`/`backup_handoff/1` (no duplicated constant). `recover/5` proves the one part of AC-01 that's locally provable without live backup infrastructure: tombstone-first ordering — it always resolves the *current* primary-store row (`ProjectParticipant`/`ProjectMemberProfile`/`ParticipationRevocation`, all read-only) before considering the caller-supplied `backup_snapshot` stand-in, and a currently tombstoned row (departed-and-cleaned, anonymized, or acknowledged-revocation) is refused outright regardless of stale snapshot content. Recovery-only access is enforced by reusing specs/26 Task 3's `ParticipationSupportAccess.authorize_content_read/2` elevation boundary rather than a second access-control mechanism. No new authoritative participation entity or persisted tombstone log was created.
- Scope classification: unchanged.
- Remaining: Task 2, then the verification gate.
- Failed checks: None.
- Proof receipts:
  - Result: 15 passed.
  - Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_backup_lifecycle_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- Spec updates: Task 1 checkbox/status line only.

### 2026-08-02 - Focused deletion and recovery specification created

- Completed: Moved unfinished participation backup and downstream propagation ownership out of the Slice 08 legacy plan without changing the approved 35-day, deletion, anonymization, or fail-closed contracts.
- Scope classification: Standard focused slice with two tasks and a two-task critical path.
- Remaining: Complete the named processing and retention providers, then implement Tasks 1 and 2 and run the verification gate.
- Failed checks: None. The individual validator and coordinated global capability graph pass; implementation has not started.
- Proof receipts: None.
- Spec updates: Added focused capability ownership, task proof scope, traceability, recovery ordering, and release boundaries.
