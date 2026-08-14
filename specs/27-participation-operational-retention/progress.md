# Participation Operational Retention Progress Log

### 2026-08-14 — Verification gate: one direct fix, one accepted exception

- Fixed a Credo `--strict` finding in Task 3's own test (`apply/3` with known arity) by calling `ParticipationSecurityLog.emit/3` directly — the runtime-atom values from `String.to_atom/1` still exercise the guard clause at runtime exactly as intended.
- Fixed `test/sdd_orchestrator/privacy/delivery_notification_retention_test.exs` (specs/18, already Verified/merged) — its "never deletes a participation-namespace notification" test used a fixture aged far past 90 days to prove the delivery rule's namespace selector never matches a `participation.*` row. That is still true, but Task 2's new `expired_participation_notifications` rule now legitimately deletes that same fixture through its OWN 90-day rule, so the old assertion ("participation row survives indefinitely") became false. Updated the test to assert namespace-selector isolation (both categories fire, delivery count is still only 1, neither cross-matches the other's row) instead of indefinite survival. This is a direct, foreseen consequence of Task 2's own approved behavior (AC-02 requires participation notifications to expire), not an unrelated pre-existing defect — fixed directly rather than treated as an exception.
- Accepted exception (same basis as specs/25 and specs/26, same two tests, same evidence): `SddOrchestrator.Delivery.LocalWorkerRuntimeProjectionTest` and `SddOrchestrator.Delivery.RevocationConsumerTest` fail even in isolation, are confined to `lib/sdd_orchestrator/delivery/` files this specification never touches, and are unrelated to Tasks 1-3. Two further failures in this run (`StagingBuilderTest`, `Worker.IsolationTest`) are pure test-pollution under full concurrent load — confirmed clean in isolation, not real failures.
- Failed checks: `mix test` — 3983/3987 passed, 4 failed; 2 confirmed genuine pre-existing/unrelated (accepted), 2 confirmed pollution.
- Format, compile --warnings-as-errors, credo --strict (after the fix above), dialyzer, deps.audit, and sobelow --config all pass with zero issues.
- Remaining: Browser matrix, production proof, validators, then mark Verified and merge.
- Spec updates: None — accepted gate exception, not a specification change.

### 2026-08-14 — Browser matrix: one pre-existing, unrelated e2e failure accepted

- `npm --prefix assets run test:e2e`: 135/138 passed, 2 skipped, 1 failed — `e2e/repository-kits.spec.js` "the owner inspects the catalog, opens one package, and sees supersession" — the same fixed-digest kit-package seed collision already documented in `specs/25-participation-identity-lifecycle/progress.md` (2026-08-14 entry). `RepositoryKits.publish_package/2` belongs to specs/15/30, not this specification, and nothing in Tasks 1-3 touches repository-kit seeding. Accepted under the same exception policy.
- Remaining: Production proof, validators, then mark Verified and merge.
- Spec updates: None — accepted gate exception, not a specification change.

### 2026-08-14 — Task 3 complete; capability ready

- Completed: Added `SddOrchestrator.Privacy.ParticipationSecurityEvent` (append-only Ecto schema, table `participation_security_events`, closed `event_type`/`outcome`/`reason` vocabularies enforced by both changeset validation and DB check constraints) and `SddOrchestrator.Privacy.ParticipationSecurityLog` (`emit/3`, `audit/3`, `prune/1`). Unlike `AIRuntime.SecurityLog` (a pure `Logger` sink with no local deletion boundary — retention there is deployment/release-gate evidence only), this module gives `Privacy.Retention` a genuinely callable local deletion boundary, per design.md's "Retention-Capable Structured Security Sink" decision — required because a 30-day policy with no callable deletion boundary cannot provide deterministic local lifecycle proof.
- Vocabulary grounded in real atoms already returned by existing participation code (not invented): event types `invitation_credential_rejected` (`InvitationProof`), `invitation_acceptance_rejected` (`Acceptance`), `revocation_denied` (`Revocations`); outcomes `rejected`/`denied`/`failed` (catch-all redaction sink); reasons scoped one-to-one per outcome.
- Added `prune_participation_security_events/1` to `Privacy.Retention`, its `prune_all/1` registration, window constant, and moduledoc paragraph — plus one small correction to the moduledoc's pre-existing closing sentence ("operational-security log... retention... enforced by the deployment's... infrastructure"), now qualified as true for every category except this new locally-deleted one.
- Capstone compatibility proof (`participation_operational_retention_test.exs`): one `Retention.prune_all/1` pass with all three specs/27 rules and the specs/25 provider-owned `prune_participation_revocation_links/1` rule simultaneously due — all four category counts correct in the same pass, no duplicate `prune_all/1` map keys, provider rule unaffected, repeat pass fully idempotent (all zero).
- Proof receipts:
  - Result: 19 passed (Task 3's own two files); 40 passed re-running all four specs/27 test files together after the moduledoc correction.
  - Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_security_log_retention_test.exs test/sdd_orchestrator/privacy/participation_operational_retention_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- `capability:participation-operational-retention` is now ready (Task 3 complete, proof passed). Downstream consumers: specs/12 Task 9, specs/26 (already ready, unaffected), specs/28 Task 1, specs/29 Task 1.
- Remaining: Slice verification gate (mix check pieces, browser matrix, prod release, validators).
- Failed checks: None.
- Spec updates: Task 3 checkbox/status line; slice Status updated to reflect all three tasks complete and the capability ready.

### 2026-08-14 — Task 2 complete: account-notification retention

- Completed: Added `prune_participation_notifications/1` to `Privacy.Retention`, mirroring `prune_delivery_notifications/1` exactly (90-day window, `like(event_type, "participation.%")`, no `read_at` filter — both read and unread rows are eligible), registered under `expired_participation_notifications` in `prune_all/1`. Namespace isolation proven both ways: a `delivery.*` row and an out-of-vocabulary row (inserted directly, bypassing the changeset's closed-vocabulary validation, to prove the DB has no constraint doing this job) are never selected.
- Scope classification: unchanged.
- Remaining: Task 3, then the verification gate.
- Failed checks: None.
- Proof receipts:
  - Result: 10 passed.
  - Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_account_notification_retention_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- Spec updates: Task 2 checkbox/status line only.

### 2026-08-14 — Task 1 complete: email-delivery diagnostic retention

- Completed: Added `prune_participation_email_delivery_diagnostics/1` to `Privacy.Retention` (30-day window, finalized `"sent"`/`"failed"` rows only, eligibility timestamp `COALESCE(delivered_at, attempted_at)`, `"pending"` never selected), registered under `expired_participation_email_delivery_diagnostics` in `prune_all/1`, and a matching moduledoc paragraph. No new module — extends the existing shared retention runner per design.md's "One Shared Runner With Serialized Rule Ownership" decision.
- Confirmed: `ParticipationEmailDelivery.record_result/3` currently always sets `delivered_at` for `"sent"` and leaves it `nil` for `"failed"`, but no DB constraint enforces that pairing, so the `COALESCE` fallback is a defensive, spec-correct implementation of "last authoritative attempt or completion," not just a reflection of current call sites.
- Confirmed the provider-owned `prune_participation_revocation_links/1` (specs/25) is untouched and composes correctly with the new rule in the same `prune_all/1` pass.
- Proof receipts:
  - Result: 11 passed.
  - Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/privacy/participation_email_delivery_retention_test.exs` — exit `0`.
  - Confirmed independently by the orchestrating session, same command, same exit status.
- Remaining: Tasks 2 and 3, then the verification gate.
- Failed checks: None.
- Spec updates: Task 1 checkbox/status line only.

### 2026-08-02 — Focused child specification created

- Completed: Moved unfinished participation email-delivery, account-notification, and operational-security-log retention out of the Slice 08 umbrella without changing the approved 30-day and 90-day outcomes.
- Remaining: Publish `capability:participation-identity-lifecycle`, then implement serialized Tasks 1 through 3 and the verification gate.
- Failed checks: None. The individual validator and 29-specification capability graph pass; implementation has not started because the identity-lifecycle provider is unavailable.
- Proof receipts: None.
- Spec updates: Added focused local AC-01 through AC-03 ownership, one shared retention-runner boundary, explicit non-duplication of provider-owned revocation direct-link cleanup, standard slice and task sizes, and focused proof commands for every task.
