# Project Participation Design

## Context

Hosted projects currently belong to one personal workspace and have no participant or invitation boundary. Slice 07 requires current authorized participants for assignment, notification, run control, review, and project-content access, but participation management is an independent access-control workflow with its own identity, delivery, revocation, privacy, and security lifecycle.

On-device projects remain authoritative to one operating-system boundary and cannot participate in hosted collaboration. Hosted identity and fresh verified-email proof already belong to `specs/03-hosted-passwordless-access/`; identity linking belongs to `specs/04-github-identity-linking/`; authoritative hosted storage belongs to `specs/05-project-storage-lifecycle/`.

## Proposed Approach

Add one project-scoped invitation and participation boundary for hosted projects. Before the first invitation, the immutable project owner establishes a project-specific display profile under the same uniqueness boundary used by participants. The owner invites an email without account discovery. The invitation grants no access. The invitee proves the invitation-bound email through the approved passwordless boundary, becomes authenticated as that stable hosted identity in the current browser, sees the identified project and participation consequence, and explicitly accepts. Acceptance creates one active participant authorization and display profile for the stable hosted identity and project atomically and idempotently.

Expose current project participation through a read-only authorization interface. Participants may work with project specifications, feature content, comments, and run evidence through later consumers, but they receive no membership administration, destructive project settings, repository or storage control, or credential authority. Invitations have a seven-day, single-pending lifecycle with invalidating resend, owner cancellation, invitee decline, and fresh re-invitation. Owner removal and participant self-leave end future authorization and record one durable versioned revocation handoff in the same transaction. Slice 08 does not mutate future feature, question, review, notification, contribution, or agent-run records; Slice 07 consumes the handoff to apply its own owner-fallback behavior. Historical attribution retains the last display name only while necessary for project accountability and is anonymized through the approved rights and deletion workflow. Email delivery and account-level in-product notification storage share reusable infrastructure while keeping invitation credentials and event payloads feature-specific and minimized.

## Components Affected

- Hosted-project participation settings and participant list.
- Email invitation request, delivery, proof, acceptance, decline, cancellation, and result surfaces.
- Hosted project owner and participant authorization domain.
- Participant project-content capability and protected-settings boundary.
- Project-specific owner and participant display identity with minimized email presentation.
- Participation email and in-product notification delivery and presentation.
- Passwordless verified-email proof handoff.
- Slice 07 current-participant authorization interface.
- Durable Slice 07 revocation-handoff outbox.
- Project-content authorization checks without long-lived authorization caching.
- Invitation and participation audit, support, privacy, retention, deletion, and rights workflows.

## Data and Access Boundaries

- `ProjectInvitation`: one project-scoped invitation addressed to an email, with inviter, protected acceptance state, lifecycle status, and only the approved delivery and diagnostic metadata.
- `ProjectParticipant`: one project-scoped active or inactive authorization attaching a stable hosted identity to the `Participant` role without changing project ownership or owning its presentation label.
- `ProjectMemberProfile`: one project-specific presentation profile for the immutable owner or one participant, with a stable account reference while active, role, accepted display name, comparison key, and anonymization state separate from authorization identity. The owner's profile is created with the project from their GitHub login; a participant's is captured at acceptance.
- `ParticipationRevocation`: one versioned, idempotent outbox handoff created atomically with removal or leave and containing only the project, former participant, owner fallback, last accepted display name, reason, event time, and consumer-delivery state.
- `AccountNotification`: the shared account-level in-product notification foundation for participation and later Slice 07 events, addressed only to the approved recipient and governed independently from project content.
- `ParticipationEmailDelivery`: one minimized invitation or participation email-delivery result with no credential or project content.

Required boundaries:

- The existing hosted project ownership boundary supplies the immutable `Owner`; this feature cannot transfer, remove, or replace it.
- `ProjectInvitation` grants no project authorization and cannot be used as a participant record.
- One pending invitation exists per project and normalized email, expires after seven days, and is replaced rather than duplicated by resend.
- Invitation request and failure responses do not disclose whether the email has an account, identity, invitation, or participation record.
- No searchable identity or account directory is exposed.
- Acceptance requires fresh proof of the invited email and explicit confirmation for the identified project.
- Fresh invitation proof authenticates the proven stable hosted identity in the current browser. It may replace another identity's browser cookie after a clear warning but never revokes that identity's server-side sessions or treats its session as proof.
- Active participation binds the stable hosted identity and project, never a session, browser, delivery record, or raw email alone.
- One hosted identity has at most one active participant authorization per project.
- Participation grants no workspace-wide or other-project access.
- Active participants may work with project specifications, feature content, comments, and run evidence but cannot manage participation, delete the project, change storage or repository connections, or access credentials.
- Registering a hosted project creates the owner's `ProjectMemberProfile` with an initial GitHub-login label. Owner and participant display names are project presentation labels, never stable identity and never derived from an email address. Resolving the immutable owner must not depend on that profile existing, because ownership comes from the hosted project workspace boundary rather than from a label.
- Owner and participant display names are trimmed, case-insensitively unique within one project, preserve accepted spelling, and never receive an automatic suffix.
- Current participants see display names. Only the owner sees invitation and other participant emails for membership management, while each participant may see their own email.
- An invitation request for an email attached to the immutable owner or an active participant returns the existing project role to the authorized owner and creates no invitation or credential.
- On-device projects cannot create hosted invitations or participants.
- Only the owner mutates invitations and other participants; an active participant may end only their own participation.
- Current authorization revalidates active project participation and fails closed after removal, leave, invalidation, or absence.
- Removal or leave makes participation inactive and inserts one `ParticipationRevocation` in the same transaction. Slice 08 never directly changes Slice 07 assignment, question, review, contribution, notification, or run state.
- Slice 07 owns idempotent consumption of `ParticipationRevocation`, including assignment clearing, owner responsibility fallback, governed historical attribution, active-run control, and former-participant denial on its records.
- Historical attribution resolves through stable identity, uses the current display name while active, and retains the last accepted display name after departure only while necessary for project accountability; approved rights or deletion handling removes the account link and anonymizes the label when continued identification is unnecessary.
- Notification channels and recipients follow the approved event matrix, and payloads contain only minimum project and action context without project content or credentials.
- Participation does not transfer or expose repository, worker, model-provider, application-session, or invitation credentials.
- Invitation and participant records, delivery and audit data, logs, caches, indexes, backups, exports, and derived records follow an approved personal-data lifecycle.

## Interfaces

- Participation-management interface: show current participant display names, owner-only membership-management emails, self email, and approved invitation details; expose only owner-authorized invitation, cancellation, and removal actions plus participant self-leave.
- Invitation interface: accept one email for one owned hosted project, avoid account discovery, create protected invitation state, and invoke the approved delivery boundary.
- Invitation-lifecycle interface: enforce seven-day expiry, one pending invitation per project and email, invalidating resend, owner cancellation, invitee decline, current-participant detection, and fresh re-invitation after every terminal state.
- Invited-email proof interface: bind fresh proof of the invited email to one invitation, warn before replacing another identity's browser cookie, establish the proven identity's hosted browser session, and never treat another session or sign-in method as equivalent proof.
- Acceptance interface: identify the project and consequence after proof, require explicit acceptance, and create one participant authorization or no partial state.
- Current-participant interface: return the minimum current project-scoped identity and authorization required by Slice 07 and other approved consumers without mutating participation.
- Project-capability interface: authorize project specifications, feature content, comments, and run evidence while denying participation management, destructive project settings, storage or repository changes, and credential access.
- Display-identity interface: create the owner's project profile with the project and backfill projects registered before that rule, capture a participant profile during acceptance, let each member change only their own trimmed project-specific display name, enforce case-insensitive project uniqueness without automatic suffixes, preserve the last accepted label for necessary historical attribution, and support approved anonymization without erasing stable contribution history.
- Revocation interface: remove or leave atomically, invalidate current authorization, insert one versioned `ParticipationRevocation`, preserve the immutable owner, and expose idempotent claim and acknowledgement operations without mutating consumer-owned records.
- Notification interface: provide the shared account-level record, unread/read lifecycle, recipient authorization, event-recipient idempotency, and minimized payload contract; deliver invitation, resend, and cancellation email; acceptance and decline in-product outcomes; expiry and leave owner notifications; and removal email plus account-level in-product notice.
- Privacy interface: enforce purposes, access, retention, deletion, rights, processor, transfer, audit, support, and genuinely anonymous analytics boundaries.

## Decisions and Tradeoffs

### Project-Scoped Participation

- Choice: Authorize participation for one hosted project rather than for the owner's personal workspace.
- Reason: Project scope follows least privilege and matches Slice 07 assignment, notification, run, review, and content boundaries.
- Consequence: Access to another project requires a separate accepted invitation, and on-device projects remain unavailable.

### Immutable Owner And Participant Role

- Choice: Keep the existing project owner immutable and add only one `Participant` role in the first release.
- Reason: The prerequisite needs a clear current-participant boundary without introducing ownership transfer, custom roles, or organization administration.
- Consequence: The approved participant capability boundary is enforced through the current-participant interface, while transfer, owner removal, and additional roles remain deferred.

### Project-Specific Owner And Participant Profiles

- Choice: Create the immutable owner's `ProjectMemberProfile` with the hosted project, carrying an initial display name derived from the owner's GitHub login, and store owner and participant labels under one case-insensitive project uniqueness boundary. Never derive a label from an email address. Keep owner authorization independent of whether any label exists.
- Reason: A project must be usable by the person who just created it. Requiring the owner to visit participation management before the project works makes a presentation label a precondition for delivery work, which is the wrong dependency: a label describes how the owner appears, not whether they are the owner. The owner's GitHub login is already the handle they registered the project under, so it is a truthful starting label rather than an invented one.
- Replaced tradeoff: The earlier choice required the owner to establish the label before the first invitation, to avoid deriving inconsistent labels from GitHub and passwordless sign-in methods. That inconsistency is now accepted deliberately: an owner starts with a derived GitHub label while a participant still chooses one at acceptance, because owners and participants arrive through different proofs and only the owner's is already a public handle.
- Consequence: Every hosted project has an owner label from birth, and projects registered before this rule are backfilled by the same rule. Owner and participant authorization identity remains separate from presentation, each member edits only their own label, conflicts require explicit correction, and anonymization can remove account linkage without erasing stable project history. The invitation action surfaces the owner label for correction instead of blocking on it.

### Email Invitation Without Directory Search

- Choice: Let only the owner invite an email and expose no searchable account directory or account-existence result.
- Reason: Email is understandable for non-technical users and avoids turning collaboration setup into an identity-enumeration surface.
- Consequence: Invitation delivery and acceptance remain account-neutral and must handle existing and new hosted identities without disclosing which path applies.

### Proof And Explicit Acceptance Before Access

- Choice: Require fresh proof of the invited email and explicit acceptance for the identified project before creating participation.
- Reason: Possession of a forwarded link, an unrelated session, or the owner's invitation action alone is insufficient authority to expose project content.
- Consequence: Every unsuccessful, canceled, invalid, expired, or unaccepted path leaves project authorization unchanged. A different active browser identity receives a warning; successful proof establishes the invited identity's browser session without revoking the other identity's server-side sessions, and project access still waits for explicit acceptance.

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

- Choice: On removal or leave, end authorization and insert one versioned `ParticipationRevocation` in the same transaction. Do not let Slice 08 mutate feature-delivery records.
- Reason: Slice 08 must be implemented and verified before Slice 07 exists, so directly clearing assignment or changing run state would create a circular implementation and verification dependency.
- Consequence: Slice 08 proves the fail-closed authorization and producer contract. Slice 07 owns idempotent consumption that clears current responsibility, preserves governed historical attribution, and leaves active runs under owner control without cancellation.

### Seven-Day Single-Pending Invitation Lifecycle

- Choice: Expire invitations after seven days, allow only one pending invitation per project and normalized email, make resend invalidate and replace the prior credential, let the owner cancel and the invitee decline, and require a fresh invitation after every terminal state.
- Reason: A bounded, single-current credential limits unintended access and gives both sides clear control without automatic restoration.
- Consequence: Current participants are shown through owner-visible membership state rather than receiving duplicate invitations. Re-invitation after expiry, cancellation, decline, removal, or leave starts a new proof and acceptance flow.

### Participant-Controlled Unique Display Name

- Choice: Let participants change only their own project display name; trim and compare it case-insensitively within the project, preserve accepted spelling, reject conflicts, and never allocate an automatic suffix.
- Reason: Unique project labels keep assignment understandable without exposing participant emails or confusing the label with stable identity.
- Consequence: Historical records reference stable participant identity, render the current name while active, and preserve the last accepted name after departure.

### Rights-Aware Historical Attribution

- Choice: Preserve stable contribution history without requiring permanent identifiable attribution. Retain the departed participant's last display name only while necessary for project accountability, then remove the account link and replace the label with an anonymous former-participant label when an approved rights or deletion workflow requires it.
- Reason: Project history must remain understandable, but a display name and stable identity link remain personal data and must not be retained indefinitely without necessity.
- Consequence: Anonymization does not delete comments, decisions, evidence, or run history and cannot restore access. The privacy design must define the necessity decision, verified request path, propagation to derived copies, and backup expiry.

### Minimal Event-Specific Notifications

- Choice: Email invitation, resend, cancellation, and removal events to the affected address; notify the owner in-product of acceptance, decline, expiry, and leave; confirm acceptance in-product to the participant; and provide an account-level in-product removal notice.
- Reason: Invitees need an external entry channel and removed participants need consequential-change awareness, while routine project outcomes belong inside the product.
- Consequence: Notification payloads contain only project display name, event or required action, necessary actor display name, time, and a safe link. Chat, push, and webhook channels remain out of scope.

### Hosted Persistence And Concurrency

- Choice: Store hosted participation in PostgreSQL through `ProjectInvitation`, `ProjectParticipant`, `ProjectMemberProfile`, `ParticipationRevocation`, `AccountNotification`, and `ParticipationEmailDelivery`. Normalize invited email through the established `ExternalIdentity.normalize_email/1` contract, retain the delivery address encrypted, and use a runtime-keyed comparison digest for indexed project-and-email uniqueness. Store invitation credentials only as a salted digest.
- Reason: The current hosted project and identity boundaries are PostgreSQL-backed, while protected comparison and credential material must support uniqueness without exposing reusable secrets.
- Consequence: Partial unique indexes enforce one pending invitation per project and email digest, one active participant per project and hosted identity, and one active display-name comparison key per project. Invitation creation serializes on project and email, and acceptance uses one `Ecto.Multi` with row locking to validate proof, consume the invitation, create participation and its profile, and enqueue notifications without partial state.

### Shared Email And In-Product Notification Foundation

- Choice: Reuse one application email-delivery behaviour and provider configuration while keeping passwordless and participation email builders, credentials, attempts, and `ParticipationEmailDelivery` diagnostics separate. Make `AccountNotification` the shared account-level in-product notification foundation that Slice 07 extends with its own event types.
- Reason: Transport and durable unread delivery are shared infrastructure, but invitation credentials and project-content authorization must not leak across feature boundaries.
- Consequence: Email is sent after authoritative state commits through an idempotent outbox operation. In-product records use a unique event, recipient, and version key, remain readable at the account boundary when project access has ended, and expose project details only through an independently authorized safe link.

### Fail-Closed Authorization Without Long-Lived Caching

- Choice: Resolve the immutable owner from the hosted project workspace and re-read active `ProjectParticipant` state for every protected project action in the first release. Do not introduce a long-lived participation authorization cache.
- Reason: Direct reads make removal and leave immediately effective and avoid a cache-invalidation dependency before the consumer surface exists.
- Consequence: Account sessions remain valid after project removal, but every project-content or management action fails closed. A future cache requires a separate versioned invalidation design and equivalent immediate-revocation proof.

### Participation Privacy Contract

- Choice: Process invited email, protected comparison and credential material, hosted identity and project references, owner and participant display profiles, invitation and participation state, revocation handoffs, notification and delivery records, necessary support and audit records, and transient abuse-protection signals only for the invitation and project-participation service. Use contract necessity for user-requested invitation, proof, participation, notification, and rights operations, and the documented legitimate-interest assessment only for minimum fraud, abuse, security, audit, and support processing.
- Reason: These records are personal data even when encrypted, hashed, pseudonymous, or indirectly linkable, and the feature must not create a reusable identity directory or social graph.
- Consequence: Project owners receive only membership-management email visibility; participants receive their own email and approved project labels; other project users receive no email visibility; support access is verified, least-privilege, purpose-limited, time-bounded, and audited; exports and verified rights handling reach active and derived records; configured email, hosting, backup, logging, and support processors receive only necessary fields; transfers require the deployment profile; and no participation data is used for analytics, advertising, model training, unrelated product improvement, or another secondary purpose. Final processor, transfer, retention, and accountable privacy or legal approval remains a release gate rather than proof of legal compliance from tests alone.

### Participation Data Lifecycle

- Choice: Make pending invitations unusable after seven days; erase credential digests and salts on every terminal transition; delete terminal invitation, email-delivery diagnostics, and a departed `ProjectParticipant` authorization-to-identity link within 30 days; delete in-product notifications within 90 days; delete operational-security logs within 30 days; and expire encrypted rolling backups within 35 days. Retain active participation only while active. After the 30-day departed-participant window, a historical `ProjectMemberProfile` may retain its account link and last display label only while project accountability requires identifiable attribution; an approved anonymization or project-deletion event removes that remaining link and replaces the label with an anonymous former-participant label.
- Reason: The workflow needs bounded replay, dispute, security, notification, and recovery evidence without retaining an indefinite email or membership graph.
- Consequence: The retention pruner, verified rights workflow, project deletion, exports, caches, indexes, backups, and configured processors must propagate deletion or anonymization. Deployment-specific processors, regions, transfer safeguards, final retention approval, and accountable privacy or legal review remain release-gate evidence.

### Verification Contract

- Choice: Use the established Phoenix gate plus feature-specific domain, transaction, concurrency, delivery, privacy, security, and browser proof.
- Reason: Participation changes project authorization and sends external email, so structural validation alone cannot establish the contract.
- Consequence: Required proof is `mix check`; `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix credo --strict`; `mix dialyzer`; `mix deps.audit`; `mix sobelow --config`; `mix test`; `npm --prefix assets ci`; `npm --prefix assets run test:e2e`; `MIX_ENV=prod mix assets.deploy`; and `MIX_ENV=prod mix release`, with deterministic delivery doubles and concurrency and failure tests under the same gate.

## Risks

- Invitation behavior can disclose whether an account exists. Keep request, resend, and failure outcomes account-neutral and expose no directory.
- Forwarded or replayed invitations can grant unintended access. Bind acceptance to fresh invited-email proof, explicit project confirmation, expiry, single-use state, and idempotent commit.
- Stale authorization can expose project content after removal or leave. Revalidate current participation and invalidate any approved cache or capability path.
- A participant could receive workspace or other-project access accidentally. Enforce project scope at domain, query, UI, and integration boundaries.
- Participation can leak credentials or repository authority. Keep provider, worker, agent, session, and invitation secrets outside membership and consumer payloads.
- Invitation and membership history can become an indefinite social graph. Minimize retained fields, restrict access, bound retention, and enforce deletion and rights behavior.
- Removal can orphan Slice 07 responsibilities or erase historical accountability. Enforce the owner handoff and preserve stable contribution history while applying approved attribution necessity and anonymization.
- Duplicate or misleading display names can make assignment ambiguous. Keep stable identity separate from the label, enforce one owner-and-participant uniqueness boundary, and reject conflicts without automatic suffixes.
- Delivery or notification differences can disclose account or membership state. Preserve account-neutral invitation responses and keep event-specific notifications addressed only to already authorized or directly affected recipients.

## Open Questions

- None.
