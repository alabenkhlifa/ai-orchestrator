# Project Participation Tasks

## Status

Blocked

## Active Slice

Deliver one project-owner email invitation through fresh invited-email proof and explicit acceptance into one active hosted-project participant authorization, with owner removal, participant self-leave, account-neutral failure, and a fail-closed current-participant handoff to Slice 07.

## Implementation Boundary

Included:

- Hosted-project participation settings and participant management.
- Account-neutral owner invitation by email without directory search.
- Protected invitation delivery, invited-email proof, explicit acceptance, and safe result behavior.
- One immutable owner and one active `Participant` role.
- Participant access to project specifications, feature content, comments, and run evidence with protected settings and credential denial.
- Project-specific display names and minimized email visibility.
- Seven-day, one-pending invitation lifecycle with invalidating resend, cancellation, decline, and fresh re-invitation.
- Event-specific invitation and participation notifications with minimized payloads.
- Atomic, idempotent, project-scoped participation creation.
- Current-participant authorization lookup and Slice 07 handoff.
- Owner removal, participant self-leave, and fail-closed authorization invalidation.
- Assignment clearing, owner responsibility handoff, historical attribution, and active-run continuity after removal or leave.
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
- Deferred criteria: none.
- Deferred entities: none.

Release gates:

- Deployment-specific email, hosting, identity, and infrastructure processors, regions, transfer safeguards, notices, incident handling, and enforced retention evidence.
- Final accountable privacy or legal review for invitation, participation, delivery, support, and security processing.
- Release criteria: none.
- Release entities: none.

## Tasks

- [ ] Task 1 — Approve the participation product, technical, privacy, and verification contracts.
  - Depends on: none
  - Purpose: Resolve architecture, data-lifecycle, and proof decisions before implementation.
  - Owned surfaces: Active-slice outcome and scope, participant capability contract, invitation workflow and lifecycle, display-name maintenance and notification rules, visibility, removal and leave handoff, technical design, privacy data contract, release gates, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Proof: Requirements, design, data contracts, task ownership, task sequence, acceptance-criterion and entity traceability, and canonical verification commands have no unresolved active-slice blockers.

- [ ] Task 2 — Deliver account-neutral hosted-project invitation.
  - Depends on: Task 1
  - Purpose: Let the owner invite one email without granting access or exposing whether an account exists.
  - Owned surfaces: `ProjectInvitation`, `ParticipationNotification`, owner authorization, hosted-project eligibility, participation-settings invitation form, email validation, no-directory boundary, seven-day expiry, one-pending uniqueness, current-participant detection, invalidating resend, protected invitation state and credential, invitation, resend, cancellation, and removal email contract foundation, owner expiry notification, delivery integration, minimized notification payload, account-neutral acknowledgement and failure, cancellation state, fresh re-invitation, fixtures, logs, and responsive accessible browser behavior.
  - Owns: AC-01, AC-02, AC-06, AC-10, AC-18, AC-21, entity:ProjectInvitation, entity:ParticipationNotification
  - Proof: Domain, integration, delivery, security, time, and browser tests cover owner and non-owner requests, hosted and device projects, existing and unknown emails, current participants, no directory or account disclosure, protected credentials, seven-day expiry, one pending invitation, resend invalidation, fresh re-invitation, invitation, resend, cancellation and expiry notifications, minimized payloads, delivery success and failure, and unchanged project authorization.

- [ ] Task 3 — Deliver invited-email proof and atomic participation acceptance.
  - Depends on: Task 2
  - Purpose: Create project access only after fresh proof of the invited email and explicit acceptance.
  - Owned surfaces: `ProjectParticipant`, invited-email proof handoff, invitation and browser-flow binding, project and consequence disclosure after proof, project-specific display-name capture and validation, explicit acceptance and decline actions, acceptance participant and owner in-product notification, decline owner notification, minimized notification payload, stable hosted-identity binding, single-use consumption, uniqueness, transaction, idempotency, concurrency, rollback, safe invalid and replay result, fixtures, and responsive accessible browser behavior.
  - Owns: AC-03, AC-04, AC-12, AC-19, AC-22, entity:ProjectParticipant
  - Proof: Domain, transaction, concurrency, fault-injection, notification, security, and browser tests cover matching and different email proof, explicit acceptance, decline, invalid, canceled, expired, replayed, already-consumed, concurrent, retry, rollback, account-neutral failure, acceptance and decline notification recipients and payloads, and exactly one active participant.

- [ ] Task 4 — Deliver participant management and current authorization.
  - Depends on: Task 3
  - Purpose: Expose current project-scoped participation and end access safely through owner removal or participant self-leave.
  - Owned surfaces: Approved participant and invitation list fields, participant-controlled project-specific display-name changes, trimmed case-insensitive uniqueness, conflict rejection without suffix, owner-only membership email visibility, participant self-email visibility, other-email non-disclosure, owner and participant role presentation, participant project-content capabilities, protected management, destructive-setting and credential denials, project-scope authorization, current-participant read interface, Slice 07 consumer contract, owner removal, participant self-leave, immutable-owner denial, current authorization invalidation, active-session and cache handoff, assignment clearing, owner question and review handoff, current and necessary last-name historical attribution, stable contribution-history seam for later privacy anonymization, active-run continuity, removal account-level and email notification, leave owner notification, minimized notification payload, fixtures, and responsive accessible browser behavior.
  - Owns: AC-05, AC-07, AC-08, AC-09, AC-11, AC-14, AC-15, AC-16, AC-17, AC-20, AC-23
  - Proof: Domain, authorization, integration, concurrency, notification, privacy, and browser tests cover current and stale membership, project and workspace isolation, allowed project-content capabilities, protected management, settings and credentials, display-name editing, normalization, uniqueness, conflict and history, email visibility, owner-only management, self-leave, removal, immutable owner, repeated actions, consumer reads, cache and session behavior, assignment clearing, owner responsibility handoff, historical attribution, active-run continuity, removal and leave notification recipients and minimized payloads, and immediate denial without participation mutation.

- [ ] Task 5 — Enforce the participation privacy and security contract.
  - Depends on: Task 2, Task 3, Task 4
  - Purpose: Govern invitation, identity, participation, delivery, audit, support, log, derived, processor, and rights data without creating an identity directory or indefinite social graph.
  - Owned surfaces: Active processing inventory; purpose, lawful-basis, necessity, access, retention, deletion, rights, processor, transfer, backup, cache, index, export, support, audit, and security-log enforcement; historical-attribution necessity decision, verified anonymization workflow, stable contribution preservation, account-link and display-label removal, derived-copy propagation and backup expiry; invitation and identity enumeration resistance; secret and project-content redaction; negative credential transfer; aggregate genuinely anonymous analytics; cleanup operations; and required privacy and security review.
  - Owns: AC-13, AC-24, AC-25
  - Proof: Data-inventory, purpose and basis, access, retention, deletion, rights, historical-attribution necessity, verified anonymization, stable contribution preservation, account-link and display-label removal, derived-copy and backup propagation, processor, transfer, cache, log, directory and enumeration, secret-exposure, project-content exposure, credential-transfer, audit-minimization, negative secondary-use, and anonymous-analytics checks pass with the required privacy and security review.

## Verification Gate

- [ ] Every active acceptance criterion and data entity has one clear primary task owner.
- [ ] Hosted-project owner invitation, no-directory, and account-neutral request and failure scenarios pass.
- [ ] Seven-day expiry, one-pending uniqueness, invalidating resend, cancellation, decline, current-participant handling, and fresh re-invitation lifecycle tests pass.
- [ ] Fresh invited-email proof, explicit acceptance, single-use, uniqueness, idempotency, concurrency, rollback, and no-partial-state tests pass.
- [ ] Project, workspace, identity, owner, participant, and cross-user isolation tests pass.
- [ ] Owner removal, participant self-leave, immutable-owner, stale authorization, session or cache invalidation, and Slice 07 current-participant consumer tests pass.
- [ ] Display-name editing, trimming, case-insensitive uniqueness, no automatic suffix, current-name presentation, necessary last-name historical attribution, verified anonymization, account-link removal, and stable contribution-history tests pass.
- [ ] Invitation, acceptance, decline, expiry, cancellation, removal, and leave notifications pass channel, recipient, account-neutrality, minimization, and failure checks.
- [ ] Invitation and participation UI passes desktop, mobile, keyboard, focus, non-color, responsive, and accessibility scenarios.
- [ ] GDPR data contract, lifecycle enforcement, rights, processor, transfer, no-directory, secret-redaction, audit, and anonymous-analytics checks pass.
- [ ] Build, formatting, lint, static, security, production, delivery, and browser checks pass.
- [ ] New decisions and invalidated proof are written back.

## Blocked Decisions

- Technical design: resolve invitation persistence and delivery, proof binding, atomic membership, current-authorization invalidation, and consumer contracts.
- Privacy and security design: approve purposes, lawful bases, necessity, access, retention, deletion, rights, processor, transfer, audit, support, and no-directory controls.
- Verification design: define canonical automated, security, privacy, concurrency, failure, delivery, production, and browser commands.

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
