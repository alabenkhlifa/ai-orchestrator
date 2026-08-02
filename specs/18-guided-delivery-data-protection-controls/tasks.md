# Guided Delivery Data Protection Controls Tasks

## Status

Blocked

The approved controls depend on the completed Slice 07 data surfaces being published and on the notification-access capability from `specs/17-guided-delivery-notification-access`, which is not yet available.

## Active Slice

Classify every Slice 07 field and transfer, enforce current-participant and exceptional-support access, exclude secrets and raw provider content, prohibit analytics and secondary use, and prove the negative routing boundary without implementing retention, rights, deletion, or deployment approval.

## Cross-Specification Dependencies

Requires:

- `capability:guided-delivery-data-surfaces` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 1`.
- `capability:guided-delivery-notification-access` — provider `specs/17-guided-delivery-notification-access#Task 4` — required before `Task 1`.

Provides:

- `capability:guided-delivery-processing-controls` — ready after `Task 4`.
- `capability:guided-delivery-purpose-limitation` — ready after `Task 5`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Field-level processing inventory and purpose or basis validation.
- Project-participant and exceptional-support access controls.
- Credential, participant-email, project-content, and raw-provider-event exclusion.
- Backend and integration prohibition of product analytics and secondary use.

Excluded:

- Retention, backup expiry, project deletion, external-cleanup reconciliation, rights handling, or anonymization.
- Deployment-specific processor evidence, controller details, regions, transfers, notices, incidents, DPIA state, or legal approval.
- Changes to approved guided-delivery product behavior.

Deferred after this slice:

- Operational retention, device relay and cache retention, project deletion, rights and anonymization, and deployment governance in focused child specifications.

Release gates:

- None; deployment-specific processor and transfer evidence belongs to the guided-delivery deployment-governance specification.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [ ] Task 1 — Implement the Slice 07 processing inventory.
  - Size: Standard
  - Proof scope: Focused
  - Status: Blocked until `capability:guided-delivery-data-surfaces` and `capability:guided-delivery-notification-access` are ready.
  - Depends on: none
  - Purpose: Give every guided-delivery field and transfer one mechanically valid purpose, basis, authority, recipient, minimum-field, and lifecycle classification.
  - Owned surfaces: `DataProcessingRecord`, migration and schema when required by the existing inventory, field-purpose map, contract-necessity and operational-security basis values, hosted and device authority, recipient and processor categories, transfer classification, lifecycle-owner references, validation, fixtures, and absence of governed content in inventory records.
  - Owns: AC-01, entity:DataProcessingRecord
  - Proof: `python3 .agents/scripts/run_proof.py task --task 1 -- mix test test/sdd_orchestrator/privacy/delivery_processing_inventory_test.exs` passes focused completeness, purpose, basis, authority, recipient, processor, transfer, lifecycle-owner, minimum-field, content-absence, and invalid-classification cases.

- [ ] Task 2 — Enforce project and exceptional-support access.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Keep project content inside current participation while allowing only verified, least-privilege, time-bounded, purpose-limited support elevation.
  - Owned surfaces: Current-participant project reads, stale, removed, absent and cross-project denial, metadata-only support default, exceptional-support capability issue and expiry, purpose and scope validation, revocation, minimized audit event, fixtures, and content-existence non-disclosure.
  - Owns: AC-02, AC-03
  - Proof: `python3 .agents/scripts/run_proof.py task --task 2 -- mix test test/sdd_orchestrator/privacy/delivery_access_controls_test.exs` passes focused participant, removal, cross-project, default-support, elevation, least-privilege, expiry, revocation, purpose, audit-minimization, and non-disclosure cases.

- [ ] Task 3 — Enforce delivery-boundary minimization and redaction.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 2
  - Purpose: Stop raw credentials, participant emails, raw provider events, and unauthorized project content before durable storage or participant exposure.
  - Owned surfaces: Shared delivery redaction contract, participant-authored free-text scan boundary, worker normalized-event allowlist, raw-provider-event rejection, notification and audit minimization checks, credential and email detection, refusal result, diagnostic field-name-only logging, fixtures, and negative persistence scans.
  - Owns: AC-04
  - Proof: `python3 .agents/scripts/run_proof.py task --task 3 -- mix test test/sdd_orchestrator/privacy/delivery_content_boundary_test.exs` passes focused credential, email, project-content, comment, review-feedback, worker-event, raw-provider, notification, audit, log, rejection, and no-persistence cases.

- [ ] Task 4 — Prohibit product analytics and secondary use.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1, Task 3
  - Purpose: Prevent guided-delivery data from becoming an analytics, advertising, training, unrelated-improvement, or stable-profile input.
  - Owned surfaces: Slice 07 store, request, event, metric, identifier and stable-profile negative contract, analytics configuration denial, advertising and training-use denial, unrelated processor denial, operational-telemetry classification, static diagnostic scans, fixtures, `capability:guided-delivery-processing-controls` provider, and readiness write-back.
  - Owns: AC-05
  - Proof: `python3 .agents/scripts/run_proof.py task --task 4 -- mix test test/sdd_orchestrator/privacy/delivery_purpose_limitation_test.exs` passes focused store, request, event, metric, identifier, profile, advertising, training, unrelated-use, telemetry-classification, and negative-scan cases.

- [ ] Task 5 — Prove browser, provider, and storage routing boundaries.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3, Task 4
  - Purpose: Confirm representative runtime paths do not transmit forbidden analytics, credentials, participant emails, provider reuse, or durable device-project copies.
  - Owned surfaces: Focused browser-network capture, worker command and event observation, model and preview adapter-double routing, hosted and device persistence scan, stable-identifier absence, raw-credential absence, participant-email absence, provider training-use configuration assertion, fixtures, proof harness, `capability:guided-delivery-purpose-limitation` provider, and readiness write-back.
  - Owns: AC-06
  - Proof: `python3 .agents/scripts/run_proof.py task --task 5 -- mix test test/sdd_orchestrator/privacy/delivery_routing_boundary_test.exs` passes focused browser-request, worker, model, preview, telemetry, hosted, device, credential, email, stable-identifier, and durable-copy cases without live provider access.

## Verification Gate

- [ ] All six acceptance criteria and the complete `DataProcessingRecord` traceability map pass.
- [ ] Current-participant, removed-participant, cross-project, and exceptional-support paths fail or authorize exactly as approved.
- [ ] Credential, participant-email, project-content, and raw-provider-event negative scans pass.
- [ ] No analytics, advertising, model-training reuse, secondary use, or durable hosted device-project copy is observed.
- [ ] Focused browser-network scenarios pass through `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e`.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice scope.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` passes before the browser matrix.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and both provided capability readiness write-backs are recorded.
- [ ] New decisions and proof receipts are written back.

## Blocked Decisions

- Active-slice implementation is blocked until `capability:guided-delivery-data-surfaces` and `capability:guided-delivery-notification-access` are ready; no product or technical-design decision is unresolved.

## Progress Log

### 2026-08-02 — Focused child specification created

- Completed: Moved unfinished processing, access, redaction, analytics, and secondary-use controls out of the Slice 07 umbrella without changing approved behavior.
- Remaining: Publish the completed guided-delivery data surfaces, complete notification access, then implement Tasks 1 through 5 and the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass; implementation has not started because required provider capabilities are unavailable.
- Proof receipts: None.
- Spec updates: Added focused ownership for processing inventory, project and support access, content boundaries, purpose limitation, and runtime negative proof.
