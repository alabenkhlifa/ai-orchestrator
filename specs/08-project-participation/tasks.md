# Project Participation Tasks

## Status

In Progress

The invitation, authorization, notification, departure, historical-attribution,
owner-profile, and recipient-routing foundation is implemented through Task 36.
`capability:project-participation-boundary`,
`capability:project-owner-display-profile`, and
`capability:project-participation-recipient-routing` are ready. The legacy plan's
unfinished identity-lifecycle repair, processing, operational retention,
deletion, recovery, and final-governance outcomes now belong to focused
continuation specifications under `specs/25-` through `specs/29-`.
`capability:project-participation-governance` remains unavailable until
`specs/29-participation-completion/` completes its provider reconciliation and
verification gate. This parent is an umbrella with completed legacy foundation
and no duplicate child implementation ownership.

## Active Slice

Preserve the completed project-participation foundation, its ready consumer contracts, shared product rules, and release coordination while focused child specifications own every unfinished implementation outcome.

## Cross-Specification Dependencies

Requires:

- None.

Provides:

- `capability:project-participation-boundary` — ready after `Task 4`.
- `capability:project-owner-display-profile` — ready after `Task 34`.
- `capability:project-participation-recipient-routing` — ready after `Task 36`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Existing task labels are preserved; newly split tasks use the next unused labels and are listed by dependency order rather than numeric order.

## Proof Scope Gate

- Applies to: Task 36.

## Implementation Boundary

Included:

- The completed hosted invitation, proof, acceptance, authorization, management, display-profile, notification, removal, leave, revocation-producer, retention-foundation, rights, and recipient-routing implementation recorded by completed Tasks 1 through 36.
- The ready current-participant, owner-profile, and recipient-routing capabilities consumed by Slice 07 and other approved specifications.
- Shared product, identity, privacy, lifecycle, and release rules without duplicate child implementation.

Excluded:

- On-device project collaboration.
- Workspace-wide or organization-wide membership.
- Searchable user or account discovery.
- Roles beyond immutable `Owner` and `Participant`.
- Ownership transfer, owner removal, and owner leave.
- Public, anonymous, domain-wide, group, or team access.
- Slice 07 feature assignment, agent-run, review, evidence, preview, and notification implementation.
- Credential transfer or sharing.
- Fresh re-entry repair, active-participant rights sequencing, and bounded revocation identity links, owned by `specs/25-participation-identity-lifecycle/`.
- Participation processing inventory, support access, processor and transfer classification, redaction, and purpose limitation, owned by `specs/26-participation-data-protection-controls/`.
- Participation email-delivery, account-notification, and operational-security-log retention, owned by `specs/27-participation-operational-retention/`.
- Participation backup expiry and deletion or anonymization propagation, owned by `specs/28-participation-deletion-and-recovery/`.
- Final provider reconciliation, full verification, staged readiness, and governance publication, owned by `specs/29-participation-completion/`.

Deferred after this slice:

- Additional roles, custom permissions, delegated participation administration, and organization or workspace membership.
- Project ownership transfer and owner departure.
- Public links, guest tiers, groups, teams, and domain-managed access.
- Slice 07 consumption of the revocation handoff for assignment clearing, question and review fallback, historical contribution presentation, notification denial, and active-run control.
- `specs/25-participation-identity-lifecycle/` owns parent AC-43, AC-44, and AC-45.
- `specs/26-participation-data-protection-controls/` owns parent AC-13.
- `specs/27-participation-operational-retention/` owns parent AC-32, AC-33, and AC-39.
- `specs/28-participation-deletion-and-recovery/` owns parent AC-37 and AC-38.
- `specs/29-participation-completion/` owns final governance coordination and `capability:project-participation-governance`.
- Deferred criteria: AC-13, AC-32, AC-33, AC-37, AC-38, AC-39, AC-43, AC-44, AC-45
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

- [x] Task 36 — Repair active-participant recipient routing without profile coupling.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4, Task 34
  - Purpose: Keep authorization, responsibility, and notification routing tied to active participation when presentation data is absent.
  - Owned surfaces: `Participation.Boundary` active-participant enumeration, immutable-owner and `ProjectParticipant`-first query semantics, optional `ProjectMemberProfile` join, stable identity and role result, explicit absent-presentation state, neutral minimized presentation contract, no email fallback, stale and departed denial, Slice 07 recipient-routing compatibility fixtures, `capability:project-participation-recipient-routing` provider, and readiness write-back.
  - Owns: AC-42
  - Proof: Focused boundary and notification-consumer tests prove an active participant without a profile remains authorized and routable, an owner without a profile remains resolvable, no email-derived label is returned, stale and departed identities remain denied, project isolation holds, and capability readiness is recorded through task scope.

- [x] Task 20 — Enforce invitation and participation-record cleanup.
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

- [x] Task 22 — Enforce rights-aware historical attribution.
  - Size: Standard
  - Depends on: Task 17, Task 18, Task 29
  - Purpose: Preserve stable contribution history while removing unnecessary departed-person identification.
  - Owned surfaces: Historical-attribution necessity decision, verified anonymization action, account-link removal, anonymous former-participant label, stable contribution preservation, no access restoration, derived-copy propagation, project-deletion handling, fixtures, and `Privacy.Rights` integration.
  - Owns: AC-25
  - Proof: Focused necessity, verified request, anonymization, account-link, label, stable-history, no-restored-access, derived-copy, and project-deletion tests pass.

## Verification Gate

- [x] Completed foundation tasks retain their recorded focused and slice evidence.
- [x] Current-participant, owner-profile, and recipient-routing capabilities have one completed provider and readiness write-back.
- [x] Every unfinished criterion is mapped to one focused child specification without duplicate parent implementation ownership.
- [ ] `specs/29-participation-completion/` reconciles every child provider, runs the full deterministic gate, records staged readiness, and publishes `capability:project-participation-governance`.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
