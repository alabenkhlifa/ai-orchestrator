# Project Participation Tasks

## Status

In Progress

`capability:project-participation-boundary` is ready: Tasks 1, 2, 3, 4, 6, 7, 8,
9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 25, 26, 27, and 29 are complete and
Slice 07 may consume the published boundary. Task 34 is complete, so
`capability:project-owner-display-profile` is ready: the owner profile is created
with the hosted project, earlier projects are backfilled, and `Boundary.owner/1`
no longer treats a missing presentation label as missing owner authorization.
Task 36 is now the next cross-specification repair: it makes active-participant
enumeration and recipient routing independent of `ProjectMemberProfile` and will
publish `capability:project-participation-recipient-routing` without reopening
the completed boundary task.
Task 35 is complete: the invitation action shows the owner label with an inline
correction and no longer blocks on it. The remaining lifecycle, retention,
rights, logging, backup, propagation, and governance tasks (20, 21, 22, 23, 24,
30, 31, 32, 33, and 5) are not started, so
`capability:project-participation-governance` is still unavailable and the slice
has not reached its verification gate. The authenticated participation browser
matrix now runs for real on desktop and mobile against a dev/test-only session
bootstrap, so no participation task carries an environment-blocked proof.

## Active Slice

Deliver one project-owner email invitation through fresh invited-email proof and explicit acceptance into one active hosted-project participant authorization, with owner removal, participant self-leave, account-neutral failure, and a fail-closed current-participant handoff to Slice 07.

## Cross-Specification Dependencies

Requires:

- None.

Provides:

- `capability:project-participation-boundary` — ready after `Task 4`.
- `capability:project-owner-display-profile` — ready after `Task 34`.
- `capability:project-participation-recipient-routing` — ready after `Task 36`.
- `capability:project-participation-governance` — ready after `Task 5`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Existing task labels are preserved; newly split tasks use the next unused labels and are listed by dependency order rather than numeric order.

## Proof Scope Gate

- Applies to: Task 36.

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
  - Size: Standard
  - Depends on: none
  - Purpose: Resolve architecture, data-lifecycle, and proof decisions before implementation.
  - Owned surfaces: Active-slice outcome and scope, participant capability contract, invitation workflow and lifecycle, owner and participant display-name rules, invitation-bound proof and browser-session behavior, visibility, notification rules, one-way removal and leave handoff, PostgreSQL and concurrency design, privacy data contract, release gates, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Proof: Requirements, design, data contracts, task ownership, task sequence, acceptance-criterion and entity traceability, and canonical verification commands have no unresolved active-slice blockers.

- [x] Task 6 — Implement participant and project-member profile persistence.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Establish the hosted authorization identity and separate project-specific presentation profile.
  - Owned surfaces: `ProjectParticipant`, `ProjectMemberProfile`, hosted migrations and schemas, immutable owner derivation, participant role, stable hosted-identity binding, active-participant uniqueness, owner-and-participant display-name comparison key, trimmed case-insensitive project uniqueness, accepted spelling, anonymization state, constraints, and fixtures.
  - Owns: AC-02, entity:ProjectParticipant, entity:ProjectMemberProfile
  - Proof: Focused migration, changeset, constraint, and domain tests cover owner derivation, active and inactive participation, stable identity binding, project isolation, unique display names, accepted spelling, conflicting names, invalid roles, and rollback.

- [x] Task 28 — Deliver the owner project-display profile workflow.
  - Size: Standard
  - Depends on: Task 6
  - Purpose: Let the owner maintain an understandable project label safely.
  - Owned surfaces: Owner self-edit action, participation-settings owner-profile form, no email-derived fallback, trimmed case-insensitive uniqueness, conflict correction, preserved spelling, authorization, fixtures, and responsive accessible browser behavior.
  - Owns: AC-30
  - Proof: Focused LiveView, authorization, validation, and browser tests cover successful creation and editing, conflicting labels, no suffix, no email presentation, non-owner denial, keyboard, focus, and mobile layout.
  - Superseded behavior: this task originally owned AC-26's missing-profile invitation gate. Task 34 removes the condition that gate detected and Task 35 owns the replacement presentation, so the gate and its blocking proof no longer apply.

- [x] Task 34 — Create the owner display profile with the hosted project.
  - Size: Standard
  - Depends on: Task 6, Task 28
  - Purpose: Make a hosted project usable by the person who just registered it, instead of making a presentation label a precondition for owner authorization.
  - Owned surfaces: `capability:project-owner-display-profile` provider, registration-transaction owner-profile creation, initial GitHub-login label derivation, non-email and non-suffix label rules, idempotent backfill of hosted projects registered before this rule, owner authorization independent of label existence, project-scoped uniqueness, processing-inventory entry for the derived label, fixtures, and rollback.
  - Owns: AC-40, AC-41
  - Proof: Focused registration, initial-label, no-email-derivation, absent-GitHub-login fallback, owner-authorization-without-label, backfill, backfill-idempotency, existing-label preservation, ownership and participation non-mutation, project-isolation, and rollback tests pass.

- [x] Task 7 — Implement the shared account-level notification foundation.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Provide durable recipient-scoped in-product notification storage reusable by participation and Slice 07.
  - Owned surfaces: `AccountNotification`, hosted migration and schema, approved recipient identity, event type and version, minimized body, safe link reference, unread and read state, event-recipient-version uniqueness, idempotent insertion and mark-read, account-boundary list and read authorization, PubSub presentation hint, fixtures, and extension seam for Slice 07 event types.
  - Owns: entity:AccountNotification
  - Proof: Focused migration, constraint, authorization, idempotency, replay, list, mark-read, restart, and PubSub-independent delivery tests pass without storing project content.

- [x] Task 8 — Implement participation email delivery.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Reuse one delivery adapter while keeping participation credentials and diagnostics isolated.
  - Owned surfaces: `ParticipationEmailDelivery`, shared email-delivery behaviour consumer, invitation, resend, cancellation, and removal email builders, encrypted recipient address, minimized diagnostic fields, event-recipient-version idempotency, success and failure state, provider configuration seam, log redaction, fixtures, and deterministic delivery double.
  - Owns: entity:ParticipationEmailDelivery
  - Proof: Focused adapter, builder, idempotency, success, failure, retry, encryption, diagnostic-minimization, and log-redaction tests pass without exposing invitation credentials or project content.

- [x] Task 2 — Deliver account-neutral hosted-project invitation creation.
  - Size: Standard
  - Depends on: Task 8, Task 28
  - Purpose: Let the owner invite one email without granting access or exposing whether an account exists.
  - Owned surfaces: `ProjectInvitation`, hosted migration and schema, owner authorization, hosted-project eligibility, participation-settings invitation form, established email normalization, encrypted delivery address, runtime-keyed comparison digest, salted-digest invitation credential, seven-day initial expiry, one-pending uniqueness, no-directory boundary, account-neutral acknowledgement and failure, transactional creation and email outbox, fixtures, logs, and responsive accessible browser behavior.
  - Owns: AC-01, AC-06, AC-10, entity:ProjectInvitation
  - Proof: Focused domain, persistence, authorization, constraint, delivery-outbox, security, and browser tests cover owner and non-owner requests, hosted and device projects, existing and unknown accounts with identical responses, protected email and credential fields, one pending invitation, delivery failure, and unchanged project authorization.

- [x] Task 35 — Present the owner display name in the invitation action.
  - Size: Standard
  - Depends on: Task 2, Task 28, Task 34
  - Purpose: Let the owner see and correct the label an invitee will read without blocking the invitation on it.
  - Owned surfaces: Invitation-action owner-label presentation, inline correction path reusing the shared availability and no-suffix rules, unblocked send with an unedited initial label, no email presented as a label, authorization, fixtures, and responsive accessible browser behavior.
  - Owns: AC-26
  - Proof: Focused presentation, inline-correction, conflict, no-suffix, no-email, unedited-send, non-owner denial, keyboard, focus, desktop, and mobile tests pass.

- [x] Task 9 — Detect existing project roles without account disclosure.
  - Size: Standard
  - Depends on: Task 2, Task 6
  - Purpose: Avoid creating credentials for the immutable owner or a current participant while exposing only already-authorized membership state.
  - Owned surfaces: Owner-email and active-participant detection through protected comparison, existing project-role result, no invitation or credential creation, no unrelated account lookup, constant account-neutral external result, owner-only role presentation, fixtures, and enumeration-resistant logs.
  - Owns: AC-29
  - Proof: Focused owner, current participant, unrelated existing identity, unknown email, normalization, timing-shape, persistence, and log tests prove no invitation or unrelated account disclosure.

- [x] Task 10 — Deliver invitation resend and fresh re-invitation.
  - Size: Standard
  - Depends on: Task 9
  - Purpose: Replace rather than duplicate the current invitation credential.
  - Owned surfaces: Owner-authorized resend and re-invitation actions, pending-row locking, prior credential invalidation, new salted credential, fresh seven-day expiry, one-pending constraint, terminal-state eligibility, idempotency, concurrency, replacement email outbox, fixtures, and inline result presentation.
  - Owns: AC-18
  - Proof: Focused state-machine, transaction, concurrency, replay, expiry, credential-rotation, one-pending, fresh-acceptance, delivery-outbox, and LiveView tests pass.

- [x] Task 25 — Deliver invitation cancellation and expiry.
  - Size: Standard
  - Depends on: Task 10
  - Purpose: End an invitation without creating access and require a fresh flow afterward.
  - Owned surfaces: Owner cancellation action, seven-day expiry transition, terminal state, immediate credential invalidation, repeated and concurrent transition safety, fresh-flow requirement, no participant mutation, expiry job or pruner seam, fixtures, and cancellation result presentation.
  - Owns: AC-34
  - Proof: Focused time-boundary, cancellation, expiry, repeat, concurrency, invalid credential, fresh-invitation, no-access, and LiveView tests pass.

- [x] Task 11 — Deliver invitation lifecycle email notifications.
  - Size: Standard
  - Depends on: Task 8, Task 25
  - Purpose: Notify the invitee of invitation, replacement, and cancellation through the approved email channel.
  - Owned surfaces: Invitation, resend, and cancellation email outbox consumption, correct current credential selection, canceled-message safe link behavior, minimized template context, account-neutral delivery result, replay idempotency, provider failure handling, and delivery diagnostics.
  - Owns: AC-21
  - Proof: Focused recipient, template, credential-version, safe-link, cancellation, replay, failure, minimization, and account-neutral delivery tests pass.

- [x] Task 26 — Deliver owner invitation-expiry notification.
  - Size: Standard
  - Depends on: Task 7, Task 25
  - Purpose: Tell the owner that one pending invitation expired without notifying an unauthorized invitee inside the product.
  - Owned surfaces: Expiry lifecycle event, owner-recipient resolution, minimized `AccountNotification`, unique event-recipient-version key, unread and read behavior, replay safety, safe participation-management link, and absence of invitee project notification.
  - Owns: AC-35
  - Proof: Focused projector, recipient, replay, minimized-payload, unread, mark-read, link-authorization, and negative invitee-notification tests pass.

- [x] Task 12 — Deliver invitation-bound fresh email proof.
  - Size: Standard
  - Depends on: Task 25
  - Purpose: Establish the invited stable hosted identity in the browser without treating an unrelated session as proof.
  - Owned surfaces: Invitation-bound proof token handoff, normalized invited-email binding, fresh passwordless verification reuse, different-email denial, active-other-identity warning, browser-cookie identity transition, unrelated server-side session preservation, proven-identity session establishment, pre-acceptance authorization denial, invalid and replay-safe result, fixtures, and responsive accessible browser behavior.
  - Owns: AC-28
  - Proof: Focused session, token-binding, matching and different email, active-other-identity, warning, cookie replacement, unrelated-session preservation, invalid, replay, and browser tests pass without granting project access.

- [x] Task 3 — Deliver atomic participation acceptance.
  - Size: Standard
  - Depends on: Task 6, Task 7, Task 12
  - Purpose: Create project access exactly once after valid proof and explicit acceptance.
  - Owned surfaces: Proven stable-identity and project binding, participant display-profile validation, explicit acceptance command, one `Ecto.Multi`, invitation row locking and consumption, active-participant and display-name constraints, acceptance notification outbox, single-use behavior, idempotency, concurrency, rollback, and safe invalid result.
  - Owns: AC-03, AC-04, AC-12
  - Proof: Focused transaction, constraint, concurrency, replay, already-consumed, invalid, canceled, expired, different-email, conflict, retry, rollback, and exactly-one-active-participant tests pass.

- [x] Task 13 — Deliver acceptance and decline interface.
  - Size: Standard
  - Depends on: Task 3
  - Purpose: Explain the identified project and consequence, collect the participant label, and require an explicit outcome.
  - Owned surfaces: Post-proof project and owner-display-name presentation, participant display-name form, availability validation, explicit accept and decline actions, safe invalid result, declined terminal state, fresh-flow requirement, no other-participant email, fixtures, and responsive accessible browser behavior.
  - Owns: AC-16, AC-19
  - Proof: Focused LiveView and desktop and mobile browser tests cover project and owner labels, available and conflicting participant names, explicit acceptance, decline, invalid and terminal invitations, no other email, keyboard, focus, and no access after decline.

- [x] Task 14 — Deliver acceptance and decline notifications.
  - Size: Standard
  - Depends on: Task 7, Task 13
  - Purpose: Confirm accepted participation to both parties and a declined outcome only to the owner.
  - Owned surfaces: Acceptance participant and owner events, decline owner event, recipient resolution, minimized `AccountNotification` payload, event-recipient-version uniqueness, durable unread and read behavior, replay safety, safe links, and no account-disclosure signal.
  - Owns: AC-22
  - Proof: Focused projector, recipient matrix, replay, minimized-payload, unread, mark-read, safe-link, and negative disclosure tests pass.

- [x] Task 15 — Deliver participation management and identity visibility.
  - Size: Standard
  - Depends on: Task 3
  - Purpose: Show only the membership and invitation fields each current member is allowed to see.
  - Owned surfaces: Participation-management LiveView, current owner and participant role presentation, project display names, owner-only invitation and verified participant email visibility, participant self-email visibility, other-email non-disclosure, pending and terminal invitation list fields, owner-only management controls, fixtures, and responsive accessible browser behavior.
  - Owns: AC-27
  - Proof: Focused query, authorization, LiveView, desktop and mobile browser tests cover owner, participant, other project, invitation states, display labels, self email, other-email denial, management control visibility, keyboard, and focus.

- [x] Task 29 — Deliver member-controlled display-name editing.
  - Size: Standard
  - Depends on: Task 15
  - Purpose: Let each current member change only their own project label without changing authorization identity.
  - Owned surfaces: Participant self-edit action, owner self-edit reuse, trimmed case-insensitive uniqueness, accepted spelling, conflict rejection without suffix, stable identity preservation, current-label rendering, last-accepted-label handoff seam, fixtures, and inline accessible validation.
  - Owns: AC-20
  - Proof: Focused authorization, uniqueness, case, trimming, conflict, stable-identity, owner and participant self-edit, cross-member denial, historical-label seam, and LiveView tests pass.

- [x] Task 16 — Enforce participant project capabilities.
  - Size: Standard
  - Depends on: Task 15
  - Purpose: Grant only the approved project-content capabilities and deny management, destructive, and credential authority.
  - Owned surfaces: Project-scoped current-participant query foundation, specification and feature-content read and edit decisions, comment and run-evidence decisions, cross-project and workspace isolation, participant-management denial, project deletion, storage and repository setting denial, provider, worker, agent, invitation, and session credential denial, protected-field redaction, and direct fail-closed reads without a long-lived cache.
  - Owns: AC-05, AC-14, AC-15
  - Proof: Focused authorization matrix, current and stale membership, project and workspace isolation, approved capability, protected setting, destructive action, credential, secret, and content-existence disclosure tests pass.

- [x] Task 17 — Deliver atomic owner removal and the revocation handoff.
  - Size: Standard
  - Depends on: Task 16, Task 29
  - Purpose: End owner-selected participation and publish exactly one durable consumer handoff in the same transaction.
  - Owned surfaces: `ParticipationRevocation`, owner removal command, active-participant row locking, atomic inactive transition and outbox insertion, immediate authorization invalidation, immutable owner fallback, last accepted display name, reason, event time, contract version, idempotent handoff identity, claim and acknowledgement operations, no Slice 07 record mutation, fixtures, and removal result.
  - Owns: AC-07, AC-17, entity:ParticipationRevocation
  - Proof: Focused transaction, authorization, concurrency, repeat, rollback, fail-closed access, exactly-one handoff, payload-minimization, claim, acknowledgement, replay, and negative Slice 07 mutation tests pass.

- [x] Task 18 — Deliver participant self-leave and immutable-owner denial.
  - Size: Standard
  - Depends on: Task 16, Task 17
  - Purpose: Let a participant end only their own access while keeping project ownership unchanged.
  - Owned surfaces: Participant self-leave command, owner and other-participant denial, atomic inactive transition and versioned revocation insertion reuse, immediate authorization invalidation, immutable-owner invariant, idempotency, concurrency, fixtures, and leave result.
  - Owns: AC-08, AC-09
  - Proof: Focused authorization, self-leave, owner-leave denial, other-member denial, repeated, concurrent, rollback, handoff, immediate access denial, and immutable-owner tests pass.

- [x] Task 19 — Deliver removal and leave in-product notifications.
  - Size: Standard
  - Depends on: Task 7, Task 17, Task 18
  - Purpose: Notify the directly affected account after removal and the owner after self-leave.
  - Owned surfaces: Removal former-participant account event, leave owner event, account-boundary removal visibility after project access ends, recipient resolution, minimized payload, event-recipient-version uniqueness, durable unread and read state, replay safety, safe account or project link, and no restored project access.
  - Owns: AC-23
  - Proof: Focused projector, recipient, removal-after-access, leave, replay, minimized-payload, unread, mark-read, link-authorization, and no-restored-access tests pass.

- [x] Task 27 — Deliver participant-removal email.
  - Size: Standard
  - Depends on: Task 8, Task 17
  - Purpose: Notify the former participant externally without exposing project content or credentials.
  - Owned surfaces: Removal email outbox event, current protected recipient address, minimized template, safe account-level link, event-recipient-version idempotency, success and failure handling, delivery diagnostics, and no invitation credential or project-content field.
  - Owns: AC-36
  - Proof: Focused recipient, template, safe-link, replay, failure, diagnostic-minimization, credential-absence, and project-content redaction tests pass.

- [x] Task 4 — Publish the current-participant authorization boundary.
  - Size: Standard
  - Depends on: Task 9, Task 16, Task 18, Task 19, Task 27
  - Purpose: Give Slice 07 and approved consumers one fail-closed read and revocation contract without participation mutation.
  - Owned surfaces: Current owner and active-participant read interface, minimum stable identity, role, and project display-name result, stale, removed, left, and absent denial, direct read semantics, project scoping, versioned revocation producer contract and claim or acknowledgement documentation, shared notification-foundation extension contract, fixtures, consumer contract tests, and `capability:project-participation-boundary` readiness write-back.
  - Owns: AC-11
  - Proof: Focused consumer-contract, current, stale, removed, left, absent, project-isolation, minimum-payload, read-only, revocation replay, notification-extension, and Slice 07 compatibility tests pass before readiness is recorded.

- [ ] Task 36 — Repair active-participant recipient routing without profile coupling.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4, Task 34
  - Purpose: Keep authorization, responsibility, and notification routing tied to active participation when presentation data is absent.
  - Owned surfaces: `Participation.Boundary` active-participant enumeration, immutable-owner and `ProjectParticipant`-first query semantics, optional `ProjectMemberProfile` join, stable identity and role result, explicit absent-presentation state, neutral minimized presentation contract, no email fallback, stale and departed denial, Slice 07 recipient-routing compatibility fixtures, `capability:project-participation-recipient-routing` provider, and readiness write-back.
  - Owns: AC-42
  - Proof: Focused boundary and notification-consumer tests prove an active participant without a profile remains authorized and routable, an owner without a profile remains resolvable, no email-derived label is returned, stale and departed identities remain denied, project isolation holds, and capability readiness is recorded through task scope.

- [ ] Task 20 — Enforce invitation and participation-record cleanup.
  - Size: Standard
  - Depends on: Task 4, Task 25
  - Purpose: Remove reusable invitation material and departed identity links on the approved schedule.
  - Owned surfaces: Immediate terminal credential digest and salt erasure, seven-day unusability, 30-day terminal `ProjectInvitation` cleanup, 30-day departed `ProjectParticipant` authorization-to-identity cleanup, active-participation preservation, idempotent `Privacy.Retention.prune_all/1` rules, supervised pruning, reconciliation, and fixtures.
  - Owns: AC-31
  - Proof: Focused time-boundary, terminal-state, credential-erasure, invitation deletion, departed-link deletion, active-record preservation, idempotency, lock, restart, and reconciliation tests pass.

- [x] Task 21 — Enforce participation notification minimization.
  - Size: Standard
  - Depends on: Task 11, Task 14, Task 19, Task 27
  - Purpose: Keep every participation notification inside the approved minimum content boundary.
  - Owned surfaces: Approved email and in-product notification field allowlist, specification, feature, comment, evidence, repository, credential, secret, and unrelated-identity exclusion, safe link rules, recipient-context minimization, fixtures, and negative payload scans.
  - Owns: AC-24
  - Proof: Focused payload allowlist, recipient context, safe link, forbidden-content, credential, secret, unrelated-identity, email, and in-product notification tests pass.

- [ ] Task 32 — Enforce participation email-delivery retention.
  - Size: Standard
  - Depends on: Task 8, Task 11, Task 27
  - Purpose: Remove email-delivery diagnostics after their short operational purpose ends.
  - Owned surfaces: 30-day `ParticipationEmailDelivery` cleanup rule, terminal delivery-state selection, active invitation and participant preservation, idempotent pruning, lock and restart behavior, fixtures, and reconciliation.
  - Owns: AC-32
  - Proof: Focused 30-day boundary, terminal and active delivery, invitation preservation, participant preservation, idempotency, lock, restart, and reconciliation tests pass.

- [ ] Task 33 — Enforce account-notification retention.
  - Size: Standard
  - Depends on: Task 7, Task 14, Task 19, Task 26
  - Purpose: Delete participation in-product notifications after their approved account-level lifetime.
  - Owned surfaces: 90-day `AccountNotification` cleanup rule, read and unread notification selection, active project authorization non-mutation, idempotent pruning, lock and restart behavior, fixtures, and reconciliation.
  - Owns: AC-39
  - Proof: Focused 90-day boundary, read, unread, active authorization, idempotency, lock, restart, and reconciliation tests pass.

- [ ] Task 22 — Enforce rights-aware historical attribution.
  - Size: Standard
  - Depends on: Task 17, Task 18, Task 29
  - Purpose: Preserve stable contribution history while removing unnecessary departed-person identification.
  - Owned surfaces: Historical-attribution necessity decision, verified anonymization action, account-link removal, anonymous former-participant label, stable contribution preservation, no access restoration, derived-copy propagation, project-deletion handling, fixtures, and `Privacy.Rights` integration.
  - Owns: AC-25
  - Proof: Focused necessity, verified request, anonymization, account-link, label, stable-history, no-restored-access, derived-copy, and project-deletion tests pass.

- [ ] Task 23 — Enforce the participation processing and access contract.
  - Size: Standard
  - Depends on: Task 4, Task 21, Task 22
  - Purpose: Limit participation data to the approved service and security purposes and authorized recipients.
  - Owned surfaces: Active processing inventory, field-purpose and lawful-basis map, owner, participant, operations, and support access, least-privilege time-bounded audited support, processor and transfer configuration, invitation and identity enumeration resistance, secret and project-content redaction, negative credential transfer, no advertising, model training, unrelated improvement, or secondary use, and aggregate genuinely anonymous analytics boundary.
  - Owns: AC-13
  - Proof: Focused inventory, purpose and basis, access, support elevation, processor, transfer, directory and enumeration, secret, project-content, credential-transfer, negative secondary-use, and anonymous-analytics tests pass.

- [ ] Task 24 — Enforce minimized participation security logs.
  - Size: Standard
  - Depends on: Task 20, Task 21, Task 32, Task 33
  - Purpose: Retain only short-lived security evidence without invitation secrets or project content.
  - Owned surfaces: Fixed structured security-log fields, invitation and identity event minimization, credential, email, project-content, repository, and secret redaction, non-secret correlation identifier, 30-day expiry rule, audit minimization, diagnostic scans, and fixtures.
  - Owns: AC-33
  - Proof: Focused structured-log, field allowlist, redaction, correlation, failure-path, 30-day expiry, audit-minimization, and diagnostic tests pass.

- [ ] Task 30 — Enforce encrypted-backup expiry.
  - Size: Standard
  - Depends on: Task 22, Task 23, Task 24
  - Purpose: Bound encrypted recovery copies without restoring deleted or anonymized identity links.
  - Owned surfaces: 35-day encrypted rolling-backup expiry configuration, approved recovery-only boundary, deletion and anonymization tombstone handling, `DeploymentPrivacyProfile` backup evidence, cleanup reconciliation, and release-gate classification.
  - Owns: AC-37
  - Proof: Focused backup-expiry, recovery-boundary, tombstone, anonymization, deletion, reconciliation, deployment-profile, and release-gate checks pass.

- [ ] Task 31 — Propagate participation deletion and anonymization.
  - Size: Standard
  - Depends on: Task 20, Task 22, Task 23, Task 30
  - Purpose: Carry approved deletion and anonymization through every configured non-backup copy.
  - Owned surfaces: Processor deletion and anonymization requests, cache, index, export and derived-copy propagation, acknowledgement and failure state, restricted cleanup reconciliation, no restored project access, fixtures, and deployment-processor configuration linkage.
  - Owns: AC-38
  - Proof: Focused processor, cache, index, export, derived-copy, acknowledgement, failure, retry, reconciliation, anonymization, deletion, and no-restored-access tests pass.

- [ ] Task 5 — Complete the participation privacy and security review.
  - Size: Standard
  - Depends on: Task 4, Task 23, Task 31
  - Purpose: Confirm the complete participation data flow satisfies its approved contract before publishing governance readiness.
  - Owned surfaces: Consolidated data inventory and lifecycle review, rights coverage, processor and transfer review, notification and email-channel review, no-directory and account-neutrality review, credential and project-content exposure review, cleanup reconciliation review, required privacy and security approval, release-gate classification, and `capability:project-participation-governance` readiness write-back.
  - Owns: none (governance gate)
  - Proof: Focused cross-task privacy, security, lifecycle, rights, notification, account-neutrality, credential-exposure, project-content, processor, transfer, and required-review checks pass before capability readiness is recorded.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Every active acceptance criterion and data entity has one clear primary task owner.
- [ ] Hosted-project owner invitation, no-directory, and account-neutral request and failure scenarios pass.
- [ ] Seven-day expiry, one-pending uniqueness, invalidating resend, cancellation, decline, current-participant handling, and fresh re-invitation lifecycle tests pass.
- [ ] Fresh invited-email proof, explicit acceptance, single-use, uniqueness, idempotency, concurrency, rollback, and no-partial-state tests pass.
- [ ] Project, workspace, identity, owner, participant, and cross-user isolation tests pass.
- [ ] Owner removal, participant self-leave, immutable-owner, direct fail-closed authorization, session preservation, and the versioned Slice 07 producer-contract tests pass without mutating consumer-owned records.
- [ ] The owner display profile is created with the hosted project from a GitHub-login label, projects registered earlier are backfilled idempotently, and owner authorization never depends on a label existing.
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

### 2026-08-02 - Task 21 complete: participation notifications stay minimized

- Completed: Added exact participation-event and email-context allowlists for invitation, resend, acceptance, decline, expiry, cancellation, removal, and leave notifications. In-product payloads now reject unapproved fields or content and enforce event-specific internal links; invitation emails reject unrelated context and links outside the configured product origin or canonical single-token acceptance route. Delivery records remain the existing fixed minimized schemas, and the shared notification store is unchanged.
- Boundary held: Notification builders accept only the project label, approved event or action wording, the necessary actor label, recipient routing identity, time, and the event's safe link. Focused negative scans and rejection tests cover specification, feature, comment, evidence, repository, credential, secret, and unrelated-identity sentinels without changing participation lifecycle or retention behavior.
- Proof: `MIX_TEST_PARTITION=21 MIX_DEPS_PATH=/Users/alabenkhlifa/IdeaProjects/sdd-orchestrator/deps mix test test/sdd_orchestrator/participation/notification_minimization_test.exs test/sdd_orchestrator/participation/email_delivery_test.exs test/sdd_orchestrator/participation/invitation_email_test.exs test/sdd_orchestrator/participation/outcome_notification_test.exs test/sdd_orchestrator/participation/expiry_notification_test.exs test/sdd_orchestrator/participation/departure_notification_test.exs test/sdd_orchestrator/participation/removal_email_test.exs` passes with 44 tests and 0 failures. Targeted `mix format --check-formatted` and strict Credo pass on all changed Elixir files.
- Spec updates: Marked Task 21 complete for AC-24; requirements, design, capability readiness, ownership, and dependency edges are unchanged.

### 2026-08-02 - Recipient-routing repair refined

- Completed: Preserved completed Task 4 and `capability:project-participation-boundary`, clarified that authorization and routing come from project ownership or active `ProjectParticipant` state before optional presentation, and added focused Task 36 for the observed profile-coupling defect.
- Remaining: Implement Task 36 and publish `capability:project-participation-recipient-routing`; the existing lifecycle, retention, rights, logging, backup, propagation, and governance tasks remain unchanged.
- Failed checks: None. The individual specification validator, global 24-specification capability graph, validator test suite, and `git diff --check` pass with the coordinated Slice 07 continuation update.
- Spec updates: Added AC-42, the explicit absent-presentation and no-email-fallback contract, prospective Task 36 proof scope, the narrow repair capability, and its consumer handoff without reopening completed history.

### 2026-07-31 - Task 35 complete: the owner sees the label an invitee will read

- Completed: The invitation action now shows the owner display name with an inline correction path, and the gate that blocked the first invitation until the owner saved one is retired. AC-26 is satisfied as rewritten.
- The gate is gone from every place it lived: `require_owner_profile/1` and its two call sites in `Invitations.create/3` and `resend/3`, the `:owner_profile_required` error, its message, the warning notice, and the branch that hid the whole invitations card. The card is now unconditional for the owner, because after Task 34 a label always exists and there is nothing left to wait for.
- Correction reuses `Participation.save_owner_profile/3`, the same function the standalone owner form calls, so trimming, case-insensitive project uniqueness, preserved spelling, explicit conflict rejection, and the no-suffix rule come from one path rather than a second implementation that could drift. A closed correction re-syncs its draft from the stored profile on every refresh, so the two edit surfaces cannot disagree.
- A non-owner has no label surface at all, and a hand-sent correction event from one fails closed at the domain rather than at the template.
- `Participation.owner_profile_established?/1` was kept rather than retired. It is public, one test still uses it to prove label-independence, and it remains a truthful question; its documentation no longer claims it is a precondition for inviting.
- The `owner_profile=false` browser bootstrap parameter also survives on purpose: registration can no longer produce that state, but it is the only way to exercise the neutral-fallback label a legacy or fixture project still gets.
- Failed checks: None. Final proof passes with real exit status, confirmed in the main thread: `mix test` (2287 passing, 0 failures), `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix credo --strict`, `git diff --check`, and the desktop and mobile browser matrix at 104 passing each.

### 2026-07-31 - Task 34 complete: the owner has a label from the moment the project exists

- Completed: Registration now creates the owner's `ProjectMemberProfile` inside its own `Ecto.Multi`, a backfill migration gives earlier hosted projects one, and `Boundary.owner/1` no longer requires a profile to resolve the owner. `capability:project-owner-display-profile` is ready.
- The defect this closes: `Boundary.owner/1` demanded `owner_profile` before it would call anyone the owner, so a presentation label was a precondition for authorization. `ParticipantGuard` then denied the real owner of every freshly registered hosted project, and Slice 07's feature board refused to render for them with nothing on screen explaining why. Ownership comes from the hosted project workspace, as this specification's own design already said; the label was never part of that question.
- Fallback label is the neutral `"Project owner"`, exposed as `Participation.default_owner_display_name/0` so registration, the migration, and the boundary all name one value. Anything derived from an email, an account id, or another stable key would push personal data or a linkable pseudonym into a string every project member reads, to solve a problem a generic role word solves.
- The backfill writes no suffix, ever. A derived label whose key is already taken by an active profile yields no owner profile at all rather than `login-2`, because AC-30 forbids automatic suffixes and a skipped row is recoverable while a wrong label is not. At registration the collision is impossible by construction, and the insert is allowed to abort the whole registration if that invariant ever breaks.
- The migration derives a label only from a login matching the GitHub shape, ASCII letters, digits, and hyphens up to 39 characters, so SQL `lower/1` is provably identical to the application's NFKC-plus-case-folding key derivation. A test asserts the written key equals `DisplayName.key/1` of the written name rather than trusting that equivalence.
- `down/0` is a documented no-op. Once backfilled, a derived label is indistinguishable from one the owner typed, so deleting rows would destroy chosen names to undo a default, and nothing depends on their absence now that authorization ignores them. The rollback test asserts exactly that: `down` preserves the row and a re-run of `up` does not duplicate it.
- Verified against real dev data: the migration was correctly a no-op on two projects whose profiles had been hand-fixed earlier, and `Boundary.owner/1` was proved to resolve both owners with the neutral label inside a rolled-back transaction with their profiles removed.
- Three existing tests encoded the defect itself and were inverted, not weakened: the onboarding walk and two landing-controller cases asserted that a just-registered project sends its owner to the overview "because it has no owner display name yet". Fail-closed cases are untouched. The landing controller's moduledoc stated the same falsehood and was rewritten; its logic was already correct.
- Task 35 is unaffected and still owns AC-26. `Participation.owner_profile_established?/1` and the invitation gate were deliberately left alone.
- Known consequence, owned elsewhere: Slice 07's browser test asserting that an unconfigured project opens on its overview now fails, because its subject was participation rather than setup. `specs/07` Task 53 is already reopened to test repository connection and storage instead.
- Failed checks: None. Final proof passes with real exit status, confirmed in the main thread: `mix test` (2272 passing, 0 failures), `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix credo --strict`, and `git diff --check`; the agent additionally recorded `mix dialyzer` and `mix sobelow --config` clean.

### 2026-07-29 - Authenticated participation browser matrix unblocked

- Completed: The desktop and mobile browser matrices recorded as environment-blocked on Tasks 28, 12, 13, 15, 29, 17, and 18 now run for real. Twenty scenarios cover the owner label prerequisite and conflicting-label rejection, invitation send, replacement and cancellation with their list states, the member list and its email-visibility rule, participant self-rename, self-leave with immediate loss of access, the unproven invitee, the other-identity warning, explicit acceptance, decline, and the one safe result a used-up invitation returns — each with keyboard, focus-ring, viewport, and axe passes on both `chromium` and `mobile-chromium`. The per-task environment-blocked `Status:` lines are removed because the condition they recorded no longer holds.
- Mechanism recorded: The blocker was that Playwright could establish neither auth boundary — an application session comes only from a live GitHub round trip and a hosted session only from a delivered passwordless credential. `SddOrchestratorWeb.E2EBootstrapController` at `/_e2e/session` establishes both and seeds one scenario's project graph. It is harness code, not product behavior: no acceptance criterion, entity, or task ownership changed. Seeding runs the real domain commands — `Invitations.create/3`, `Acceptance.accept/3`, and the lifecycle transition table — so every seeded state is one the product itself can produce, and the invited person's credential is read back out of the delivered message rather than reconstructed, which also exercises the Task 11 delivery path.
- Security boundary: The harness is excluded from production by construction, not by a runtime check, in three layers. The controller's own `defmodule` and the router's route are both wrapped in `Application.compile_env(:sdd_orchestrator, :e2e_bootstrap, false)`, and `create/2` re-checks the flag at runtime and answers `404`. `config/test.exs` sets the flag and `config/dev.exs` sets it only when `E2E_MODE` is on, so an ordinary `mix phx.server` does not expose it either — confirmed against the plain dev build, whose route table has no `/_e2e/session` while `/_ui` is present. Verified against a real production build: `MIX_ENV=prod` compiles 31 routes with no `/_e2e/session`, and the built release contains no `E2EBootstrapController` beam and no occurrence of the path anywhere in its artifacts. This deliberately goes further than the `/_ui` preview, which gates only its route and whose module does ship, because this endpoint establishes authenticated sessions. The runtime `404` and the absence of the key from the production configuration are each asserted directly.
- Remaining: Unchanged. The lifecycle, retention, rights, logging, backup, propagation, and governance tasks (20, 21, 22, 23, 24, 30, 31, 32, 33, and 5) still remain, so `capability:project-participation-governance` is unavailable and the slice verification gate has not run. The gate's browser line now has real desktop and mobile evidence and will be confirmed when the gate runs as a whole.
- Failed checks: None. Proof passes with real exit status: 13 bootstrap-controller tests, `npm --prefix assets run test:e2e` (69 passing on `chromium` and 69 on `mobile-chromium`, of which 20 per project are these participation and invitation scenarios), `mix check` (1037 passing), and `mix sobelow --config`.
- Spec updates: Removed the satisfied environment-blocked `Status:` lines from Tasks 28, 12, 13, 15, 29, 17, and 18 and the matching sentence from the slice status. Requirements, design, acceptance criteria, ownership, task sizes, and dependency edges are unchanged.

### 2026-07-29 - Task 4 complete: current-participant authorization boundary published

- Completed: Added `Participation.Boundary`, the whole contract approved consumers use. It resolves the immutable owner and each active participant as a minimum result — stable identity, role, and project display name — answers capability questions, exposes the versioned departure handoff through claim, pending, and acknowledge, and lets a consumer add its own namespaced event types to the shared account-level notification store.
- Capability readiness: `capability:project-participation-boundary` is ready after Task 4. Slice 07 may now consume current participant identity and authorization, the shared notification foundation, and the `ParticipationRevocation` claim and acknowledgement contract.
- Boundary held: No email address crosses the boundary — the member result has exactly four keys and membership management keeps addresses inside this specification. A stale, removed, departed, absent, or cross-project identity receives one denial that does not say which case applied. Reads are direct: removing a participant changes the very next answer with no cache step, and a sequence of reads leaves participation state byte-identical. The handoff carries the owner fallback and the last accepted label and contains no consumer-owned field; an unapproved notification namespace is rejected.
- Remaining: The lifecycle, retention, rights, logging, backup, propagation, and governance tasks (20, 21, 22, 23, 24, 30, 31, 32, 33, and 5) remain, so `capability:project-participation-governance` is unavailable and the slice verification gate has not run.
- Failed checks: None. Focused proof passes with real exit status: 9 consumer-contract tests, `mix test` (942 passing), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 4 complete and recorded capability readiness in the slice status; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 27 complete: participant-removal email

- Completed: Owner removal now sends the approved removal message to the address currently verified for that stable identity, after the authoritative transaction commits, and records its own minimized delivery outcome keyed by the handoff and contract version.
- Boundary held: The message carries no link, no credential, no invitation reference, and no project content beyond the project label; it states that the person's account is unchanged. A retried removal finds nothing to remove and sends nothing, and re-issuing the same event returns the recorded outcome without a second message. A provider failure leaves the removal committed with a recorded failure code and a log line that does not contain the address. Leaving sends no removal message.
- Remaining: Task 4 publishes `capability:project-participation-boundary`, which is what Slice 07 waits on.
- Failed checks: The full run again exposed Task 17's negative scan, which now also had to account for this specification's own email-delivery diagnostic; the participation-owned table list was extended and each new row is asserted, keeping the scan's meaning that no consumer-owned record is touched. Final proof passes with real exit status: 5 removal-email tests, `mix test` (933 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 27 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 19 complete: removal and leave in-product notifications

- Completed: The departure transaction now projects one minimized notification per event. Removal reaches the former participant at their account boundary with an account-level link, and leaving reaches the project owner with the participation link. Both are keyed by the handoff and its contract version.
- Boundary held: The removal record stays readable and markable after project access has ended, and reading it restores nothing — participation and project visibility remain closed. Neither person is notified about their own action. Bodies name the project label and the action only, with the departing member's last accepted label as the actor on the owner's record; no address, invitation, or credential appears. Re-projecting the same handoff is idempotent through the shared event-recipient key, while a rejoined and re-removed person produces a second distinct record.
- Remaining: Task 27 (participant-removal email) is next, then Task 4 publishes `capability:project-participation-boundary`.
- Failed checks: The full run exposed that Task 17's negative scan asserted only the handoff table changes during removal; the departure now also writes its own account-level notification. The scan was corrected to treat `participation_revocations` and `account_notifications` as the participation-owned tables and to require exactly one new row in each, which keeps its real meaning: no consumer-owned record is touched. Final proof passes with real exit status: 6 departure-notification tests, `mix test` (928 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 19 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 18 complete: participant self-leave and immutable-owner denial

- Completed: Added `Revocations.leave/4` and the participant's own leave control. Leaving reuses the removal transaction, so it ends the authorization, preserves the last accepted label, and inserts the same versioned handoff with reason `left`.
- Boundary held: A participant ends only their own participation — another member and the owner are untouched — and access is gone immediately: the leave action redirects to the catalog and a fresh visit with the same hosted session fails closed. The immutable owner cannot leave their own project, with or without a participant identity, and the attempt creates no handoff. Ending someone else's participation, acting with no identity, and repeating a completed leave are all rejected without a second handoff. The owner's screen shows no leave control.
- Remaining: Task 19 (removal and leave in-product notifications) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 12 revocation tests, 23 participation LiveView tests, `mix test` (923 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 18 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 17 complete: owner removal and the revocation handoff

- Completed: Added `participation_revocations` with its migration and schema, the `Participation.Revocations` domain, and the owner's inline remove control. One transaction locks the active authorization, marks it departed, preserves the last accepted project label as historical attribution, and inserts exactly one versioned handoff naming the project, the former participant, the immutable owner fallback, that label, the reason, the event time, and the contract version.
- Boundary held: Authorization ends at commit — the next capability decision returns nothing and the project is no longer visible to that identity. A non-owner, an absent actor, an outsider target, and a repeat are all rejected without creating a second handoff. A person who rejoins and later departs produces a distinct handoff, because the handoff is keyed to the participation row rather than the person. A row-count comparison across every table proves removal adds only the handoff and touches no consumer-owned record.
- Consumer contract: `pending/1`, `claim/1`, and `acknowledge/3` expose the producer side. Claiming is a delivery marker only, so a consumer that crashes before acknowledging sees the same handoff again and its own idempotent handling absorbs the repeat; acknowledging twice keeps the first record and consumer reference.
- Remaining: Task 18 (participant self-leave and immutable-owner denial) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: Dialyzer reported the known `Ecto.Multi` opacity warning for the new transaction module, which now uses the repository's existing narrow suppression list. Final proof passes with real exit status: 9 revocation tests, 21 participation LiveView tests, `mix test` (917 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 17 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 16 complete: participant project capabilities

- Completed: Added `Participation.Capabilities` as the project-scoped decision surface. A participant receives the approved project-content capabilities — read and edit specifications, read and edit feature content, comment, and read run evidence — and the owner adds membership management, project deletion, and storage and repository settings.
- Boundary held: No role reaches any credential capability, including the owner: repository, worker, agent, invitation, and session secrets stay with their own boundaries. An unknown capability name is denied rather than ignored. Participation in one project grants nothing in another, and owning one project grants nothing in a second. Every decision re-reads current participation, so capabilities end on the next action after removal without any cache invalidation step. A member reads only the approved project fields; workspace and repository identifiers are absent from the result rather than nulled.
- Remaining: Task 17 (owner removal and the revocation handoff) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 9 capability tests, `mix test` (907 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 16 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 29 complete: member-controlled display-name editing

- Completed: Added `Participation.rename_member_profile/4` and the participant's own label form on the participation screen. A participant edits their label there; the owner keeps the same action through their existing form, so one rule governs both.
- Boundary held: A rename is presentation only — the participant authorization row, the stable hosted identity, the account link, and the role are unchanged. Labels are trimmed, compared case-insensitively across owner and participants in one project, and a conflict is rejected inline for correction with no automatic suffix. An unusable label (blank, oversized, control-bearing, email-shaped) is rejected. Renaming another member's label, renaming without a session, and renaming after departure all fail closed.
- Seam recorded: `Participation.preserve_historical_label/2` moves a departing member's profile to historical while keeping the last accepted label and account link, and frees that label for a current member. Task 17 and Task 18 call it from their removal and leave transactions.
- Remaining: Task 16 (participant project capabilities) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 7 member-profile tests, 20 participation LiveView tests, `mix test` (898 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 29 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 15 complete: participation management and identity visibility

- Completed: Participation settings now serve both current members. The page lists every current member by project display name with their role, and the owner additionally sees the project's invitation list with each invited address and its lifecycle state.
- Mechanism recorded: Participation is a hosted-identity feature, so the route moved to a live session that resolves both boundaries — the owner arrives through the application session and a participant through their hosted session — and the view itself fails closed through `Participation.visible_project/3` rather than relying on a route-level guard.
- Boundary held: Email visibility is decided in the domain, not the template. The owner sees member addresses for membership management; a participant sees only their own and never another member's or the owner's; every member is otherwise presented by project label, and no label is derived from an address. Owner-only controls — the owner profile form, the invitation form, and the invitation list — are absent for a participant, and a departed participant or an outsider is returned to the catalog without seeing any project content.
- Remaining: Task 29 (member-controlled display-name editing) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: Two earlier assertions encoded the pre-Task-15 view (no address anywhere, and a route-level redirect to the entry page); both were updated to the approved visibility rule and the view's own fail-closed redirect. Final proof passes with real exit status: 19 participation LiveView tests, `mix test` (890 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 15 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 14 complete: acceptance and decline notifications

- Completed: Proved the in-product outcome channel end to end. Acceptance confirms to the new participant and reports to the project owner; declining reports to the owner only. Every record uses the shared store's event, subject, version, and recipient key, so replaying an outcome creates no duplicate for either person.
- Boundary held: A project bystander receives nothing, and the person who declined receives no record for a project they did not join. Each body names the project label, the action, and the new participant's project display name only — never the invited address, the invitation identifier, a credential, or an account-existence signal — and each link stays inside the project it belongs to. Unread delivery is durable, mark-read is idempotent, and marking is denied for another recipient.
- Remaining: Task 15 (participation management and identity visibility) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 6 outcome-notification tests, `mix test` (887 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Spec updates: Marked Task 14 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 13 complete: acceptance and decline interface

- Completed: Added `Acceptance.decline/3` and the post-proof acceptance step on the invitation screen. Once the invited address is proven, the screen names the project, states who runs it by project label, asks for the participant's own project display name, and offers explicit `Join` and `No thanks` actions. Accepting shows the joined state and a link into the project; declining shows a terminal result and notifies the owner in-product.
- Boundary held: The screen presents display names only — the owner's email address never appears. An unavailable label is rejected inline as taken, and an invalid or email-shaped label is rejected as unusable; neither creates a participant. Declining erases the invitation credential, creates no access, and leaves a later invitation to start a fresh flow, which the test proves by creating one afterwards. The owner's decline notification names the project and the action only.
- Remaining: Task 14 (acceptance and decline notifications) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 7 acceptance-screen LiveView tests, `mix test` (881 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 13 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 3 complete: atomic participation acceptance

- Completed: Added `Participation.Acceptance`. One `Ecto.Multi` locks the invitation row, revalidates at commit time that it is still pending, unexpired, and freshly proven by the acting identity, creates the participant authorization and its project display profile, consumes the invitation while erasing its credential, and inserts the participant and owner outcome notifications.
- Boundary held: Exactly one active participant exists per identity and project — a replayed acceptance returns the existing participation without a second participant, profile, or notification, and a self-race leaves one participant and one accepted invitation. Every unusable path (unknown or malformed id, absent identity, expired, canceled, or an identity that proved a different address) returns the same safe result and leaves no participant, profile, consumed invitation, or notification behind. An unavailable or invalid project display name rolls the whole transaction back and reports which of the two it was.
- Mechanism recorded: `Notifications` now exposes `changeset/1` and `insert_options/0` so a caller composes notification steps inside its own transaction without passing an opaque `Ecto.Multi` across a module boundary. The module was added to the repository's existing documented `call_without_opaque` suppression list, which every `Ecto.Multi` module here already carries for the same known Ecto/Dialyzer interaction.
- Remaining: Task 13 (acceptance and decline interface) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: Strict Credo flagged an `Enum.count/2` predicate count in a race assertion. Dialyzer reported the known `Ecto.Multi` opacity warning; the notification composition was restructured first and the residual warning uses the repository's existing narrow suppression. Final proof passes with real exit status: 7 acceptance tests, `mix test` (878 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 3 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 12 complete: invitation-bound fresh email proof

- Completed: Added `Participation.InvitationProof` and the invited person's entry screen at `/projects/invitations/:id/accept`. Opening the link resolves the invitation from its delivered credential; requesting proof issues a passwordless link for the address stored on the invitation, never for typed input, and returns to the same screen.
- Boundary held: An active session for another identity is never treated as proof — the screen warns that continuing signs this browser in as the invited address and that other sign-ins are unaffected — and a real verification round trip proves the other identity's server-side session survives. Every unusable case (wrong credential, unknown or malformed id, expired, canceled, replaced credential) returns one safe result that does not name the invited address or the project. Proof alone creates no participant authorization: the invitee is still not an active participant, the project stays inaccessible, and the invitation stays pending until an explicit acceptance step.
- Mechanism recorded: The delivered credential is not carried through the proof round trip, so it never enters the passwordless attempt's return path. The return visit is authorized by the proven identity's own verified-address digest instead.
- Remaining: Task 3 (atomic participation acceptance) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: Changing the invitation URL shape to a routable path broke two Task 2 assertions that pinned the old query-string form; both now assert the routed path. Strict Credo flagged one unordered alias group. Final proof passes with real exit status: 9 proof-domain tests, 4 acceptance-screen LiveView tests, `mix test` (871 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 12 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 26 complete: owner invitation-expiry notification

- Completed: Added `Participation.ProjectNotifications` and wired the expiry sweep to it. Expiring a pending invitation now resolves the current project owner and creates one minimized `AccountNotification` keyed by event type, invitation, credential version, and recipient, carrying the project label, what happened, the expiry time, and the participation link.
- Boundary held: The invited person receives no project notification, because they never held project access. The notification body names the project and the action only — never the invited address, the invitation identifier, or a credential. Replaying the sweep or the projector creates no second record, unread state is durable, and mark-read is idempotent and denied for another account. A canceled or accepted invitation is never expired and never notified, and a replaced invitation notifies against its own credential version.
- Remaining: Task 12 (invitation-bound fresh email proof) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 5 expiry-notification tests, `mix test` (858 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 26 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 11 complete: invitation lifecycle email notifications

- Completed: Completed the invitation, replacement, and cancellation email channel and made delivery replay-safe. `EmailDelivery.deliver/2` now returns an already-sent record without sending a second message, while a failed attempt is still retried in place on the same record.
- Boundary held: Each message carries the credential current at its own version — the replacement link matches the rotated digest and the superseded link does not — and each version records its own delivery outcome. The cancellation message contains no link, no credential, and no invitation identifier. Every message names the project label and the action only: no specification, evidence, repository, owner label, address digest, or account-existence signal appears. A known address and an unknown address produce the same delivery status, failure code, and event type, and a provider outage leaves the invitation pending and still usable with a recorded failure.
- Remaining: Task 26 (owner invitation-expiry notification) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 7 invitation-email tests, `mix test` (853 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 11 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 25 complete: invitation cancellation and expiry

- Completed: Added owner cancellation, the seven-day expiry transition, and the `usable/2` read used by later acceptance. Both transitions lock the row, move it to a terminal state, and erase the credential digest and salt in the same update, so the delivered link stops working immediately. Cancellation sends the approved message once and is idempotent when repeated; expiry is a bulk idempotent sweep that returns how many invitations it ended. Participation settings expose an inline `Cancel that invitation` action beside the replacement action.
- Boundary held: Neither transition creates access or touches a participant record — an active participant is unchanged across an expiry sweep. A terminal invitation cannot be resent and cannot be canceled again from another terminal state; a later invitation for the same address is a fresh row with credential version 1, so acceptance always requires a fresh flow.
- Seam recorded: `Invitations.expire_due/1` is the callable transition. Wiring it, and terminal-row cleanup, into `Privacy.Retention.prune_all/1` belongs to Task 20, which owns those pruner rules.
- Remaining: Task 11 (invitation lifecycle emails) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 8 lifecycle tests, 85 participation and LiveView tests, `mix test` (846 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 25 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 10 complete: invitation resend and fresh re-invitation

- Completed: Added `Invitations.resend/3` and the inline replacement control in participation settings. Resending locks the pending row `FOR UPDATE`, replaces its salted credential and salt, bumps the credential version, restarts the seven-day expiry, and sends the replacement message, which states that any earlier link no longer works. The invitation form now offers `Send a new link instead` when the address already has a pending invitation.
- Mechanism recorded: A resend rotates the credential on the existing pending row rather than inserting a second row. That keeps the one-pending invariant structural instead of racing two rows through the partial unique index, and the prior link stops working immediately because its digest no longer matches. A re-invitation after a terminal invitation still inserts a fresh row with credential version 1, since the uniqueness index covers pending invitations only.
- Boundary held: Resend applies the same owner authorization, hosted-project, owner-profile, address-validity, and existing-member rules as creation; a rejected resend leaves the current credential untouched. Each credential version records its own delivery outcome, so the first invitation and its replacement are separately provable.
- Remaining: Task 25 (cancellation and expiry) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: Strict Credo flagged a three-level nested transaction body; the credential replacement moved into its own function. Final proof passes with real exit status: 7 resend tests, 76 participation and LiveView tests, `mix test` (837 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 10 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 9 complete: existing project-role detection

- Completed: Added `Participation.ProjectRoles` and wired it into invitation creation. The check compares the submitted address, as its runtime-keyed digest, against the digests of identities that are already members of that project — the immutable owner and its active participants — using constant-time comparison across every candidate.
- Boundary held: Detection reads no unrelated account and exposes no directory: an unrelated identity that already has an account is invited exactly like an unknown address. A detected owner or current participant returns the existing project role to the authorized owner and creates no invitation row and no credential material, so nothing can later be replayed. Detection is project-scoped, case-insensitive through the established normalization, and forgets a departed participant. The rejection path writes no log line at all, so neither the address, its digest, nor the outcome becomes an enumeration signal.
- Remaining: Task 10 (resend and fresh re-invitation) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: One test exposed that an unsaved project struct reached the membership query with a nil id; the entry point now requires a persisted project id and returns no role instead. Final proof passes with real exit status: 10 role-detection tests, 68 participation and LiveView tests, `mix test` (829 passing), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 9 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 2 complete: account-neutral invitation creation

- Completed: Added `project_invitations` with its migration and schema, the runtime-keyed `EmailDigest` derived from the deployment field-encryption key, the `Participation.Invitations` domain, and the participation-settings invitation form. Creation authorizes the immutable owner, requires a hosted project and an established owner display profile, normalizes the address through `ExternalIdentity.normalize_email/1`, stores it encrypted beside its comparison digest, issues one salted single-use credential with a seven-day expiry, and sends the invitation through the participation delivery boundary after the record commits.
- Boundary held: The invitation grants no authorization — an invited identity is still not an active participant and cannot open the project. The raw credential is never stored, only its salted digest; the address, digest, and credential are excluded from struct inspection and from the structured log, which names the project and invitation only. A partial unique index allows one pending invitation per project and normalized address, terminal invitations never block a fresh one, and a check constraint keeps a pending row credential-bearing while every terminal transition erases it. Creation resolves and creates no account or identity, and an address that already has an identity produces the same result shape and the same message wording as an unknown address.
- Failure behavior: A non-owner, unknown project, malformed id, device-authoritative project, missing owner profile, invalid address, or already-pending address is rejected without creating invitation state or sending mail; a provider failure leaves the pending invitation recoverable with a recorded failed delivery.
- Remaining: Task 9 (existing project-role detection) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: Strict Credo flagged one single-clause `with`, and Dialyzer flagged a closed email-context type plus an `Ecto.Multi` opaqueness mismatch on the single-step transaction; the lookup became a `case`, the context type accepts caller routing fields, and the one-step Multi became a direct insert whose pending uniqueness index still resolves concurrent creation. Final proof passes with real exit status: 13 invitation tests, 14 participation LiveView tests, `mix test` (819 passing), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 2 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 8 complete: participation email delivery

- Completed: Added `participation_email_deliveries` with its migration and schema, the four approved message builders (invitation, replacement, cancellation, removal), and the `Participation.EmailDelivery` boundary. The transport module and provider configuration are shared with passwordless access through a separate `:participation_email_delivery` config key, so a deterministic double can replace participation delivery alone.
- Boundary held: The delivery record stores only the event, subject, subject version, encrypted recipient address, status, short failure code, and timestamps — no credential, message body, or provider response column — and the address is excluded from struct inspection and stored as ciphertext. One event, subject, and version keeps one outcome across retries, a provider failure or crash records a minimized failure code, and the failure log carries neither the address, the invitation credential, nor the provider message. Messages name only the project label, the action, and one safe link, with identical wording whether or not the address already has an account.
- Remaining: Task 2 (account-neutral invitation creation) is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 31 participation tests including the delivery suite, `mix test` (803 passing), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 8 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 7 complete: shared account-level notification foundation

- Completed: Added `account_notifications` with its migration, schema, and the `SddOrchestrator.Notifications` context. A notification is a fixed field set — event type, subject reference, subject state version, title, body, optional project and actor labels, safe internal link, occurrence and read time — with no free-form payload column, so project content cannot be copied into it. A unique event, subject, version, and recipient index makes both `deliver/1` and the transactional `deliver_multi/3` idempotent under at-least-once replay, and a replay returns the stored record without resetting its read state.
- Boundary held: The stored unread row is the delivery guarantee and PubSub is only a presentation hint, proven by delivering with no subscriber and finding the durable unread record afterwards. List, fetch, and mark-read authorize at the account boundary and fail closed for another account, a missing id, or a malformed id; mark-read is idempotent and preserves the first read time. Event types are namespaced, and the reserved `delivery.` namespace is the seam Slice 07 extends instead of creating a second store.
- Remaining: Task 8 is next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 14 notification tests, `mix test` (793 passing), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 7 complete; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 28 complete: owner project-display profile workflow

- Completed: Added `/projects/:id/participation` with the owner display-profile form. The immutable owner creates or corrects only their own project label; the page states that invitations stay unavailable until it is saved, then reports them available. Conflicting labels are rejected inline for correction without an automatic suffix, blank, oversized, control-bearing, and email-shaped labels are rejected, and the owner's email is never rendered. A non-owner, unknown project, malformed id, or unauthenticated request returns to the catalog without exposing project content, and the domain action denies a non-owner independently of the view.
- Mechanism recorded: Participation management authenticates through the existing application session, matching the hosted project dashboard, because the immutable owner is derived from the project's personal-workspace account.
- Environment blocker: The Playwright harness has no way to establish an application session (GitHub sign-in credentials are unavailable), so authenticated keyboard, focus, and mobile-layout browser scenarios cannot run. The route's fail-closed behavior is proven in the browser, and the authenticated behavior is proven deterministically at the LiveView level, including accessible labelling, `aria-invalid`, error association, and the responsive action layout.
- Remaining: Tasks 7 and 8 are next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 32 participation LiveView and persistence tests, `mix test` (779 passing), `mix format --check-formatted`, `mix credo --strict`, and the participation route protection scenario in `assets/e2e/entry.spec.js`.
- Spec updates: Marked Task 28 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-29 - Task 6 complete: participant and member-profile persistence

- Completed: Added `project_participants` and `project_member_profiles` with their hosted migration, schemas, and the `SddOrchestrator.Participation` context. Owner derivation reads the immutable hosted project ownership boundary and fails closed for a device-authoritative project. Partial unique indexes enforce one active authorization per project and hosted identity and one active display-name comparison key per project, while check constraints keep active rows identity-bound, departed rows reasoned, and anonymized profiles account-free. Display names are trimmed, rejected when blank, oversized, control-bearing, or email-shaped, compared case-insensitively through NFKC folding, and stored with their accepted spelling.
- Boundary held: Participation authorization stays separate from presentation. Departure preserves the profile and its last accepted label, a later retention step can release the authorization-to-identity link, and anonymization removes the account link without deleting project history.
- Remaining: Tasks 28, 7, and 8 are next; the participation boundary capability becomes available only after Task 4.
- Failed checks: None. Focused proof passes with real exit status: 21 participation persistence tests, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 6 complete and moved the slice status to `In Progress`; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-28 - Task-size and execution sequence refined

- Completed: Applied the Task Size Gate, preserved every existing task label, and split the four unfinished broad tasks into thirty-two standard implementation tasks with focused proof and no task-size exception.
- Remaining: Implement ready Task 6 and the dependency-ordered invitation, proof, acceptance, authorization, removal, notification, privacy, and governance tasks; publish the participation boundary after Task 4 and governance after Task 5.
- Failed checks: None; implementation has not started.
- Spec updates: Split account notification and email delivery foundations, invitation creation and lifecycle, identity proof, acceptance, management, capability authorization, removal, leave, revocation, notification channels, retention, rights, logging, backup and processor propagation, and final review ownership; added AC-31 through AC-39 without changing approved behavior.

### 2026-07-28 - Participation capability ownership recorded

- Completed: Named Slice 08 as the sole provider of `capability:project-participation-boundary` after Task 4 and `capability:project-participation-governance` after Task 5, separating the usable authorization and handoff interface from its final lifecycle proof.
- Remaining: Implement Tasks 2–5 and the verification gate; each capability remains unavailable while its provider task is incomplete.
- Failed checks: None; implementation has not started.
- Spec updates: Added the canonical cross-specification dependency section, assigned participation-boundary readiness to Task 4, and assigned governance readiness to Task 5 without making Slice 07 an implementation prerequisite.

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
