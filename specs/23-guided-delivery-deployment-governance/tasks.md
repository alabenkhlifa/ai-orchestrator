# Guided Delivery Deployment Governance Tasks

## Status

Blocked

The agreement is approved. Task 1 is blocked until the purpose-limitation capability is ready; later validation also waits for the focused lifecycle, rights, and deletion capabilities.

## Active Slice

Create one versioned guided-delivery deployment privacy profile, bind it to start disclosure, and classify missing controller, processor, transfer, retention, deletion, notice, review, and live-enforcement evidence at the correct readiness stage.

## Cross-Specification Dependencies

Requires:

- `capability:guided-delivery-start-disclosure` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 2`.
- `capability:guided-delivery-artifact-preview-boundary` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 2`.
- `capability:guided-delivery-notification-governance` — provider `specs/17-guided-delivery-notification-access#Task 5` — required before `Task 3`.
- `capability:guided-delivery-purpose-limitation` — provider `specs/18-guided-delivery-data-protection-controls#Task 5` — required before `Task 1`.
- `capability:guided-delivery-operational-retention` — provider `specs/19-guided-delivery-operational-retention#Task 5` — required before `Task 3`.
- `capability:guided-delivery-device-transient-retention` — provider `specs/20-guided-delivery-device-data-retention#Task 2` — required before `Task 3`.
- `capability:guided-delivery-project-deletion-governance` — provider `specs/21-guided-delivery-deletion-and-recovery#Task 6` — required before `Task 3`.
- `capability:guided-delivery-rights-governance` — provider `specs/22-guided-delivery-rights-and-anonymization#Task 6` — required before `Task 3`.

Provides:

- `capability:guided-delivery-deployment-governance` — ready after `Task 3`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Every task is `Size: Standard`, owns one deployment-profile, disclosure-linkage, or readiness-classification outcome, has at most three acceptance criteria and two entities, and has focused proof expected to run in about ten minutes.
- No task-size exception is used; live deployment, full repository, browser, security, production, and accountable review proof stays at the slice or release gate.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Versioned deployment privacy profile and configured destination inventory.
- Start-disclosure linkage and material-boundary invalidation.
- Separate implementation, local-verification, and release readiness classification.
- Protected evidence references and reviewer states.

Excluded:

- Vendor selection, contract negotiation, legal conclusions, technical-control reimplementation, production deployment, and final guided-delivery capability publication.

Deferred after this slice:

- Multi-controller or organization-wide deployment governance.
- Deferred criteria: none.
- Deferred entities: none.

Release gates:

- Actual controller contact and notices; processor and recipient agreements; regions and transfer safeguards; provider retention and training-use settings; support and incident procedures; enforced deletion and backup expiry; any required DPIA or legal review; live configured adapter evidence; and final accountable privacy and security approval.
- Release criteria: none.
- Release entities: none.

## Tasks

- [ ] Task 1 — Implement the versioned deployment privacy profile.
  - Status: Blocked until `capability:guided-delivery-purpose-limitation` is ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Record the actual guided-delivery processing configuration and evidence state without secrets or project content.
  - Owned surfaces: `DeploymentPrivacyProfile`, migration and schema or configuration record, immutable versions, configured destination registry, purpose and data-category allowlists, controller and contact state, region and transfer state, retention and training-use state, support, incident, deletion, notice and review state, protected evidence references, authorization, fixtures, and rollback.
  - Owns: AC-01, entity:DeploymentPrivacyProfile
  - Proof: Focused migration, changeset, versioning, authorization, destination completeness, unknown and not-applicable state, forbidden secret and content, evidence-reference, and rollback tests pass through task scope.

- [ ] Task 2 — Bind start disclosure to the material deployment boundary.
  - Status: Blocked until `capability:guided-delivery-start-disclosure` and `capability:guided-delivery-artifact-preview-boundary` are ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Require participant confirmation after a material processing-boundary change without prompting for evidence-only edits.
  - Owned surfaces: Profile-version material digest, worker, model, preview, artifact, hosting, backup, region, transfer, retention and training-use mapping, participant-visible summary, confirmation lookup and invalidation, unchanged-boundary reuse, and fixtures.
  - Owns: AC-02
  - Proof: Focused first-use, each material-field change, evidence-only change, unchanged reuse, exact-version, missing-profile, and minimized-disclosure tests pass through task scope.

- [ ] Task 3 — Validate deployment evidence at the correct readiness stage.
  - Status: Blocked until the notification, operational-retention, device-retention, deletion, and rights capabilities named for Task 3 are ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Keep deterministic implementation and verification readiness separate from deployment release evidence.
  - Owned surfaces: Technical-capability inventory reconciliation, implementation, local-verification and release classifiers, earliest-stage reason codes, controller, notice, agreement, transfer, live deletion, backup, DPIA or legal, security and accountable approval evidence checks, stale-profile invalidation, `capability:guided-delivery-deployment-governance` provider, and readiness write-back.
  - Owns: AC-03
  - Proof: Focused complete, missing-field, missing-reference, stale-version, technical-capability mismatch, implementation-ready, verification-ready, release-blocked, release-ready, and capability-readiness tests pass through task scope.

## Verification Gate

- [ ] All acceptance criteria pass.
- [ ] Destination inventory, profile versioning, material-change disclosure, protected evidence, and staged-readiness suites pass.
- [ ] Authorization, secret and content exclusion, audit, no-analytics, and stale-evidence suites pass.
- [ ] `mix check` and the explicit formatting, warnings-as-errors, Credo, Dialyzer, dependency-audit, Sobelow, and test commands pass through slice-scoped proof-runner invocations.
- [ ] `npm --prefix assets ci` and the desktop and mobile deployment-profile, disclosure, and readiness browser matrix pass through slice scope.
- [ ] Production asset deployment and release assembly pass through slice scope with `MIX_ENV=prod`.
- [ ] The individual specification validator and global capability graph pass, and capability readiness is recorded.

## Blocked Decisions

- Task 1 is blocked on an unavailable provider capability; no product decision is unresolved.

## Progress Log

### 2026-08-02 - Focused deployment-governance slice created

- Completed: Approved the deployment profile, destination inventory, material start-disclosure linkage, protected evidence, and staged-readiness contracts split from the Slice 07 legacy plan.
- Scope classification: Standard focused slice with three tasks and a three-task critical path.
- Remaining: Wait for the named provider capabilities, then implement Tasks 1–3 and complete the verification gate and deployment release evidence.
- Failed checks: None. The individual specification validator and global capability graph pass with the coordinated continuation-specification update.
- Spec updates: Created requirements, design, capability ownership, task proof scope, traceability, and release boundaries for deployment governance.
