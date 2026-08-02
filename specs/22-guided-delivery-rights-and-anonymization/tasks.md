# Guided Delivery Rights And Anonymization Tasks

## Status

Blocked

The agreement is approved. Task 1 is blocked until the named participation, specification, notification, processing, retention, device, deletion, and revocation capabilities are ready.

## Active Slice

Deliver one verified guided-delivery rights workflow across authoritative and configured derived copies, including necessity-gated historical anonymization without another participant's data exposure or immutable-history rewriting.

## Cross-Specification Dependencies

Requires:

- `capability:guided-delivery-revocation-consumer` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-notification-governance` — provider `specs/17-guided-delivery-notification-access#Task 5` — required before `Task 1`.
- `capability:guided-delivery-processing-controls` — provider `specs/18-guided-delivery-data-protection-controls#Task 4` — required before `Task 1`.
- `capability:guided-delivery-operational-retention` — provider `specs/19-guided-delivery-operational-retention#Task 5` — required before `Task 1`.
- `capability:guided-delivery-device-transient-retention` — provider `specs/20-guided-delivery-device-data-retention#Task 2` — required before `Task 1`.
- `capability:guided-delivery-project-deletion-governance` — provider `specs/21-guided-delivery-deletion-and-recovery#Task 6` — required before `Task 1`.
- `capability:project-participation-governance` — provider `specs/08-project-participation#Task 5` — required before `Task 1`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 1`.

Provides:

- `capability:guided-delivery-rights-governance` — ready after `Task 6`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Every task is `Size: Standard`, owns one independently provable rights action or historical-attribution invariant, has at most three acceptance criteria and two entities, and has focused proof expected to run in about ten minutes.
- No task-size exception is used; complete repository, security, browser, production, and release proof stays at the slice gates.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Verified request and project-scope authorization.
- Access, export or portability, correction, restriction, objection, and erasure adapters.
- Hosted, device, notification, artifact, cache, log, backup, export, and configured processor propagation.
- Necessity-gated historical anonymization with stable neutral contribution history.

Excluded:

- Legal adjudication, ownership transfer, project deletion authorization, processor selection, and immutable-history rewriting.

Deferred after this slice:

- Jurisdiction-specific automated exception rules beyond the approved operator workflow.
- Deferred criteria: none.
- Deferred entities: none.

Release gates:

- Live configured processor, backup, export, and device rights-operation evidence.
- Deployment-specific notices, response periods, controller contact, identity-verification policy, transfer safeguards, and accountable privacy or legal review.
- Release criteria: none.
- Release entities: none.

## Tasks

- [ ] Task 1 — Authorize and scope guided-delivery rights requests.
  - Status: Blocked until every capability named for Task 1 is ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Select only the verified requester's applicable records without project or participant disclosure.
  - Owned surfaces: Verified operator and requester inputs, current and former participation resolution, project and action scope, adapter applicability plan, account-neutral denial, cross-participant and cross-project isolation, and fixtures.
  - Owns: AC-01
  - Proof: Focused verified, unverified, malformed, current, former, cross-participant, cross-project, and existence-nondisclosure tests pass through task scope.

- [ ] Task 2 — Deliver minimized access and portability output.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Assemble a protected request-bound export without creating a permanent rights-data copy.
  - Owned surfaces: Rights adapter discovery, hosted and device reads, artifact, notification, log, backup, export and processor result normalization, source and limitation metadata, output encryption and expiry, another-participant exclusion, and fixtures.
  - Owns: AC-02
  - Proof: Focused hosted, device, derived-copy, processor, minimized-output, source-metadata, encryption, expiry, and cross-participant tests pass through task scope.

- [ ] Task 3 — Correct mutable delivery identity and processing state.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Apply valid corrections without rewriting immutable delivery history.
  - Owned surfaces: Correctable-field registry, authoritative adapter mutations, correction provenance and effective time, immutable evidence, activity, review and revision guards, derived presentation refresh, and fixtures.
  - Owns: AC-03
  - Proof: Focused valid-field, forbidden-field, hosted, device, immutable-history, provenance, refresh, and rollback tests pass through task scope.

- [ ] Task 4 — Enforce restriction and objection safely.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Stop affected optional processing without unauthorized deletion or weakened security controls.
  - Owned surfaces: Restriction and objection state, affected-processing registry, optional-processing stops, required-security exception boundary, other-participant preservation, no-access-restoration guard, and fixtures.
  - Owns: AC-04
  - Proof: Focused restriction, objection, optional-processing stop, necessary-security preservation, shared-record preservation, and no-restored-access tests pass through task scope.

- [ ] Task 5 — Propagate approved erasure across configured copies.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Remove applicable personal data through the owning deletion and processor boundaries.
  - Owned surfaces: Erasure applicability map, hosted and device adapter actions, artifact, notification, cache, log, backup, export and processor deletion requests, restricted reconciliation linkage, access-denial invariant, and fixtures.
  - Owns: AC-05
  - Proof: Focused authoritative, derived-copy, processor, backup, export, partial-failure, retry-linkage, another-participant preservation, and access-denial tests pass through task scope.

- [ ] Task 6 — Anonymize historical attribution when identification is unnecessary.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Remove linkable identity while preserving stable accountable contribution history.
  - Owned surfaces: Necessity decision input, account and presentation de-linking, neutral former-participant presentation, stable contribution reference, email, hash, encrypted-identifier and pseudonym negative scans, derived-copy propagation, `capability:guided-delivery-rights-governance` provider, and readiness write-back.
  - Owns: AC-06
  - Proof: Focused necessity-current, necessity-ended, anonymization, stable-history, no-access-restoration, linkability-negative, propagation, and capability-readiness tests pass through task scope.

## Verification Gate

- [ ] All acceptance criteria pass across hosted and device-authoritative modes and every configured derived-copy adapter.
- [ ] Cross-participant, cross-project, existence-nondisclosure, immutable-history, no-restored-access, and linkability-negative suites pass.
- [ ] Access, export, correction, restriction, objection, erasure, and historical-anonymization end-to-end scenarios pass.
- [ ] `mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice-scoped proof-runner invocations.
- [ ] `npm --prefix assets ci` and the desktop and mobile operator and requester browser matrix pass through slice scope.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.

## Blocked Decisions

- Task 1 is blocked on unavailable provider capabilities; no product decision is unresolved.

## Progress Log

### 2026-08-02 - Focused rights and anonymization slice created

- Completed: Approved verified rights authorization, access and portability, correction, restriction and objection, erasure propagation, and necessity-gated historical anonymization split from the Slice 07 legacy plan.
- Scope classification: Standard focused slice with six tasks and a six-task critical path.
- Remaining: Wait for the named provider capabilities, then implement Tasks 1–6 and complete the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass with the coordinated continuation-specification update.
- Spec updates: Created requirements, design, capability ownership, task proof scope, traceability, and release boundaries for guided-delivery rights.
