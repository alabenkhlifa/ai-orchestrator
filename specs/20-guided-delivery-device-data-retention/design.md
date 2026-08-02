# Guided Delivery Device Data Retention Design

## Context

The project-storage authority requires device-authoritative project data to remain in the worker-owned device store. Guided delivery may still use a hosted outbound-worker relay and transient presentation cache for approved control or display exchanges. The approved Slice 07 contract limits those hosted records to 24 hours and prohibits a durable hosted device-project copy.

This boundary is distinct from ordinary temporary execution retention: it protects storage authority and transfer minimization across a hosted/device trust boundary. It therefore has its own focused child specification and does not redefine the completed delivery-store or worker protocol.

## Proposed Approach

Introduce explicit transient relay and cache classifications for device-authoritative projects. Validate every write against a field allowlist, the project's current storage authority, a named transport purpose, creation and purpose-expiry times, and a bounded active-exchange reference. Refuse any payload containing authoritative project records, raw project content, credentials, evidence bytes, or provider payloads.

Apply separate 24-hour relay and cache selectors through the shared retention runner. Revalidate storage mode and active-exchange state at deletion, reconcile interrupted cleanup idempotently, and keep only minimized failure metadata. Add hosted-store scans that prove no durable device-project feature, specification, run, activity, evidence, artifact, or source-content record exists.

## Components Affected

- Hosted worker relay transient-data boundary.
- Guided-delivery presentation cache for device-authoritative projects.
- Project-storage authority consumer.
- Shared privacy-retention runner and reconciliation path.
- Hosted persistence and analytics negative scans.

## Data and Access Boundaries

This slice introduces no authoritative project-data entity. Relay and cache records are transient transport state whose existence cannot change the device store's authority.

Required boundaries:

- Device-authoritative storage mode is resolved through `capability:project-storage-governance` before any transient hosted write or cleanup.
- Relay and cache records contain only allowlisted control or presentation fields and bounded timing metadata.
- Raw feature or specification text, source context, prompts, outputs, evidence bytes, artifacts, credentials, participant emails, and provider payloads are prohibited.
- Participants cannot use a relay or cache record as a hosted project-content read path.
- Active transport state is bounded to one named exchange and cannot renew data indefinitely.
- Cleanup diagnostics contain rule, outcome, and non-secret correlation only and cannot become analytics.

## Interfaces

- Transient relay-write interface: validate device authority, approved field shape, active transport purpose, creation time, and expiry before accepting one hosted relay record.
- Relay-retention interface: delete ended or 24-hour relay state while permitting only a still-current bounded exchange.
- Transient cache interface: validate and store only minimized presentation state with a hard 24-hour expiry.
- Cache-retention interface: delete expired cache state and reconcile failures without reconstructing content.
- Hosted-copy audit interface: scan authoritative and cache stores for prohibited durable device-project records and stable analytics identifiers.

## Decisions and Tradeoffs

### Treat Relay And Cache As Transient Transport State

- Choice: Give each record a named purpose and hard expiry without any authoritative project-data semantics.
- Reason: A hosted helper should not become a second store merely because it can display or route a device-owned workflow.
- Consequence: A disconnected client may lose stale presentation convenience after expiry and must refresh from the device authority.

### Bound The Active-Transport Allowance

- Choice: Allow a current exchange to retain only the minimum relay state it is actively using, with no indefinite renewal.
- Reason: Deleting a message still in flight can break delivery, but an unbounded active flag would defeat the 24-hour limit.
- Consequence: The exchange identity and deadline must be explicit and revalidated during retention.

### Fail Closed On Payload Shape

- Choice: Reject any relay or cache payload outside a strict allowlist rather than attempting to sanitize arbitrary project content.
- Reason: Sanitization cannot reliably turn source, prompt, output, evidence, or credential payloads into approved transient metadata.
- Consequence: New transport fields require a privacy-inventory and contract update before use.

### Scan For Durable Copies

- Choice: Prove absence across hosted project, delivery, evidence, artifact, cache, and analytics stores.
- Reason: Correct retention of one relay table does not prove another hosted path did not persist the same device content.
- Consequence: Verification owns negative persistence scans in addition to rule-level retention tests.

## Risks

- An active flag could extend retention indefinitely. The allowance is tied to a current exchange and a fixed deadline and is tested after disconnect and restart.
- Cache code could persist content outside the known relay schema. Hosted-copy scans cover all guided-delivery and analytics stores.
- A cleanup failure could expose stale data. Failed records remain inaccessible and minimized while reconciliation retries deletion.
- Device authority could change during cleanup. Storage mode is revalidated and migration remains outside this slice.
- Diagnostics could identify a stable device or workspace. Logs use non-secret per-operation correlation and the approved short retention boundary.

## Open Questions

None.
