# Participation Deletion And Recovery

## Status

Approved

## Outcome

Participation identity links removed by retention, project deletion, or an approved anonymization workflow remain removed across encrypted backups and every configured derived or processor copy without restoring project access.

## Users

- Departed project participants whose participation data reaches deletion or anonymization.
- Project owners whose project history must remain coherent without retaining unnecessary identity links.
- Privacy, security, and operations personnel responsible for backup and downstream-cleanup enforcement.

## In Scope

- Thirty-five-day encrypted rolling-backup expiry for participation data.
- Recovery-only backup access and anonymization or deletion tombstones applied before restored participation data becomes readable.
- Idempotent deletion and anonymization propagation to configured processors, caches, indexes, exports, and other non-backup derived copies.
- Restricted retry and acknowledgement state that contains no project content, credential, or deleted identity value.
- Reconciliation that cannot restore participation or historical identity links.

## Out of Scope

- The primary-store participation retention and rights decisions owned by `specs/25-participation-identity-lifecycle/`.
- Email-delivery, account-notification, and operational-security-log retention owned by `specs/27-participation-operational-retention/`.
- Deployment-specific vendor selection, controller details, processor agreements, regions, transfer safeguards, or final legal approval.
- Project deletion authorization, ownership transfer, or restoration of project access.

## Primary Workflow

1. A primary-store retention, project-deletion, or approved anonymization action removes an identity link and emits its minimum cleanup intent.
2. Recovery controls preserve the deletion or anonymization tombstone and expire encrypted rolling backups within 35 days.
3. Configured non-backup destinations receive idempotent minimum-field cleanup requests and record acknowledgements or restricted retry state.
4. Reconciliation retries incomplete destinations while every authorization and identity-link read remains fail closed.

## Business Rules

- Encrypted participation backups are recovery-only and expire within 35 days.
- Recovery applies deletion and anonymization tombstones before any restored participation record can become readable.
- A restored backup cannot recreate an erased participant, profile, or revocation identity link.
- Cleanup requests contain only the destination, action, opaque subject reference, idempotency key, and timing needed by the configured destination.
- Processor, cache, index, export, and derived-copy cleanup is idempotent and records only minimum acknowledgement or normalized failure state.
- Incomplete cleanup does not restore project authorization, notification routing, presentation, or identifiable historical attribution.
- Deployment-specific live enforcement evidence remains a release gate; deterministic adapter and configuration proof is required for local verification.

## Acceptance Criteria

- [AC-01] Given participation data enters encrypted rolling backups, when the approved lifecycle is enforced, then every backup expires within 35 days, remains recovery-only, and applies deletion and anonymization tombstones before restored data can become readable.
- [AC-02] Given an approved participation deletion or anonymization action, when propagation runs, then every configured processor, cache, index, export, and other non-backup derived copy receives one idempotent minimum-field cleanup request and records its acknowledgement or restricted retry state.
- [AC-03] Given propagation is delayed, retried, interrupted, or resumed after recovery, when authorization and historical presentation are checked, then no deleted or anonymized identity link, participant access, or identifying label is restored.

## Open Questions

- None.
