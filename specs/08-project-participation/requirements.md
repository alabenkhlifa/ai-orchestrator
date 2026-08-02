# Project Participation

## Status

Approved

## Outcome

The owner of one hosted project can invite another person by email to become an authorized participant in that project. The invited person receives no access until they prove control of the invited email and explicitly accept, after which current participation can be enforced by the project board and agent-delivery workflow.

## Users

- Hosted-project owners who need another person to contribute to one project.
- Invited business analysts, product owners, project managers, developers, and reviewers with varying technical knowledge.
- Current project participants who need to leave a project.
- Privacy, security, support, and operations personnel governing invitation and participation data.

## In Scope

- Participation in one hosted project without granting access to the owner's personal workspace or other projects.
- One immutable project `Owner` and zero or more `Participant` members.
- Owner-created invitations addressed to an email without a searchable user directory.
- Account-neutral invitation creation that does not disclose whether the email already belongs to an account.
- Proof of the invited email and explicit acceptance before access begins.
- Current participant listing needed for assignment and authorization consumers.
- Active-participant authorization and recipient routing that remain valid when a separate presentation profile is absent or being repaired.
- Participant access to project specifications, feature content, comments, and run evidence without management or credential authority.
- Project-specific owner and participant display names with one shared uniqueness boundary and minimized email visibility.
- Invitation-bound fresh email proof that never treats an unrelated active browser session as the invited identity.
- Seven-day, single-pending invitation lifecycle with resend invalidation, cancellation, decline, and fresh re-invitation.
- Invitation, participation-outcome, removal, and leave notifications through the approved email and in-product channels.
- Owner removal of a participant and participant self-leave.
- Immediate fail-closed authorization after removal, leave, invalid proof, cancellation, expiry, or other unsuccessful invitation outcomes.
- A durable removal and leave handoff that records the owner fallback and historical label without mutating Slice 07 feature, question, review, or run records.
- A read-only current-participant authorization contract for `specs/07-guided-specification-delivery/`.
- GDPR data contracts for invited emails, invitation state, participation, delivery, audit, support, logs, derived records, and processors.

## Out of Scope

- Participation in on-device projects, which remain unavailable to collaborators under `specs/05-project-storage-lifecycle/`.
- Workspace-wide, organization-wide, or multi-project membership.
- A searchable user directory or disclosure of whether an invited email has an account.
- Roles beyond immutable project `Owner` and `Participant`.
- Project ownership transfer, owner removal, or owner self-leave.
- Groups, teams, guest tiers, custom permissions, or role administration.
- Participant management by participants, project deletion, storage-mode changes, repository-connection changes, and provider, worker, agent, invitation, or session credential access.
- Public links, anonymous access, domain-wide access, or automatic membership.
- Chat, mobile push, webhook, or other external participation-notification channels beyond the approved invitation and removal emails.
- Slice 07 feature assignment, run-control, review, and notification behavior beyond the current-participant authorization and revocation-producer handoffs.
- Repository-provider credential sharing, worker credential transfer, or agent-provider credential sharing.
- General project deletion, storage migration, or cross-user project ownership transfer.

## Primary Workflow

1. Registering a hosted project creates the owner's project-specific display profile with an initial label, so the project is immediately usable; the authenticated owner may open participation management to review or change that label at any time.
2. The owner enters an email address; the product provides no searchable account directory and does not reveal whether the email already has an account.
3. The product creates an invitation for that project and sends the invitation through the approved email-delivery boundary. An email already attached to the owner or a current participant creates no invitation and shows the existing project role to the owner.
4. The invited person opens the invitation and proves control of the invited email through the approved passwordless verification boundary. If another hosted identity is active in the browser, the product explains that continuing authenticates the invited email for this browser and does not treat the existing session as proof.
5. Fresh proof creates or restores the stable hosted identity for the invited email and establishes its hosted browser session without revoking sessions belonging to another identity.
6. The product then identifies the project and owner display name, explains the participation consequence, asks for a project-specific participant display name, and requires explicit acceptance.
7. Successful acceptance creates one active `Participant` authorization and display profile for the proven stable hosted identity and project; every unsuccessful outcome leaves project access unchanged.
8. The project exposes the participant through its current-participant authorization interface for assignment, notifications, run control, review, and content access.
9. The owner may later remove the participant, or the participant may leave; either action ends future authorization, records one durable Slice 07 handoff, and does not transfer project ownership or directly mutate feature-delivery records.
10. Invitation and participation outcomes notify the approved recipients through the minimum email or in-product channel for that event.

## Business Rules

- Participation is scoped to one hosted project and grants no access to the owning workspace or any other project.
- The project owner is derived from the existing hosted project ownership boundary and remains the immutable `Owner` in the first release.
- The owner's project display profile is created together with the hosted project and carries an initial display name derived from the owner's GitHub login, never from their email. The owner may later edit only their own project display name, and no participation or delivery action may treat a missing owner label as missing owner authorization.
- The invitation action shows the owner display name the invitee will see and offers an inline correction, but an unedited initial label does not block sending.
- A non-owner may participate only through one active `Participant` authorization attached to their stable hosted identity.
- An active participant may view and edit project specifications and feature content, comment, and inspect agent-run evidence that belongs to the project.
- Participation does not authorize participant management, project deletion, storage-mode or repository-connection changes, or access to provider, worker, agent, invitation, or application-session credentials.
- Only the current project owner may create or cancel an invitation or remove a participant.
- A participant may leave the project without owner approval.
- An invitation is addressed to one email. Invitation request and delivery behavior must not disclose whether that email already has an account or participant record.
- Invitation creation must not expose a searchable account or identity directory.
- An invitation expires seven days after issuance.
- At most one pending invitation may exist for one project and normalized invited email.
- Resending invalidates the prior pending invitation and creates a fresh invitation with a new seven-day expiry.
- The owner may cancel a pending invitation and the invitee may decline it; cancellation and decline are terminal for that invitation.
- Re-invitation after expiry, cancellation, decline, removal, or leave creates a fresh invitation and requires fresh proof and acceptance. Participation is never restored automatically.
- Re-invitation after removal or leave reactivates the same non-anonymized project-member presentation identity under the fresh acceptance transaction and applies the newly accepted display name under the existing uniqueness rules. It never inserts a duplicate linked profile, never relinks anonymized history, and never reports an account-link conflict as invalid display-name input.
- Submitting the verified email of a current participant creates no new invitation; the owner sees the existing current-participant state already available through participation management.
- Sending or opening an invitation does not grant project access.
- Acceptance requires fresh proof of the invited email plus an explicit acceptance action for the identified project.
- Proof of another email, an existing session without invited-email proof, a forwarded invitation, or an unaccepted invitation must not grant access.
- Successful acceptance attaches participation to the stable hosted identity that proved the invited email, not to a browser, session, or email string alone.
- Successful acceptance records a project-specific display name as a presentation label, never as stable participant identity.
- A participant may change only their own project-specific display name.
- Owner and participant display-name comparison trims surrounding whitespace and is case-insensitively unique within one project while preserving the accepted spelling for display.
- A conflicting display name is rejected for explicit correction; the product must not select or append an automatic suffix.
- Current project participants see the owner and participant display names. The owner may see invitation and verified participant emails for membership management; each participant may see their own email; participants do not see another participant's or the owner's email through this feature. The owner's email is not used as their project display name.
- Historical attribution resolves through stable participant identity, shows the current project display name while participation is active, and preserves the last accepted display name as a non-interactive label after departure only while identifiable attribution remains necessary for project accountability. An approved rights or deletion workflow anonymizes the label when continued identification is unnecessary.
- A current participant cannot be anonymized in place. An approved verified-rights workflow must first complete the authorized removal or leave transition and then anonymize the resulting historical attribution; after departure, an approved verified request may override pending-handoff necessity without restoring access or deleting stable contribution history.
- At most one active participant authorization may exist for one hosted identity and project.
- Repeated, concurrent, invalid, canceled, expired, replayed, or otherwise unsuccessful invitation actions must not create duplicate or partial authorization.
- Inviting an email attached to the project owner or a current participant creates no invitation. The owner may see the existing project role because it is already authorized membership state, but the product must not disclose unrelated account or identity information.
- Invitation proof is bound to one invitation and its normalized invited email. An existing hosted session, including a session for another identity, is never sufficient proof.
- When fresh invitation proof succeeds, the browser becomes authenticated as the stable hosted identity that proved the invited email. Replacing the browser's current session cookie must not revoke another identity's server-side sessions.
- Current-participant reads and every protected consumer action must fail closed when participation is inactive, removed, left, stale, or absent.
- Current-participant authorization, enumeration, responsibility, and notification routing derive from the immutable owner or active `ProjectParticipant` record, never from `ProjectMemberProfile` existence. When presentation is unavailable, consumers receive an explicit absent-presentation state and may use only a neutral minimized label; they never fall back to email and never omit the active participant from authorization or recipient routing.
- Removing or leaving ends future project access and cannot remove, replace, or transfer the immutable owner.
- Removing or leaving atomically ends current participation and records one idempotent revocation handoff containing only the project, former participant, immutable owner fallback, last accepted project display name, reason, event time, and contract version needed by approved consumers.
- A revocation handoff may retain its former-account and former-hosted-identity links only until consumer acknowledgement and never beyond 30 days after departure. Cleanup preserves the non-identifying handoff identity, project, participant reference, owner fallback, reason, event time, contract version, and delivery state needed for audit and idempotency.
- Slice 08 does not mutate feature assignment, blocking-question, review, notification, contribution, or agent-run records. Slice 07 consumes the revocation handoff to clear current responsibility, preserve governed historical attribution, keep an active run under owner control, and deny former-participant actions.
- Participation must not expose or transfer repository-provider credentials, worker credentials, agent-provider credentials, session secrets, or invitation secrets.
- Invitation and resend send email to the invited address.
- Acceptance sends an in-product confirmation to the participant and an in-product outcome to the owner. Decline and expiry notify the owner in-product.
- Cancellation notifies the invitee by email. Removal notifies the former participant in-product at the account boundary and by email. Participant self-leave notifies the owner in-product.
- Participation notifications contain only the project display name, event or required action, relevant actor display name when necessary, time, and a safe product link. They contain no specification, feature, comment, evidence, repository, credential, or other project content.
- Invited emails, invitation and membership events, participation state, delivery records, support records, and security logs are personal data subject to approved purpose, lawful basis, necessity, access, retention, deletion, rights, processor, transfer, and review rules.
- Analytics may retain only aggregate genuinely anonymous measures without email hashes, project, workspace, invitation, participant, identity, network, or other linkable identifiers.

## Acceptance Criteria

- [AC-01] Given an authenticated owner manages one hosted project, when they submit an email invitation, then the product creates an account-neutral project invitation without exposing a searchable user directory or whether the email already has an account.
- [AC-02] Given an invitation has been sent or opened but not accepted, when project authorization is checked, then the invited person has no access and the existing owner and participants remain unchanged.
- [AC-03] Given the invited person freshly proves the invited email and explicitly accepts for the identified project, when acceptance commits, then exactly one active `Participant` authorization attaches their stable hosted identity to that project.
- [AC-04] Given the invitation is invalid, canceled, expired, replayed, already consumed, or proven through a different email, when acceptance is attempted, then no project access or partial participant state is created and the response exposes no unrelated account data.
- [AC-05] Given a person participates in one project, when they request another project or the owner's workspace, then participation in the first project grants no access.
- [AC-06] Given a non-owner attempts to invite or remove another person, when authorization is evaluated, then the action is rejected without changing invitations or participation.
- [AC-07] Given the owner removes an active participant, when the removal commits, then that identity is no longer a current participant and subsequent protected project access fails closed.
- [AC-08] Given an active participant leaves the project, when the leave commits, then their future project access ends without changing the owner or another participant.
- [AC-09] Given an action attempts to remove, replace, transfer, or make the project owner leave, when it is evaluated, then the immutable owner remains unchanged.
- [AC-10] Given a project is stored on-device, when participation management is requested, then collaboration remains unavailable and no hosted invitation or participation record is created.
- [AC-11] Given Slice 07 or another approved consumer requests current authorization, when the participant is active, removed, left, stale, or absent, then the interface returns only the current fail-closed project-scoped authorization result without changing participation.
- [AC-12] Given concurrent or repeated acceptance targets the same hosted identity and project, when the attempts settle, then at most one active participant authorization exists and no partial state remains.
- [AC-13] Given invitation, participation, delivery, support, or derived data is processed, when purpose, access, processor, transfer, and secondary-use controls run, then the approved data contract is enforced, secrets and unauthorized project content are not exposed, and analytics remain aggregate and genuinely anonymous.
- [AC-14] Given an active participant opens the project, when authorization succeeds, then they may view and edit its specifications and feature content, comment, and inspect project run evidence without receiving access to another project or the owning workspace.
- [AC-15] Given a participant attempts participant management, project deletion, storage or repository changes, or credential access, when authorization is evaluated, then the action is denied and no protected setting, credential, or secret is exposed.
- [AC-16] Given invited-email proof succeeds and acceptance is shown, when identity details are presented, then acceptance requires an available project-specific participant display name, the project and owner display name are visible, and no other participant email is exposed.
- [AC-17] Given an active participant leaves or is removed, when the change commits, then participation becomes inactive, future project authorization fails closed, and exactly one durable idempotent revocation handoff records the immutable owner fallback and last accepted project display name without directly mutating or canceling Slice 07 work.
- [AC-18] Given invitation resend or re-invitation is requested, when the lifecycle action succeeds, then at most one invitation remains pending per project and normalized email, the prior link is invalidated, and the fresh invitation has a new credential and seven-day expiry and requires fresh acceptance.
- [AC-19] Given the invitee declines an invitation, when decline commits, then the invitation becomes terminal, no access is created, the owner can see the declined outcome, and any later invitation requires a fresh flow.
- [AC-20] Given an active participant changes their project display name, when the trimmed name is available case-insensitively, then the preserved spelling becomes the current label; when it conflicts, the change is rejected without an automatic suffix or identity change, and departure preserves the last accepted label for historical attribution.
- [AC-21] Given an invitation is created, resent, or canceled, when email delivery runs, then the affected invitee receives the approved invitation, replacement, or cancellation message with only the minimum context and no account-disclosure signal.
- [AC-22] Given an invitation is accepted or declined, when notification runs, then acceptance confirms in-product to the participant and owner while decline notifies the owner in-product, with no project content or account-disclosure signal.
- [AC-23] Given a participant is removed or leaves, when in-product notification runs, then removal notifies the former participant at the account boundary, leave notifies the owner, and no notification restores access or exposes project content.
- [AC-24] Given any participation notification is inspected, when its payload and delivery records are reviewed, then they contain only the approved minimum project and action context and no specification, feature, comment, evidence, repository, credential, secret, or unrelated identity data.
- [AC-25] Given a departed participant's last project display name remains on historical contributions, when continued identifiable attribution is no longer necessary or an approved rights workflow requires anonymization, then the stable contribution history remains but the display label and account link no longer identify that person.
- [AC-26] Given the owner opens the invitation action, when the invitation is composed, then the owner display name the invitee will see is shown with an inline correction path that applies the same availability and no-suffix rules; sending is not blocked by an unedited initial label, and no email is presented as that label.
- [AC-40] Given a hosted project is registered, when registration commits, then the owner's project display profile exists with an initial display name derived from their GitHub login and never from their email, the owner is authorized on the project without depending on that label, and the owner may change the label at any time.
- [AC-41] Given a hosted project was registered before owner profiles were created at registration, when the backfill runs, then that project gains one owner display profile under the same rule, idempotently, without changing project ownership, participation, or any existing display name.
- [AC-42] Given the immutable owner or an active participant has no current `ProjectMemberProfile`, when an approved consumer checks authorization, enumerates current participants, resolves responsibility, or routes a notification, then stable identity and role remain available with an explicit absent-presentation state, the authorized person is not omitted, and no email-derived label is exposed.
- [AC-27] Given participation management or a participant list is shown, when identity labels are presented, then current members see project display names, the owner may see invitation and verified participant emails, each participant may see only their own email, and no participant sees another member's email.
- [AC-28] Given an invitation is opened while another hosted identity is active in the browser, when the invitee continues, then the product explains the identity change, requires fresh proof of the invited email, authenticates the proven stable identity for this browser, preserves unrelated server-side sessions, and still grants no project access before explicit acceptance.
- [AC-29] Given an owner submits an email already attached to the project owner or a current participant, when invitation creation is evaluated, then no invitation or credential is created, the existing project role is shown to the owner, and no unrelated account information is disclosed.
- [AC-30] Given the project owner changes their project display name, when the trimmed name is available case-insensitively, then the preserved spelling becomes the owner label; when it conflicts, the change is rejected without an automatic suffix, email-derived fallback, or ownership change.
- [AC-31] Given an invitation or participation record reaches its approved lifecycle boundary, when retention enforcement runs, then invitation credentials are erased immediately at every terminal transition, terminal invitations and departed authorization-to-identity links are deleted within 30 days, and active participation is retained only while active.
- [AC-32] Given participation email-delivery diagnostics reach their approved lifecycle boundary, when retention enforcement runs, then those records are deleted within 30 days without removing a still-required invitation or active authorization.
- [AC-33] Given participation operational-security logs reach their approved lifecycle boundary, when retention enforcement runs, then logs contain only approved minimum fields, expose no invitation secret or project content, and are deleted within 30 days.
- [AC-34] Given an invitation expires after seven days or the owner cancels it, when the lifecycle transition commits, then the invitation becomes terminal, its credential becomes unusable, no access is created, and a later invitation requires a fresh flow.
- [AC-35] Given a pending invitation expires, when notification projection runs, then the owner receives one minimized in-product outcome and the invitee receives no project-content disclosure.
- [AC-36] Given the owner removes a participant, when email delivery runs, then the former participant receives one minimized removal message without a credential, project content, or restored access.
- [AC-37] Given participation data enters encrypted rolling backups, when lifecycle enforcement runs, then those copies expire within 35 days and cannot restore deleted or anonymized identity links outside the approved recovery process.
- [AC-38] Given a verified deletion or anonymization action reaches derived, cache, index, export, or processor copies, when propagation runs, then the approved action reaches every configured copy without restoring project access.
- [AC-39] Given an account-level participation notification reaches its approved lifecycle boundary, when retention enforcement runs, then the notification is deleted within 90 days without changing current project authorization.
- [AC-43] Given a departed participant accepts a fresh re-invitation, when acceptance commits, then one active participant authorization exists, the existing linked historical project-member profile is reactivated with the newly accepted available display name, no duplicate linked profile is inserted, anonymized history is not relinked, and any structural conflict is reported without misclassifying it as invalid display-name input.
- [AC-44] Given a current participant has an approved verified rights disposition requiring anonymization, when the workflow runs, then participation ends through an authorized removal or leave transition before historical attribution is anonymized; given the person has departed, the approved disposition may override pending-handoff necessity without restoring access or deleting stable contribution history.
- [AC-45] Given a participation revocation has been acknowledged or reaches 30 days after departure, whichever occurs first, when lifecycle enforcement runs, then its former-account and former-hosted-identity links are cleared while its non-identifying, idempotent handoff state remains available.

## Open Questions

- None.
