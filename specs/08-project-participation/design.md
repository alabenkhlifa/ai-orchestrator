# Project Participation Design

## Context

Hosted projects currently belong to one personal workspace and have no participant or invitation boundary. Slice 07 requires current authorized participants for assignment, notification, run control, review, and project-content access, but participation management is an independent access-control workflow with its own identity, delivery, revocation, privacy, and security lifecycle.

On-device projects remain authoritative to one operating-system boundary and cannot participate in hosted collaboration. Hosted identity and fresh verified-email proof already belong to `specs/03-hosted-passwordless-access/`; identity linking belongs to `specs/04-github-identity-linking/`; authoritative hosted storage belongs to `specs/05-project-storage-lifecycle/`.

## Proposed Approach

Add one project-scoped invitation and participation boundary for hosted projects. The existing project owner invites an email without account discovery. The invitation grants no access. The invitee proves the invited email through the approved passwordless boundary, sees the identified project and participation consequence, and explicitly accepts. Acceptance creates one active participant authorization for the stable hosted identity and project atomically and idempotently.

Expose current project participation through a read-only authorization interface. Participants may work with project specifications, feature content, comments, and run evidence, but they receive no membership administration, destructive project settings, repository or storage control, or credential authority. Acceptance records a case-insensitively unique project-specific display name while limiting email visibility to the owner for membership management and to each participant for their own identity. Invitations have a seven-day, single-pending lifecycle with invalidating resend, owner cancellation, invitee decline, and fresh re-invitation. Owner removal and participant self-leave end future authorization, clear current assignment, route pending responsibility to the owner, preserve the last display name as non-interactive historical attribution, and leave active runs under owner control. Send only the approved minimum email and in-product notifications for invitation and participation outcomes. Keep persistence mechanisms and privacy lifecycles open until the remaining technical decisions are resolved.

## Components Affected

- Hosted-project participation settings and participant list.
- Email invitation request, delivery, proof, acceptance, decline, cancellation, and result surfaces.
- Hosted project owner and participant authorization domain.
- Participant project-content capability and protected-settings boundary.
- Project-specific display identity and minimized email presentation.
- Participation email and in-product notification delivery and presentation.
- Passwordless verified-email proof handoff.
- Slice 07 current-participant authorization interface.
- Project-content authorization checks and cache invalidation boundary.
- Invitation and participation audit, support, privacy, retention, deletion, and rights workflows.

## Data and Access Boundaries

- `ProjectInvitation`: one project-scoped invitation addressed to an email, with inviter, protected acceptance state, lifecycle status, and only the approved delivery and diagnostic metadata.
- `ProjectParticipant`: one project-scoped active or inactive authorization attaching a stable hosted identity and project-specific display label to the `Participant` role without changing project ownership.
- `ParticipationNotification`: one minimized email or account-level in-product invitation or participation event addressed only to the approved recipient and governed independently from project content.

Required boundaries:

- The existing hosted project ownership boundary supplies the immutable `Owner`; this feature cannot transfer, remove, or replace it.
- `ProjectInvitation` grants no project authorization and cannot be used as a participant record.
- One pending invitation exists per project and normalized email, expires after seven days, and is replaced rather than duplicated by resend.
- Invitation request and failure responses do not disclose whether the email has an account, identity, invitation, or participation record.
- No searchable identity or account directory is exposed.
- Acceptance requires fresh proof of the invited email and explicit confirmation for the identified project.
- Active participation binds the stable hosted identity and project, never a session, browser, delivery record, or raw email alone.
- One hosted identity has at most one active participant authorization per project.
- Participation grants no workspace-wide or other-project access.
- Active participants may work with project specifications, feature content, comments, and run evidence but cannot manage participation, delete the project, change storage or repository connections, or access credentials.
- The display name is a project presentation label, never stable identity; project-level uniqueness is only a presentation constraint.
- Display names are trimmed, case-insensitively unique within one project, preserve accepted spelling, and never receive an automatic suffix.
- Current participants see display names. Only the owner sees invitation and other participant emails for membership management, while each participant may see their own email.
- On-device projects cannot create hosted invitations or participants.
- Only the owner mutates invitations and other participants; an active participant may end only their own participation.
- Current authorization revalidates active project participation and fails closed after removal, leave, invalidation, or absence.
- Removal or leave clears current assignment, routes pending question and review responsibility to the owner, preserves non-interactive historical attribution, and leaves active agent runs under owner control.
- Historical attribution resolves through stable identity, uses the current display name while active, and retains the last accepted display name after departure.
- Notification channels and recipients follow the approved event matrix, and payloads contain only minimum project and action context without project content or credentials.
- Participation does not transfer or expose repository, worker, model-provider, application-session, or invitation credentials.
- Invitation and participant records, delivery and audit data, logs, caches, indexes, backups, exports, and derived records follow an approved personal-data lifecycle.

## Interfaces

- Participation-management interface: show current participant display names, owner-only membership-management emails, self email, and approved invitation details; expose only owner-authorized invitation, cancellation, and removal actions plus participant self-leave.
- Invitation interface: accept one email for one owned hosted project, avoid account discovery, create protected invitation state, and invoke the approved delivery boundary.
- Invitation-lifecycle interface: enforce seven-day expiry, one pending invitation per project and email, invalidating resend, owner cancellation, invitee decline, current-participant detection, and fresh re-invitation after every terminal state.
- Invited-email proof interface: bind fresh proof of the invited email to one invitation without treating another session or sign-in method as equivalent proof.
- Acceptance interface: identify the project and consequence after proof, require explicit acceptance, and create one participant authorization or no partial state.
- Current-participant interface: return the minimum current project-scoped identity and authorization required by Slice 07 and other approved consumers without mutating participation.
- Project-capability interface: authorize project specifications, feature content, comments, and run evidence while denying participation management, destructive project settings, storage or repository changes, and credential access.
- Display-identity interface: capture and let the participant change their trimmed project-specific display name, enforce case-insensitive project uniqueness without automatic suffixes, and preserve the last accepted label for historical attribution.
- Revocation interface: remove or leave atomically, invalidate current authorization, clear assignment, route pending responsibility to the owner, preserve historical attribution, keep active runs under owner control, and preserve the immutable owner.
- Notification interface: deliver invitation, resend, and cancellation email; acceptance and decline in-product outcomes; expiry and leave owner notifications; and removal email plus account-level in-product notice using only approved minimum context.
- Privacy interface: enforce purposes, access, retention, deletion, rights, processor, transfer, audit, support, and genuinely anonymous analytics boundaries.

## Decisions and Tradeoffs

### Project-Scoped Participation

- Choice: Authorize participation for one hosted project rather than for the owner's personal workspace.
- Reason: Project scope follows least privilege and matches Slice 07 assignment, notification, run, review, and content boundaries.
- Consequence: Access to another project requires a separate accepted invitation, and on-device projects remain unavailable.

### Immutable Owner And Participant Role

- Choice: Keep the existing project owner immutable and add only one `Participant` role in the first release.
- Reason: The prerequisite needs a clear current-participant boundary without introducing ownership transfer, custom roles, or organization administration.
- Consequence: Participant capability details still require product approval, while transfer, owner removal, and additional roles remain deferred.

### Email Invitation Without Directory Search

- Choice: Let only the owner invite an email and expose no searchable account directory or account-existence result.
- Reason: Email is understandable for non-technical users and avoids turning collaboration setup into an identity-enumeration surface.
- Consequence: Invitation delivery and acceptance remain account-neutral and must handle existing and new hosted identities without disclosing which path applies.

### Proof And Explicit Acceptance Before Access

- Choice: Require fresh proof of the invited email and explicit acceptance for the identified project before creating participation.
- Reason: Possession of a forwarded link, an unrelated session, or the owner's invitation action alone is insufficient authority to expose project content.
- Consequence: Every unsuccessful, canceled, invalid, expired, or unaccepted path leaves project authorization unchanged.

### Owner Management And Participant Self-Leave

- Choice: Only the immutable owner may invite, cancel invitations, or remove participants; an active participant may leave without owner approval.
- Reason: Owner-only management prevents participant privilege escalation, while self-leave avoids forced continued association.
- Consequence: Delegated membership administration, owner transfer, and owner leave require later specifications.

### Participant Project Capabilities

- Choice: Let active participants view and edit project specifications and feature content, comment, and inspect run evidence. Keep participation management, project deletion, storage and repository changes, and every provider, worker, agent, invitation, or session credential owner-only or outside participant access.
- Reason: Participants need the project content required for specification and delivery without receiving unrelated destructive or secret-bearing authority.
- Consequence: Slice 07 decides which current participants may start, cancel, approve, or reject runs; this prerequisite supplies the current participant identity and base project-content authorization.

### Project Display Identity And Minimized Email Visibility

- Choice: Require a project-specific display name at acceptance. Show display names to current project participants, expose invitation and verified participant emails only to the owner for membership management, and let each participant see only their own email.
- Reason: Assignment and collaboration need understandable labels, but an email address is personal data and does not need project-wide disclosure.
- Consequence: Stable hosted identity remains the authorization key. Project-level display-name uniqueness is only a presentation constraint, and participants control later edits to their own label.

### Removal Handoff Without Run Cancellation

- Choice: On removal or leave, clear current assignment, route pending blocking-question and review responsibility to the owner, preserve prior contributions with non-interactive attribution, and keep active runs under owner control.
- Reason: Access must end immediately without erasing project history, losing pending work, or making membership change an implicit run-cancellation action.
- Consequence: Historical attribution becomes separately governed retained personal data. Slice 07 must consume the handoff and allow the owner to continue or cancel the run.

### Seven-Day Single-Pending Invitation Lifecycle

- Choice: Expire invitations after seven days, allow only one pending invitation per project and normalized email, make resend invalidate and replace the prior credential, let the owner cancel and the invitee decline, and require a fresh invitation after every terminal state.
- Reason: A bounded, single-current credential limits unintended access and gives both sides clear control without automatic restoration.
- Consequence: Current participants are shown through owner-visible membership state rather than receiving duplicate invitations. Re-invitation after expiry, cancellation, decline, removal, or leave starts a new proof and acceptance flow.

### Participant-Controlled Unique Display Name

- Choice: Let participants change only their own project display name; trim and compare it case-insensitively within the project, preserve accepted spelling, reject conflicts, and never allocate an automatic suffix.
- Reason: Unique project labels keep assignment understandable without exposing participant emails or confusing the label with stable identity.
- Consequence: Historical records reference stable participant identity, render the current name while active, and preserve the last accepted name after departure.

### Minimal Event-Specific Notifications

- Choice: Email invitation, resend, cancellation, and removal events to the affected address; notify the owner in-product of acceptance, decline, expiry, and leave; confirm acceptance in-product to the participant; and provide an account-level in-product removal notice.
- Reason: Invitees need an external entry channel and removed participants need consequential-change awareness, while routine project outcomes belong inside the product.
- Consequence: Notification payloads contain only project display name, event or required action, necessary actor display name, time, and a safe link. Chat, push, and webhook channels remain out of scope.

## Risks

- Invitation behavior can disclose whether an account exists. Keep request, resend, and failure outcomes account-neutral and expose no directory.
- Forwarded or replayed invitations can grant unintended access. Bind acceptance to fresh invited-email proof, explicit project confirmation, expiry, single-use state, and idempotent commit.
- Stale authorization can expose project content after removal or leave. Revalidate current participation and invalidate any approved cache or capability path.
- A participant could receive workspace or other-project access accidentally. Enforce project scope at domain, query, UI, and integration boundaries.
- Participation can leak credentials or repository authority. Keep provider, worker, agent, session, and invitation secrets outside membership and consumer payloads.
- Invitation and membership history can become an indefinite social graph. Minimize retained fields, restrict access, bound retention, and enforce deletion and rights behavior.
- Removal can orphan Slice 07 responsibilities or erase historical accountability. Resolve handoff and attribution rules before implementation.
- Duplicate or misleading display names can make assignment ambiguous. Keep stable identity separate from the label and resolve editing and disambiguation before implementation.
- Delivery or notification differences can disclose account or membership state. Preserve account-neutral invitation responses and keep event-specific notifications addressed only to already authorized or directly affected recipients.

## Open Questions

- Which persistence, locking, uniqueness, idempotency, and concurrency model implements invitation and participant state?
- How does invitation delivery reuse or separate from passwordless magic-link delivery while keeping credentials and diagnostics isolated?
- How are current participation, cache invalidation, active sessions, and consumer authorization kept consistent after removal or leave?
- Which audit, support, notification persistence, historical-attribution retention, deletion, rights, backup, processor, and transfer mechanisms implement the approved data contract?
- Which automated, security, privacy, concurrency, failure, delivery, and browser commands form the verification gate?
