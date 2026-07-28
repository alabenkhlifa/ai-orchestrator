# Project Participation Tasks

## Status

Not Started

The product, technical, privacy, handoff, task-sequence, and verification
contracts are approved. Task 2 is ready to begin; Slice 07 remains a downstream
consumer and is not an implementation prerequisite for this slice.

## Active Slice

Deliver one project-owner email invitation through fresh invited-email proof and explicit acceptance into one active hosted-project participant authorization, with owner removal, participant self-leave, account-neutral failure, and a fail-closed current-participant handoff to Slice 07.

## Implementation Boundary

Included:

- Hosted-project participation settings and participant management.
- Account-neutral owner invitation by email without directory search.
- Protected invitation delivery, invited-email proof, explicit acceptance, and safe result behavior.
- One immutable owner and one active `Participant` role.
- Project-specific owner and participant display profiles under one uniqueness boundary.
- Read-only project-capability decisions for later specification, feature-content, comment, and run-evidence consumers with protected settings and credential denial.
- Project-specific display names and minimized email visibility.
- Seven-day, one-pending invitation lifecycle with invalidating resend, cancellation, decline, and fresh re-invitation.
- Event-specific invitation and participation notifications with minimized payloads.
- Atomic, idempotent, project-scoped participation creation.
- Current-participant authorization lookup and Slice 07 handoff.
- Owner removal, participant self-leave, and fail-closed authorization invalidation.
- A versioned durable revocation handoff produced atomically on removal or leave without mutating Slice 07 records.
- Privacy, security, delivery, audit, lifecycle, and responsive browser proof.

Excluded:

- On-device project collaboration.
- Workspace-wide or organization-wide membership.
- Searchable user or account discovery.
- Roles beyond immutable `Owner` and `Participant`.
- Ownership transfer, owner removal, and owner leave.
- Public, anonymous, domain-wide, group, or team access.
- Slice 07 feature assignment, agent-run, review, evidence, preview, and notification implementation.
- Credential transfer or sharing.

Deferred after this slice:

- Additional roles, custom permissions, delegated participation administration, and organization or workspace membership.
- Project ownership transfer and owner departure.
- Public links, guest tiers, groups, teams, and domain-managed access.
- Slice 07 consumption of the revocation handoff for assignment clearing, question and review fallback, historical contribution presentation, notification denial, and active-run control.
- Deferred criteria: none.
- Deferred entities: none.

Release gates:

- Deployment-specific email, hosting, identity, and infrastructure processors, regions, transfer safeguards, notices, incident handling, and enforced retention evidence.
- Final accountable privacy or legal review for invitation, participation, delivery, support, and security processing.
- Release criteria: none.
- Release entities: none.

## Tasks

- [x] Task 1 — Approve the participation product, technical, privacy, and verification contracts.
  - Depends on: none
  - Purpose: Resolve architecture, data-lifecycle, and proof decisions before implementation.
  - Owned surfaces: Active-slice outcome and scope, participant capability contract, invitation workflow and lifecycle, owner and participant display-name rules, invitation-bound proof and browser-session behavior, visibility, notification rules, one-way removal and leave handoff, PostgreSQL and concurrency design, privacy data contract, release gates, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Proof: Requirements, design, data contracts, task ownership, task sequence, acceptance-criterion and entity traceability, and canonical verification commands have no unresolved active-slice blockers.

- [ ] Task 2 — Deliver account-neutral hosted-project invitation.
  - Depends on: Task 1
  - Purpose: Let the owner invite one email without granting access or exposing whether an account exists.
  - Owned surfaces: `ProjectInvitation`, `ProjectParticipant` persistence and current-role query foundation, `ProjectMemberProfile`, shared account-level `AccountNotification`, `ParticipationEmailDelivery`, owner authorization, hosted-project eligibility, owner display-profile prerequisite and editing foundation, one owner-and-participant display-name uniqueness boundary, participation-settings invitation form, established email normalization, encrypted delivery address and protected comparison digest, no-directory boundary, seven-day expiry, one-pending uniqueness, owner and current-participant detection, invalidating resend, salted-digest invitation credential, invitation, resend, cancellation, and removal email contract foundation, owner expiry notification, shared email-delivery adapter, durable in-product unread and read state, event-recipient-version idempotency, minimized notification payload, account-neutral acknowledgement and failure, cancellation state, fresh re-invitation, fixtures, logs, and responsive accessible browser behavior.
  - Owns: AC-01, AC-02, AC-06, AC-10, AC-18, AC-21, AC-26, AC-29, entity:ProjectInvitation, entity:ProjectParticipant, entity:ProjectMemberProfile, entity:AccountNotification, entity:ParticipationEmailDelivery
  - Proof: Domain, persistence, constraint, integration, delivery, security, time, and browser tests cover owner-profile prerequisite and editing, owner-and-participant label uniqueness, owner and non-owner requests, hosted and device projects, existing and unknown emails, owner and current-participant detection without unrelated account disclosure, protected email and credential fields, seven-day expiry, one pending invitation, resend invalidation, fresh re-invitation, invitation, resend, cancellation and expiry notifications, durable unread and read state, replay idempotency, minimized payloads, delivery success and failure, and unchanged project authorization.

- [ ] Task 3 — Deliver invited-email proof and atomic participation acceptance.
  - Depends on: Task 2
  - Purpose: Create project access only after fresh proof of the invited email and explicit acceptance.
  - Owned surfaces: Invitation-bound fresh email proof, warning and identity transition when another hosted identity is active, invited stable-identity session establishment without unrelated server-side session revocation, invitation and browser-flow binding, project and owner-display-name disclosure after proof, project-specific participant display-profile capture and validation, explicit acceptance and decline actions, acceptance participant and owner in-product notification, decline owner notification, minimized notification payload, stable hosted-identity binding, one `Ecto.Multi` acceptance transaction, row locking, single-use consumption, uniqueness, idempotency, concurrency, rollback, safe invalid and replay result, fixtures, and responsive accessible browser behavior.
  - Owns: AC-03, AC-04, AC-12, AC-16, AC-19, AC-22, AC-28
  - Proof: Domain, transaction, concurrency, fault-injection, notification, session, security, and browser tests cover matching and different email proof, another active browser identity, warning and session transition without unrelated session revocation, explicit acceptance, owner and participant label conflicts, decline, invalid, canceled, expired, replayed, already-consumed, concurrent, retry, rollback, account-neutral failure, acceptance and decline notification recipients and payloads, and exactly one active participant.

- [ ] Task 4 — Deliver participant management and current authorization.
  - Depends on: Task 3
  - Purpose: Expose current project-scoped participation and end access safely through owner removal or participant self-leave.
  - Owned surfaces: `ParticipationRevocation`, approved participant and invitation list fields, owner and participant self-controlled display-name changes, trimmed case-insensitive uniqueness, conflict rejection without suffix, owner-only membership email visibility, participant self-email visibility, other-email non-disclosure, owner and participant role presentation, read-only approved project-capability decisions, protected management, destructive-setting and credential denials, project-scope authorization, current-participant read interface, owner removal, participant self-leave, immutable-owner denial, immediate current-authorization invalidation without long-lived caching, atomic versioned revocation-handoff insertion, idempotent handoff claim and acknowledgement, owner fallback and last-label payload minimization, stable Slice 07 producer contract without consumer-record mutation, necessary historical-label seam for later privacy anonymization, removal account-level and email notification, leave owner notification, minimized notification payload, fixtures, and responsive accessible browser behavior.
  - Owns: AC-05, AC-07, AC-08, AC-09, AC-11, AC-14, AC-15, AC-17, AC-20, AC-23, AC-27, AC-30, entity:ParticipationRevocation
  - Proof: Domain, authorization, transaction, outbox-contract, concurrency, notification, privacy, and browser tests cover current and stale membership, project and workspace isolation, allowed and denied project-capability decisions, protected management, settings and credentials, display-name editing and history, email visibility, owner-only management, self-leave, removal, immutable owner, repeated actions, direct fail-closed reads without authorization-cache staleness, exactly-one versioned handoff insertion, claim and acknowledgement replay, minimized owner-fallback and historical-label payload, absence of Slice 07 record mutation, removal and leave notification recipients and minimized payloads, and immediate denial without session revocation.

- [ ] Task 5 — Enforce the participation privacy and security contract.
  - Depends on: Task 2, Task 3, Task 4
  - Purpose: Govern invitation, identity, participation, delivery, audit, support, log, derived, processor, and rights data without creating an identity directory or indefinite social graph.
  - Owned surfaces: Active processing inventory; purpose, lawful-basis, necessity, access, retention, deletion, rights, processor, transfer, backup, cache, index, export, support, audit, and security-log enforcement; seven-day pending-invitation expiry; immediate terminal credential erasure; 30-day terminal invitation, delivery-diagnostic, departed-identity-link, and security-log cleanup; 90-day in-product notification cleanup; 35-day encrypted-backup expiry; historical-attribution necessity decision, verified anonymization workflow, stable contribution preservation, account-link and display-label removal, derived-copy propagation; invitation and identity enumeration resistance; secret and project-content redaction; negative credential transfer; aggregate genuinely anonymous analytics; cleanup reconciliation; and required privacy and security review.
  - Owns: AC-13, AC-24, AC-25
  - Proof: Data-inventory, purpose and basis, access, retention, deletion, rights, historical-attribution necessity, verified anonymization, stable contribution preservation, account-link and display-label removal, derived-copy and backup propagation, processor, transfer, cache, log, directory and enumeration, secret-exposure, project-content exposure, credential-transfer, audit-minimization, negative secondary-use, and anonymous-analytics checks pass with the required privacy and security review.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Every active acceptance criterion and data entity has one clear primary task owner.
- [ ] Hosted-project owner invitation, no-directory, and account-neutral request and failure scenarios pass.
- [ ] Seven-day expiry, one-pending uniqueness, invalidating resend, cancellation, decline, current-participant handling, and fresh re-invitation lifecycle tests pass.
- [ ] Fresh invited-email proof, explicit acceptance, single-use, uniqueness, idempotency, concurrency, rollback, and no-partial-state tests pass.
- [ ] Project, workspace, identity, owner, participant, and cross-user isolation tests pass.
- [ ] Owner removal, participant self-leave, immutable-owner, direct fail-closed authorization, session preservation, and the versioned Slice 07 producer-contract tests pass without mutating consumer-owned records.
- [ ] Owner and participant display-name creation and editing, trimming, shared case-insensitive uniqueness, no automatic suffix or email-derived owner fallback, current-name presentation, necessary last-name historical attribution, verified anonymization, account-link removal, and stable contribution-history tests pass.
- [ ] Invitation, acceptance, decline, expiry, cancellation, removal, and leave notifications pass channel, recipient, account-neutrality, minimization, and failure checks.
- [ ] Invitation and participation UI passes desktop, mobile, keyboard, focus, non-color, responsive, and accessibility scenarios.
- [ ] GDPR data contract, lifecycle enforcement, rights, processor, transfer, no-directory, secret-redaction, audit, and anonymous-analytics checks pass.
- [ ] `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [ ] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass.
- [ ] New decisions and invalidated proof are written back.

## Blocked Decisions

- None.

## Progress Log

### 2026-07-27 - Initial project-participation draft

- Completed: Isolated project participation from Slice 07 and approved one hosted-project scope, immutable owner plus participant role, owner email invitation without directory search, fresh invited-email proof and explicit acceptance, participant project-content access with protected settings and credentials, project-specific unique and participant-controlled display names with minimized email visibility, seven-day single-pending invitation lifecycle, event-specific notifications, owner removal, participant self-leave, historical attribution, and owner handoff for active responsibility and runs.
- Remaining: Resolve technical, privacy, and verification decisions.
- Failed checks: None; implementation has not started.
- Spec updates: Created the focused participation prerequisite and first end-to-end invitation, acceptance, authorization, removal, and leave slice; completed the product agreement for capability, display identity, visibility, invitation lifecycle, notifications, and removal handoff; and kept workspace, organization, public-link, ownership-transfer, and Slice 07 implementation outside this slice.

### 2026-07-28 - Historical-attribution privacy constraint

- Completed: Clarified that departed-participant display attribution is retained only while necessary for project accountability and must be anonymized by an approved rights or deletion workflow without erasing stable contribution history.
- Remaining: Resolve the existing technical, privacy, and verification decisions, including the necessity test, derived-copy propagation, and backup expiry mechanism.
- Failed checks: None; implementation has not started.
- Spec updates: Added stable anonymization acceptance coverage, assigned its implementation to the privacy task, and preserved Task 4 ownership of removal, authorization invalidation, and the contribution-history seam.

### 2026-07-28 - Participation implementation contract refined and unblocked

- Completed: Approved the project-owner display profile, invitation-bound browser identity transition, hosted persistence and concurrency model, shared email and in-product notification foundation, direct fail-closed authorization, one-way versioned revocation handoff, bounded privacy lifecycle, canonical verification gate, and forward-dependency-free task sequence.
- Remaining: Implement Tasks 2–5 and complete the verification gate. Slice 07 separately consumes the delivered current-participant and revocation contracts.
- Failed checks: None; implementation has not started.
- Spec updates: Changed task status from `Blocked` to `Not Started`, completed Task 1, added stable AC-26 through AC-30 and the new data entities, moved Slice 07 record mutation out of this slice, assigned every active surface to one primary task, and resolved all active design blockers.
