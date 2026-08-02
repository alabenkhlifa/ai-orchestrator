# Guided Delivery Deletion And Recovery

## Status

Approved

## Outcome

Deleting a project immediately ends guided-delivery access, removes authoritative hosted and device copies, requests cleanup from configured derived stores and processors, and keeps only restricted retryable reconciliation evidence while encrypted recovery backups expire within 35 days.

## Users

- Project owners deleting a project and expecting its delivery data to become inaccessible immediately.
- Privacy, security, support, and operations personnel responsible for deletion completion and recovery controls.

## In Scope

- Thirty-five-day maximum expiry for encrypted rolling backups used only for disaster recovery.
- Immediate guided-delivery access revocation and authoritative hosted deletion.
- Device-authoritative deletion through the approved worker boundary.
- Cleanup requests for preview, artifact, cache, index, and configured processor copies.
- Restricted, idempotent, restart-safe reconciliation of incomplete cleanup.
- Proof that recovery or retry never restores deleted project access.

## Out of Scope

- Project deletion confirmation UX and ownership rules already owned by project storage governance.
- Selecting backup, preview, artifact, hosting, or processor vendors.
- Legal holds or retention exceptions not already approved in the shared project contract.
- Rights requests for a person when the project remains active.

## Primary Workflow

1. The approved project-deletion event immediately denies guided-delivery reads and commands.
2. Hosted or device-authoritative delivery records are deleted through their owning adapters.
3. The service issues idempotent cleanup requests for configured preview, artifact, cache, index, and processor copies.
4. Failures create only a restricted reconciliation record with no project content.
5. Reconciliation retries until every configured cleanup acknowledges completion, without restoring project access.
6. Recovery backups remain inaccessible to ordinary product and support paths and expire within 35 days.

## Business Rules

- Access denial begins with the authoritative deletion transition and does not wait for asynchronous cleanup.
- Hosted and device-authoritative stores remain separate authorities; this feature coordinates deletion without creating a copy between them.
- Backup data is encrypted, recovery-only, excluded from ordinary support and product access, and expires within 35 days.
- Cleanup requests contain only the stable target reference and minimum deletion metadata required by the configured adapter.
- `ProjectCleanupReconciliation` contains no project content, artifact bytes, prompt, output, credential, or user-facing history.
- Repeated deletion and cleanup acknowledgement are idempotent.
- A failed cleanup remains visible only to authorized operations and cannot make deleted content accessible.
- Recovery from backup must reapply the deletion tombstone before any project read boundary becomes available.

## Acceptance Criteria

- [AC-01] Given an encrypted rolling backup contains guided-delivery data, when its recovery-only lifetime reaches 35 days, then it is expired and cannot be read through product or ordinary support paths.
- [AC-02] Given project deletion commits for a hosted project, when any guided-delivery read or command follows, then access is denied immediately and authoritative hosted delivery records are removed idempotently.
- [AC-03] Given project deletion commits for a device-authoritative project, when the authorized worker processes it, then authoritative device delivery records are removed without creating a hosted copy.
- [AC-04] Given deleted delivery data has preview or artifact copies, when cleanup is issued, then configured adapters receive idempotent deletion requests and any failure creates only a restricted minimized reconciliation record.
- [AC-05] Given deleted delivery data has cache, index, or configured processor copies, when cleanup is issued, then each configured destination receives the minimum idempotent deletion request and no content is copied into reconciliation state.
- [AC-06] Given one cleanup request fails or the service restarts, when reconciliation resumes or a backup is restored, then cleanup retries safely, completed acknowledgements are preserved, project access stays denied, and deleted content is never restored to an active path.

## Open Questions

- None.
