# Guided Delivery Rights And Anonymization Design

## Context

Guided delivery distributes personal data and project content across authoritative hosted or device records, notifications, evidence artifacts, transient operations data, backups, exports, and configured processors. Project participation owns stable identity and revocation, project specification storage owns immutable revisions, and the deletion continuation owns fail-closed cleanup. This specification composes those providers into one verified rights workflow without taking ownership of their records.

## Proposed Approach

Extend the existing verified privacy-operator workflow with a guided-delivery adapter registry. Each adapter can discover the requester's linkable records under project authorization, export minimized values, apply its supported correction or restriction action, and request erasure through the owning deletion boundary. Normalize results by source, action, limitation, and completion state without centralizing raw copies.

Evaluate historical attribution separately from current authorization. Retain stable contribution identity only while a recorded accountability necessity remains current. When it does not, remove account and identifying presentation links and replace them with a neutral former-participant presentation while preserving immutable contribution references.

## Components Affected

- Verified privacy-operator request workflow.
- Guided-delivery rights adapter registry.
- Hosted and device-authoritative delivery adapters.
- Notification, artifact, cache, log, backup, export, and configured processor adapters.
- Participation revocation and project deletion consumers.
- Historical-attribution necessity and anonymization workflow.

## Data and Access Boundaries

No new stored entity is introduced. Rights requests and operator verification remain owned by the existing project-wide privacy workflow; this slice adds guided-delivery adapters and normalized result values.

Required boundaries:

- Stable hosted identity and verified operator scope are authorization inputs; display names and emails are not authorization keys.
- Every adapter remains authoritative for its own records and returns minimized results rather than raw bulk copies to a central store.
- Device-authoritative reads and mutations run through the authorized worker and create no durable hosted copy.
- Export output is encrypted in transit and at rest, short-lived, recipient-bound, and deleted on its approved schedule.
- Immutable evidence, activity, revision, and review chronology cannot be rewritten to make a correction appear retroactive.
- Erasure reuses project-deletion cleanup and reconciliation controls where applicable and never restores access.
- Historical anonymization removes every linkable account or presentation identifier; a stable internal contribution record may remain only when it is not linkable to the person.

## Interfaces

- Rights authorization interface: verify operator, requester identity, project scope, requested action, and current or former relationship without existence disclosure.
- Rights adapter interface: discover, export, correct, restrict, object, erase, and report normalized minimum results for one owned data surface.
- Device rights interface: issue bounded rights commands to the authorized worker and return only the requested protected result.
- Erasure interface: invoke configured deletion adapters and restricted reconciliation without duplicating cleanup state.
- Historical-attribution interface: record the current necessity decision, remove account and presentation links when unnecessary, and preserve neutral stable contribution references.

## Decisions and Tradeoffs

### Federated Adapters Instead Of A Rights Data Warehouse

- Choice: Execute rights operations through owning adapters and assemble only a request-bound result.
- Reason: A central rights copy would become another sensitive store with its own retention and authorization risks.
- Consequence: Completion depends on normalized acknowledgements from each configured surface and processor.

### Correction Without Rewriting History

- Choice: Correct mutable identity and processing state while preserving immutable evidence and event chronology.
- Reason: Historical proof must remain trustworthy and correction must not fabricate past state.
- Consequence: Exports and presentation show the correction and its effective time beside immutable prior attribution when retention remains necessary.

### Necessity-Gated Historical Anonymization

- Choice: Keep identifiable historical attribution only while a documented project-accountability necessity remains current.
- Reason: Permanent attribution is not justified by convenience, while immediate history deletion can destroy required accountability.
- Consequence: The workflow periodically or eventfully re-evaluates necessity and performs stable neutral anonymization when identification is no longer required.

## Risks

- An adapter may omit a derived copy. Maintain an explicit inventory and fail the request completion state until every applicable adapter reports.
- Export may expose another participant. Enforce requester and project filters inside every adapter and run cross-participant negative proof.
- Anonymization may remain linkable. Scan account, email, hash, encrypted identifier, stable pseudonym, indexes, caches, and exports before completion.

## Open Questions

- None.
