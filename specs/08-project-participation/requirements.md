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
- Participant access to project specifications, feature content, comments, and run evidence without management or credential authority.
- A project-specific participant display name and minimized email visibility.
- Seven-day, single-pending invitation lifecycle with resend invalidation, cancellation, decline, and fresh re-invitation.
- Invitation, participation-outcome, removal, and leave notifications through the approved email and in-product channels.
- Owner removal of a participant and participant self-leave.
- Immediate fail-closed authorization after removal, leave, invalid proof, cancellation, expiry, or other unsuccessful invitation outcomes.
- Removal and leave handoff that clears current assignment, routes pending responsibility to the owner, preserves historical attribution, and leaves active agent runs under owner control.
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
- Slice 07 feature assignment, run-control, review, and notification behavior beyond the current-participant authorization handoff.
- Repository-provider credential sharing, worker credential transfer, or agent-provider credential sharing.
- General project deletion, storage migration, or cross-user project ownership transfer.

## Primary Workflow

1. The authenticated owner opens participation management for one hosted project.
2. The owner enters an email address; the product provides no searchable account directory and does not reveal whether the email already has an account.
3. The product creates an invitation for that project and sends the invitation through the approved email-delivery boundary.
4. The invited person opens the invitation and proves control of the invited email through the approved passwordless verification boundary.
5. The product identifies the project and participation consequence, asks for a project-specific display name, and requires explicit acceptance.
6. Successful acceptance creates one active `Participant` authorization and display label for the stable hosted identity and project; every unsuccessful outcome leaves project access unchanged.
7. The project exposes the participant through its current-participant authorization interface for assignment, notifications, run control, review, and content access.
8. The owner may later remove the participant, or the participant may leave; either action ends future authorization without transferring project ownership.
9. Invitation and participation outcomes notify the approved recipients through the minimum email or in-product channel for that event.

## Business Rules

- Participation is scoped to one hosted project and grants no access to the owning workspace or any other project.
- The project owner is derived from the existing hosted project ownership boundary and remains the immutable `Owner` in the first release.
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
- Submitting the verified email of a current participant creates no new invitation; the owner sees the existing current-participant state already available through participation management.
- Sending or opening an invitation does not grant project access.
- Acceptance requires fresh proof of the invited email plus an explicit acceptance action for the identified project.
- Proof of another email, an existing session without invited-email proof, a forwarded invitation, or an unaccepted invitation must not grant access.
- Successful acceptance attaches participation to the stable hosted identity that proved the invited email, not to a browser, session, or email string alone.
- Successful acceptance records a project-specific display name as a presentation label, never as stable participant identity.
- A participant may change only their own project-specific display name.
- Display-name comparison trims surrounding whitespace and is case-insensitively unique within one project while preserving the accepted spelling for display.
- A conflicting display name is rejected for explicit correction; the product must not select or append an automatic suffix.
- Current project participants see the owner and participant display names. The owner may see invitation and verified participant emails for membership management; each participant may see their own email; participants do not see another participant's or the owner's email through this feature.
- Historical attribution resolves through stable participant identity, shows the current project display name while participation is active, and preserves the last accepted display name as a non-interactive label after departure only while identifiable attribution remains necessary for project accountability. An approved rights or deletion workflow anonymizes the label when continued identification is unnecessary.
- At most one active participant authorization may exist for one hosted identity and project.
- Repeated, concurrent, invalid, canceled, expired, replayed, or otherwise unsuccessful invitation actions must not create duplicate or partial authorization.
- Current-participant reads and every protected consumer action must fail closed when participation is inactive, removed, left, stale, or absent.
- Removing or leaving ends future project access and cannot remove, replace, or transfer the immutable owner.
- Removing or leaving clears the former participant from current assignment, routes their pending blocking-question and review responsibility to the project owner, and preserves prior comments, decisions, evidence, and other contributions with non-interactive historical attribution subject to the approved necessity, retention, and anonymization rules.
- An active agent run is not canceled solely because its initiating, assigned, or responsible participant leaves or is removed; control returns to the project owner, who may continue or cancel it under Slice 07.
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
- [AC-13] Given invitation, participation, delivery, support, audit, log, or derived data is processed, when lifecycle and access controls run, then the approved data contract is enforced, secrets and unauthorized project content are not exposed, and analytics remain aggregate and genuinely anonymous.
- [AC-14] Given an active participant opens the project, when authorization succeeds, then they may view and edit its specifications and feature content, comment, and inspect project run evidence without receiving access to another project or the owning workspace.
- [AC-15] Given a participant attempts participant management, project deletion, storage or repository changes, or credential access, when authorization is evaluated, then the action is denied and no protected setting, credential, or secret is exposed.
- [AC-16] Given invitation acceptance or the participant list is shown, when identity labels are presented, then acceptance requires a project-specific display name, current participants see display names, the owner may see membership-management emails, each participant may see their own email, and other participant emails remain hidden.
- [AC-17] Given a participant with current assignment, pending responsibility, historical contributions, or an active run leaves or is removed, when the change commits, then current assignment clears, pending question and review responsibility route to the owner, historical contributions retain non-interactive attribution, the run remains active under owner control, and the former participant loses access.
- [AC-18] Given invitation creation, resend, cancellation, expiry, or re-invitation is requested, when the lifecycle action succeeds, then invitations expire after seven days, at most one remains pending per project and normalized email, resend invalidates the prior link, cancellation is terminal, and every re-invitation creates a fresh credential and requires fresh acceptance.
- [AC-19] Given the invitee declines an invitation, when decline commits, then the invitation becomes terminal, no access is created, the owner can see the declined outcome, and any later invitation requires a fresh flow.
- [AC-20] Given an active participant changes their project display name, when the trimmed name is available case-insensitively, then the preserved spelling becomes the current label; when it conflicts, the change is rejected without an automatic suffix or identity change, and departure preserves the last accepted label for historical attribution.
- [AC-21] Given an invitation is created, resent, canceled, or expires, when notification runs, then invitation and resend email the invitee, cancellation emails the invitee, expiry notifies the owner in-product, and each notification contains only the approved minimum context.
- [AC-22] Given an invitation is accepted or declined, when notification runs, then acceptance confirms in-product to the participant and owner while decline notifies the owner in-product, with no project content or account-disclosure signal.
- [AC-23] Given a participant is removed or leaves, when notification runs, then removal notifies the former participant in-product and by email, leave notifies the owner in-product, and no notification restores access or exposes project content.
- [AC-24] Given any participation notification is inspected, when its payload and delivery records are reviewed, then they contain only the approved minimum project and action context and no specification, feature, comment, evidence, repository, credential, secret, or unrelated identity data.
- [AC-25] Given a departed participant's last project display name remains on historical contributions, when continued identifiable attribution is no longer necessary or an approved rights workflow requires anonymization, then the stable contribution history remains but the display label and account link no longer identify that person.

## Open Questions

- None.
