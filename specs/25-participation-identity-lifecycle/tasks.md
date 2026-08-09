# Participation Identity Lifecycle Tasks

## Status

In Progress

All four tasks are complete. Task 3 was reopened once when integrated proof showed its derived-revocation anonymization could no longer find an already-acknowledged handoff; the approved fix correlates through `project_participant_id`, which acknowledgement and retention never clear. Task 4's compatibility suite proves all three repairs compose without regressing current authorization, the Slice 07 revocation consumer, or notification minimization. `capability:participation-identity-lifecycle` is ready. Remaining: the slice verification gate.

Parallel-slice check (2026-08-09): reviewed against concurrently active slices 15 (Repository SDD Kit Integration) and 16 (Empty Repository Initialization). This slice owns only the `Participation` context (`ProjectParticipant`, `ProjectMemberProfile`, `ParticipationRevocation`); no shared schema, migration, context, or UI with either slice. Partitioned by ownership — no serialization required.

## Active Slice

Repair the departed-participant identity lifecycle across fresh re-acceptance, bounded revocation-link retention, and ordered verified-rights anonymization, then publish one compatibility capability for downstream participation privacy work.

## Cross-Specification Dependencies

Requires:

- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.

Provides:

- `capability:participation-identity-lifecycle` — ready after `Task 4`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Every task is `Size: Standard`, owns one independently provable identity-lifecycle outcome or focused compatibility gate, and has focused proof expected to run in about ten minutes.
- Tasks 1, 2, and 3 have disjoint primary module ownership and may run in parallel; Task 4 depends on all three and publishes readiness only after their contracts agree.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Fresh-acceptance reuse of a linked historical participant profile.
- New-profile creation only when no linked historical profile exists.
- Permanent non-relinking of anonymized historical profiles.
- Explicit identity-lifecycle error classification and atomic rollback.
- Former account and hosted-identity cleanup on acknowledgement or at 30 days.
- Verified current-participant departure before historical anonymization.
- Verified pending-handoff necessity override after departure.
- Focused compatibility proof and capability readiness.

Excluded:

- Invitation proof, email/template, current-authorization, or Slice 07 consumer redesign.
- Owner departure, ownership transfer, project deletion, or general legal adjudication.
- Participation delivery, notification, log, backup, processor, transfer, or general governance work outside the named lifecycle rules.
- Rewriting, deleting, or relinking anonymized or immutable contribution history.

Deferred after this slice:

- Wider participation processing, logging, backup, propagation, governance, and release evidence remain in their focused specifications.

Release gates:

- Deployment-specific rights notices, controller procedure, response periods, processor evidence, transfer safeguards, and accountable privacy or legal approval remain required for release but do not block local implementation or verification.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Repair fresh re-acceptance after departure.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Restore participation through fresh proof without duplicating linked historical presentation or relinking anonymized history.
  - Owned surfaces: `Participation.Acceptance` linked-profile lookup and transaction, `ProjectMemberProfile` historical reactivation changeset, fresh `ProjectParticipant` activation, newly accepted display-name validation, anonymized-profile exclusion, new-profile fallback, typed identity-lifecycle failures, rollback and concurrent replay behavior, notifications, fixtures, and focused tests.
  - Owns: AC-01, AC-02, AC-03, entity:ProjectParticipant, entity:ProjectMemberProfile
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/participation/reacceptance_test.exs` passes focused removed, left, fresh proof, same-profile identifier, new label, no-linked-profile, anonymized-history, new-profile, uniqueness, invalid-label, typed-conflict, rollback, replay, concurrency, invitation, and notification cases.

- [x] Task 2 — Enforce revocation former-identity cleanup.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Stop retaining former account and hosted-identity routing links once acknowledged and no later than 30 days.
  - Owned surfaces: `ParticipationRevocation` identity-release changeset, atomic `Revocations.acknowledge/3` cleanup, 30-day `occurred_at` selector, shared locked `Privacy.Retention.prune_all/1` integration, stable handoff preservation, active authorization non-mutation, idempotency, lock, restart, reconciliation, fixtures, and focused tests.
  - Owns: AC-04, entity:ParticipationRevocation
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/participation_revocation_retention_test.exs test/sdd_orchestrator/participation/revocations_test.exs` passes focused acknowledgement, 29-day, 30-day, acknowledged, unacknowledged, both former links, stable handoff, active authorization, idempotency, lock, restart, and reconciliation cases.

- [x] Task 3 — Complete the verified participant-anonymization workflow.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give an approved verified request an ordered path from current participation to anonymous historical attribution without weakening direct fail-closed behavior.
  - Owned surfaces: `Privacy.Rights` verified participation-anonymization orchestration, verified stable account and hosted-identity scope, current-participant detection, authoritative self-departure invocation, direct active-anonymization refusal, post-departure verified anonymization, pending-handoff necessity override, unverified necessity denial, retryable incomplete result, no-access-restoration guard, `project_participant_id`-correlated derived revocation anonymization, fixtures, and focused tests.
  - Owns: AC-05, AC-06
  - Proof: `python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/participation/identity_rights_workflow_test.exs test/sdd_orchestrator/participation/historical_attribution_test.exs` passes focused current, departed, verified, unverified, wrong identity, cross-project, owner refusal, departure ordering, pending handoff, retry, stable history, derived revocation, linkability-negative, and no-restored-access cases.

- [x] Task 4 — Prove identity-lifecycle compatibility and publish readiness.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2, Task 3
  - Purpose: Confirm the three repairs compose without changing current authorization, invitation safety, revocation consumption, notifications, or stable history before downstream work consumes them.
  - Owned surfaces: Cross-workflow lifecycle compatibility contract and fixtures, fresh accept to depart to acknowledge or rights-anonymize scenarios, current-participant authorization regression, invitation atomicity regression, Slice 07 revocation-consumer contract regression, notification minimization regression, historical-profile and handoff reference stability, `capability:participation-identity-lifecycle` provider, proof receipt, and readiness write-back.
  - Owns: none
  - Proof: `python3 .agents/scripts/run_proof.py task --task 4 -- mix test test/sdd_orchestrator/participation/identity_lifecycle_compatibility_test.exs` passes focused re-acceptance, authorization, departure, acknowledgement cleanup, rights anonymization, revocation-consumer, notification, stable-reference, fail-closed, project-isolation, and capability-readiness cases.

## Verification Gate

- [ ] All six acceptance criteria pass through the fresh re-acceptance, departure, acknowledgement, retention, and verified-rights workflows.
- [ ] Concurrent and replayed acceptance leaves one active authorization and the correct active profile without changing anonymized history.
- [ ] Acknowledgement and 30-day cleanup clear only former-participant identity links and preserve stable handoff and active authorization contracts.
- [ ] Verified and unverified rights paths prove departure ordering, pending-handoff handling, retry safety, stable history, and no restored access.
- [ ] Current participant authorization, Slice 07 revocation consumption, invitation atomicity, and notification minimization regressions pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass for the repository browser matrix.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.
- [ ] New decisions and proof receipts are written back.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
