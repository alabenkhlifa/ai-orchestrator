# Guided Delivery Device Data Retention

## Status

Approved

## Outcome

Transient hosted relay and cache data used for a device-authoritative guided-delivery project is removed within 24 hours and never becomes a durable hosted project copy, while an active transport exchange can finish without changing the device as the sole authority.

## Users

- Participants whose projects use device-authoritative storage.
- Operators maintaining the outbound worker relay and transient presentation cache.
- Privacy and security reviewers verifying device locality and storage limitation.

## In Scope

- Explicit allowlists for transient device-project relay and cache records.
- An active-transport allowance that does not create durable hosted authority.
- Twenty-four-hour relay-data deletion.
- Twenty-four-hour cache-data deletion.
- Idempotent restart and cleanup reconciliation.
- Negative scans proving no durable hosted device-project copy remains.

## Out of Scope

- Device-authoritative feature, specification, run, evidence, artifact, or activity deletion.
- Hosted-project retention behavior.
- Temporary command, artifact, security-log, notification, or backup retention owned by other child specifications.
- Worker provisioning, protocol redesign, cross-worker migration, or device-to-hosted storage migration.
- Project deletion and external-processor cleanup.

## Primary Workflow

1. A configured device worker initiates an approved guided-delivery control or presentation exchange with the hosted relay.
2. The hosted boundary accepts only allowlisted transient fields and records their active transport purpose without becoming authoritative.
3. Relay or cache data becomes eligible when the transport no longer needs it and must be removed no later than 24 hours after creation.
4. Cleanup runs idempotently after normal operation, restart, or partial failure.
5. Verification scans hosted stores and confirms that no authoritative or durable device-project copy exists.

## Business Rules

- A device-authoritative project keeps feature, specification, run, command, activity, evidence, artifact, review, and notification-source authority in the worker-owned store.
- The hosted relay accepts only separately approved transient control or presentation fields and cannot persist raw project content, source context, prompts, outputs, evidence bytes, credentials, or provider payloads.
- An active transport allowance may delay deletion only while the named exchange is current and cannot extend beyond the approved bounded transport purpose.
- Hosted relay and cache data for device-authoritative projects is deleted within 24 hours.
- Cleanup is idempotent, restart-safe, and reconcilable without rehydrating deleted content.
- A cleanup failure remains minimized operational state and cannot make hosted data authoritative or participant-accessible.
- Retention diagnostics and scans cannot create a stable device, workspace, repository, project, feature, run, worker, or participant analytics profile.

## Acceptance Criteria

- [AC-01] Given a device-authoritative guided-delivery exchange, when the hosted relay or cache accepts data, then only approved transient fields are stored for the named active transport purpose and no authoritative project-content copy is created.
- [AC-02] Given hosted relay data for a device-authoritative project reaches 24 hours or its active transport purpose ends, when retention runs, then the data is deleted while a still-current bounded exchange remains usable only for its approved duration.
- [AC-03] Given hosted cache data for a device-authoritative project reaches 24 hours, when retention runs, then the cache is deleted and hosted persistence contains no durable feature, specification, run, activity, evidence, artifact, or source-content copy.
- [AC-04] Given relay or cache cleanup is repeated, interrupted, or restarted, when reconciliation runs, then deletion completes idempotently, failures remain minimized and inaccessible, and deleted device-project content is not restored.

## Open Questions

None.
