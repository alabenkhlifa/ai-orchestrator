# Participation Operational Retention

## Status

Approved

## Outcome

Participation email-delivery diagnostics, account-level participation notifications, and minimized operational-security logs are removed on their approved schedules through one locked and restart-safe retention workflow without changing invitations, project authorization, revocation handoffs, or another notification namespace.

## Users

- Project owners, invitees, and participants whose operational records must not be retained longer than necessary.
- Operators who need short-lived delivery and security evidence for retry, diagnosis, and reconciliation.
- Privacy and security reviewers verifying storage limitation, minimization, and lifecycle isolation.

## In Scope

- Thirty-day cleanup of finalized `ParticipationEmailDelivery` diagnostics.
- Ninety-day cleanup of read and unread participation-namespace `AccountNotification` records.
- Fixed minimized participation operational-security events with no credential, email, project content, repository detail, secret, or unrelated identity.
- Thirty-day deletion of participation operational-security logs.
- Shared retention scheduling, locking, restart, idempotency, and reconciliation across the three rules.
- Compatibility with the separately owned participation identity-lifecycle cleanup rule.

## Out of Scope

- Invitation, participant, profile, or revocation identity-link lifecycle rules owned by the participation identity-lifecycle specification.
- Notification payload design, recipient routing, email message content, retry policy, or the shared notification-store schema.
- Guided-delivery notification retention or any non-participation notification namespace.
- Historical-attribution rights handling, backup expiry, processor propagation, project deletion, or final participation governance review.
- Product analytics, advertising, model training, or stable operational profiling.

## Primary Workflow

1. The supervised retention process acquires the existing shared advisory lock and evaluates the participation rules at a fixed time.
2. It deletes finalized participation email-delivery diagnostics whose 30-day operational purpose has ended while preserving invitations and authorization records.
3. It deletes read and unread participation-namespace account notifications at 90 days without touching current authorization or another notification namespace.
4. It deletes fixed minimized participation operational-security events at 30 days through the configured retention-capable log boundary.
5. A later locked run safely reconciles interrupted or missed work, reports category-level results, and does not restore deleted records or repeat provider-owned identity-link cleanup logic.

## Business Rules

- A finalized participation email-delivery diagnostic is deleted at the 30-day boundary measured from its last authoritative delivery attempt or completion time; pending retry state is not selected as finalized evidence.
- Deleting a delivery diagnostic cannot delete, cancel, consume, restore, or otherwise change an invitation, participant authorization, profile, revocation handoff, or account.
- A participation-namespace account notification is deleted at the 90-day boundary whether it is read or unread.
- Account-notification retention selects only approved participation event types and cannot delete a guided-delivery or future non-participation notification from the shared store.
- Deleting an account notification cannot grant, remove, restore, or otherwise change project authorization.
- Participation security logging accepts only an allowlisted event type, coarse outcome, UTC occurrence time, fixed reason classification when required, and a fresh non-secret correlation identifier.
- Participation security logs contain no invitation credential, email or digest, project or specification content, comment, evidence, repository detail, provider payload, secret, or unrelated identity.
- Participation operational-security logs are deleted at the 30-day boundary through a retention-capable sink invoked by the shared pruner.
- Every rule is idempotent, runs under the existing shared lock and scheduler, exposes only minimized category-level reconciliation results, and re-discovers overdue eligible records after restart.
- The participation identity-lifecycle provider remains the sole owner of direct `ProjectParticipant` and `ParticipationRevocation` identity-link cleanup. This specification may verify that its rule remains registered and reconciled but cannot redefine its selector, deadline, acknowledgement behavior, or retained handoff fields.

## Acceptance Criteria

- [AC-01] Given finalized participation email-delivery diagnostics reach 30 days after their last authoritative attempt or completion, when the locked retention workflow runs or later reconciles, then those diagnostics are deleted idempotently while pending retry state, invitations, participants, profiles, revocations, and accounts remain unchanged.
- [AC-02] Given read or unread participation-namespace account notifications reach 90 days, when the locked retention workflow runs or later reconciles, then those notifications are deleted idempotently without changing current project authorization or deleting another notification namespace.
- [AC-03] Given a participation security event is emitted or reaches 30 days, when logging and retention run, then the event contains only the approved structured minimum and a non-secret correlation identifier, contains none of the forbidden personal, project, repository, credential, secret, or unrelated-identity data, and is deleted idempotently without changing participation state; repeats, interruption, lock contention, and restart reconcile every operational-retention rule without duplicating identity-lifecycle authority.

## Open Questions

None.
