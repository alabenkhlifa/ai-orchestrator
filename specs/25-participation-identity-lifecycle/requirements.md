# Participation Identity Lifecycle

## Status

Approved

## Outcome

A participant who leaves or is removed can rejoin through a fresh invitation without duplicating or relinking historical presentation, departure handoffs stop retaining former identity links on an approved schedule, and a verified rights workflow ends current participation before anonymizing historical attribution.

## Users

- Project owners re-inviting a person who previously left or was removed.
- Former participants completing a fresh proof and acceptance flow.
- Current and former participants exercising an approved verified anonymization right.
- Privacy and operations personnel enforcing departure-link retention and rights workflows.

## In Scope

- Fresh re-invitation and acceptance after removal or leave.
- Reactivation of an existing linked historical `ProjectMemberProfile` without changing its stable identifier.
- Safe creation of a new active profile only when no linked historical profile exists.
- Permanent separation between anonymized historical profiles and later active participation.
- Immediate former-identity-link cleanup when a revocation handoff is acknowledged, with a 30-day maximum when acknowledgement does not arrive.
- Ordered verified-rights handling that ends current participation before anonymizing historical attribution.
- Verified-request override of pending-handoff attribution necessity after departure.

## Out of Scope

- Changes to invitation creation, proof, expiry, resend, or notification content except where acceptance consumes their existing contracts.
- Re-linking or rewriting an anonymized historical profile.
- Slice 07 revocation-consumer behavior, responsibility reassignment, or run handling.
- Project-owner anonymization, ownership transfer, owner removal, or owner self-leave.
- Participation email-delivery retention, account-notification retention, security logs, backups, processors, or the wider participation governance gate.
- Jurisdiction-specific legal adjudication or deployment-specific rights notices and controller evidence.

## Primary Workflow

1. A former participant receives a fresh invitation after removal or leave and freshly proves the invited email.
2. On explicit acceptance, the service locks the applicable participation and presentation state, creates one fresh active authorization, and reactivates the linked historical profile with the newly accepted project label. If no linked historical profile exists, it creates one new active profile without changing any anonymized history.
3. A later departure produces the existing durable revocation handoff and immediately ends access.
4. Consumer acknowledgement clears the handoff's former account and hosted-identity links; if acknowledgement does not arrive, retention clears both links no later than 30 days after departure while preserving the non-identifying handoff core.
5. When a verified anonymization request concerns a current participant, the approved rights workflow first commits the authoritative departure transition and then anonymizes the resulting historical attribution.
6. When the verified requester has already departed, the rights workflow may override pending-handoff attribution necessity and anonymize without waiting for acknowledgement; unverified processing continues to respect the necessity decision.

## Business Rules

- Re-invitation after removal or leave always requires a fresh invitation, fresh invited-email proof, and explicit acceptance; access is never restored automatically.
- Acceptance creates exactly one active `ProjectParticipant` authorization for the newly proven hosted identity and project.
- When the accepted account has one linked historical participant profile in the project, acceptance reactivates and updates that same profile in the acceptance transaction, preserving its identifier and applying the newly accepted label.
- The reactivated profile keeps the participant role, returns to active presentation state, and applies the same trimmed, case-insensitive project uniqueness and no-automatic-suffix rules as first acceptance.
- Acceptance creates a new participant profile only when no profile remains linked to the accepted account and project.
- An anonymized historical profile remains anonymous and unlinked forever. A later fresh acceptance may create a separate active profile but must not reuse, relink, rename, or reactivate the anonymized row.
- Participant creation or profile-state conflicts return a typed identity-lifecycle failure distinct from invalid display-name syntax. A genuine unavailable label remains a display-name conflict, and invalid label syntax remains invalid display-name input.
- Participant authorization, profile activation or creation, invitation consumption, and acceptance notifications commit atomically; a failure leaves the invitation pending and creates no partial active state.
- Acknowledging a `ParticipationRevocation` clears `former_hosted_identity_id` and `former_account_id` in the acknowledgement transaction.
- If a revocation remains unacknowledged, retention clears both former-identity links at the 30-day boundary measured from `occurred_at`. Cleanup is idempotent and never changes active authorization.
- Clearing former-identity links preserves the revocation identifier, project, participant-history reference, owner fallback, reason, occurrence time, contract version, and acknowledgement state required for idempotent consumer reconciliation. Its last display label remains governed separately by attribution necessity and anonymization.
- Direct historical-attribution anonymization continues to refuse a current participant. An approved verified-rights workflow must commit departure first and anonymize only after the profile becomes historical.
- A verified request may override pending-consumer-handoff necessity only after participation has ended. Without a verified request, an unacknowledged handoff continues to block anonymization.
- Anonymization preserves stable contribution and handoff history, removes the account and hosted-identity links and identifying label covered by the action, never restores project access, and never substitutes an email-derived label or stable pseudonym.

## Acceptance Criteria

- [AC-01] Given a removed or departed participant has a linked historical project profile, when they freshly prove a new invitation and explicitly accept with an available label, then exactly one active participant authorization is created, the same profile identifier becomes active with the newly accepted label, the invitation is consumed, and acceptance notifications commit atomically.
- [AC-02] Given fresh acceptance finds no linked historical profile, when it commits, then one new active participant profile is created; any anonymized historical profile remains anonymous, unlinked, and unchanged, and no email-derived label is used.
- [AC-03] Given re-acceptance encounters invalid label syntax, an unavailable label, an incompatible linked profile state, or another participant-identity conflict, when the transaction fails, then no partial authorization, profile, invitation, or notification change remains and identity-lifecycle conflicts are not reported as invalid display-name input.
- [AC-04] Given a participation revocation is acknowledged before 30 days or reaches 30 days without acknowledgement, when acknowledgement or retention commits, then `former_hosted_identity_id` and `former_account_id` are cleared idempotently while the non-identifying handoff core, active authorization state, and consumer acknowledgement state remain correct.
- [AC-05] Given a verified anonymization request concerns a current participant, when the approved rights workflow runs, then it first ends participation through the authoritative departure transition and only then anonymizes historical attribution, with access remaining denied if anonymization must be retried.
- [AC-06] Given a departed participant still has an unacknowledged revocation handoff, when anonymization is requested, then an approved verified request may override that pending-handoff necessity while an unverified action is refused; successful anonymization preserves stable history without an account link, hosted-identity link, identifying label, email-derived label, or restored access.

## Open Questions

- None.
