# Guided Delivery Data Protection Controls Design

## Context

The Slice 07 core implements feature, specification, run, attempt, command, activity, comment, evidence, preview, review, and notification surfaces across hosted and device authorities. Its approved privacy agreement defines contract-necessity service processing, a narrow operational-security purpose, current-participant access, exceptional support elevation, strict redaction, and no product analytics or secondary use. The unfinished umbrella Tasks 38 and 41 combine several independently provable controls; this child specification assigns each invariant a focused owner.

## Proposed Approach

Extend the existing processing inventory with a structured `DataProcessingRecord` for every Slice 07 field and transfer. Validate that each record names one approved service or security purpose, basis, authoritative destination, minimum field set, recipients, and lifecycle owner.

Apply the completed participant guard to all content reads and state-changing actions and add a separate exceptional-support capability that defaults to metadata-only access. Centralize boundary redaction and raw-provider-event rejection so free text, worker events, notifications, logs, and provider requests follow one minimum-content contract.

Prohibit product analytics and secondary use by configuration and code structure, then prove the absence through static store and event scans plus focused browser-network, worker, provider, preview, and device-persistence checks. Treat operational telemetry as governed data with a later retention owner rather than as analytics.

## Components Affected

- Existing data-processing inventory and privacy configuration.
- Guided-delivery current-participant guard consumers.
- Exceptional support-access capability and audit record.
- Shared credential and project-content redaction boundary.
- Worker normalized-event and raw-provider-event rejection.
- Browser-network, provider-routing, telemetry, analytics, and hosted-copy negative checks.

## Data and Access Boundaries

- `DataProcessingRecord`: one governed inventory entry for a Slice 07 field or transfer, including purpose, basis, authority, recipients, minimum fields, access boundary, lifecycle owner, processor category, and transfer classification without copying the governed content itself.

Required boundaries:

- `DataProcessingRecord` is privacy configuration and contains classifications and field names, not feature text, source content, prompts, outputs, evidence bytes, credentials, participant emails, or provider payloads.
- Project content remains available only through current project authorization and the project's selected hosted or device authority.
- Exceptional support access is separate from participant authorization, disabled by default, scoped to one incident purpose and duration, and auditable without copying content into the audit record.
- Device-authoritative records remain local except for already approved transient control or presentation exchange.
- Raw provider events are transient input to normalization and are never a durable project or analytics record.
- Negative analytics proof cannot itself emit stable project, account, device, feature, run, repository, worker, or provider identifiers.

## Interfaces

- Processing-inventory interface: register and validate one field-purpose, basis, authority, recipient, processor, transfer, and lifecycle classification.
- Project-access interface: consume the completed current-participant boundary and return one non-disclosing denial for stale, removed, absent, and cross-project callers.
- Support-elevation interface: issue, validate, expire, revoke, and audit one purpose-bound least-privilege capability without storing project content in the audit record.
- Redaction interface: reject or remove credential material, participant emails, raw provider events, and fields outside the approved boundary before persistence or participant presentation.
- Purpose-limitation interface: fail configuration or tests when a Slice 07 analytics store, request, event, identifier, metric, training-use path, or unrelated processing destination exists.
- Negative-routing interface: inspect representative browser, worker, model, preview, telemetry, and persistence paths without contacting a live provider.

## Decisions and Tradeoffs

### One Inventory Entry Per Field Or Transfer

- Choice: Record structured classifications rather than one prose inventory for the whole slice.
- Reason: A field-level contract can be validated mechanically and updated when one surface changes without hiding unclassified processing.
- Consequence: Every later data surface must add its inventory entry before implementation proof can pass.

### Content-Free Support By Default

- Choice: Separate exceptional support elevation from ordinary operational metadata access.
- Reason: Most diagnosis does not require project content, and broad standing access would violate least privilege.
- Consequence: Content access requires a verified purpose, scope, expiry, and audit event and cannot be granted through a participant role.

### Reject Raw Provider Events

- Choice: Normalize allowed fields before durable handling and reject raw provider payload persistence.
- Reason: Provider streams are unstable, oversized, and likely to contain secrets or unnecessary content.
- Consequence: Diagnostics use minimized typed outcomes and cannot replay arbitrary provider payloads from the database.

### Prove Absence At Multiple Boundaries

- Choice: Combine static negative scans with focused browser, worker, provider, and persistence observations.
- Reason: A missing analytics module does not prove the browser or adapter sends nothing, while network observation alone does not prove no dormant store exists.
- Consequence: Purpose-limitation proof has separate backend and integration tasks while the full browser matrix remains a slice gate.

## Risks

- An incomplete inventory could create false assurance. Validation rejects any known Slice 07 data surface without one classification and lifecycle owner.
- Redaction after persistence could leave secret-bearing copies. Boundary tests assert rejection or minimization before storage and transmission.
- Support access could become a hidden participant role. The elevation capability is purpose- and time-bound and cannot alter project authorization.
- Negative analytics proof could miss dynamically constructed requests. Focused browser traffic and provider-adapter doubles complement static scans.
- Operational metrics could be relabeled as anonymous analytics. Stable or linkable identifiers remain prohibited and telemetry stays under governed retention.

## Open Questions

None.
