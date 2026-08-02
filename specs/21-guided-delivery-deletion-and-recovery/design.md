# Guided Delivery Deletion And Recovery Design

## Context

Slice 07 already stores guided-delivery state through hosted and device-authoritative adapters and can create derived preview, artifact, relay, cache, index, log, notification, and processor copies. Project storage governance owns the authoritative project deletion transition. This specification owns the guided-delivery response to that transition and the proof that asynchronous cleanup cannot restore access.

## Proposed Approach

Consume the project-storage deletion event after access has been revoked. Delete authoritative guided-delivery records through the selected storage adapter, then issue idempotent cleanup commands to each configured derived-copy adapter. Store only minimum destination, request, state, attempt, acknowledgement, and error-class metadata in a restricted `ProjectCleanupReconciliation` record. Reconcile on restart and after recovery while treating the deletion tombstone as authoritative.

Keep encrypted rolling backups outside ordinary product and support access and expire them within 35 days. Recovery must load deletion tombstones before any project access path and resume outstanding cleanup rather than reviving deleted projects.

## Components Affected

- Hosted and device-authoritative guided-delivery deletion adapters.
- Project deletion-event consumer.
- Preview and artifact cleanup adapters.
- Relay, cache, index, and configured processor cleanup adapters.
- Encrypted-backup expiry and recovery sequencing.
- Restricted cleanup reconciliation worker and operations projection.

## Data and Access Boundaries

- `ProjectCleanupReconciliation`: one restricted project-deletion cleanup state containing destination type, opaque destination reference, idempotency key, request and acknowledgement times, retry state, minimum error class, and deletion-tombstone reference without project content.

Required boundaries:

- Project storage governance remains the deletion authority; this specification cannot undelete a project or delay access revocation.
- Hosted deletion touches hosted authoritative records. Device deletion is performed by the authorized device worker and creates no hosted project-data copy.
- Derived-copy adapters accept only minimum opaque references and deletion metadata.
- Reconciliation is operations-only, least-privilege, purpose-limited, audited, and excluded from product analytics.
- Backups are encrypted, recovery-only, and expire within 35 days.
- Restored state loads deletion tombstones and denied authorization before project records or cleanup work can become readable.

## Interfaces

- Project-deletion consumer: receive the stable project and deletion event identity idempotently after authoritative access revocation.
- Authoritative deletion interface: remove guided-delivery records through equivalent hosted and device adapters and report minimum completion state.
- Derived-copy cleanup interface: request and acknowledge idempotent cleanup for preview, artifact, relay, cache, index, and configured processor references.
- Reconciliation interface: claim incomplete destinations, retry under a lock, preserve acknowledgements, and expose only minimum operational state.
- Recovery interface: apply deletion tombstones first, resume cleanup, and deny any path that would restore deleted project access.

## Decisions and Tradeoffs

### Access Denial Before Cleanup Completion

- Choice: Treat the project deletion transition as immediate authorization denial while cleanup proceeds asynchronously.
- Reason: External and derived stores cannot share one transaction with both authoritative storage modes.
- Consequence: Cleanup may remain operationally incomplete, but deleted project content is never exposed while retries continue.

### Restricted Reconciliation Instead Of Content Copies

- Choice: Store only opaque destination and retry metadata in `ProjectCleanupReconciliation`.
- Reason: Copying content into a cleanup queue would create another retained project-data store during deletion.
- Consequence: Adapters must resolve their own target references and return normalized minimum error classes.

### Recovery-First Tombstones

- Choice: Restore deletion tombstones and authorization denial before recoverable project data.
- Reason: A backup restore must not resurrect a project during the interval before cleanup catches up.
- Consequence: Recovery tooling must preserve deletion and acknowledgement state across the full 35-day backup window.

## Risks

- A configured processor may not acknowledge deletion. Keep access denied, retain only restricted retry state, and surface the release blocker.
- A device worker may be offline. Preserve the pending deletion instruction without hosting device content and reconcile when the authorized worker returns.
- Backup restore ordering may expose deleted records. Prove tombstone-first recovery and keep product routes closed until it completes.

## Open Questions

- None.
