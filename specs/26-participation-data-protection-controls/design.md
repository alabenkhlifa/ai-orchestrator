# Participation Data Protection Controls Design

## Context

Slice 08 established invitation, participation, profile, notification, delivery, revocation, retention, and historical-attribution surfaces. Its unfinished Task 23 and AC-13 combined the processing inventory, access matrix, support elevation, processor and transfer rules, redaction, credential-transfer denial, and purpose limitation. Those controls form one focused privacy outcome, but their inventory must classify the final identity and revocation lifecycle rather than preserve the incomplete lifecycle assumptions that exposed the refinement findings.

The existing `SddOrchestrator.Privacy.ProcessingInventory` and `DataProcessingRecord` provide the application-wide configuration model. `capability:project-participation-boundary` supplies immutable-owner and active-participant authorization. `capability:participation-identity-lifecycle` supplies the final re-invitation, departure, revocation-link, attribution-necessity, verified-rights, and anonymization rules. This slice consumes both contracts and does not redefine their authoritative state or lifecycle.

## Proposed Approach

Extend the existing processing inventory with structured participation entries covering invitations, invited-email proof, participation authorization, presentation profiles, revocation handoffs, notifications, email-delivery diagnostics, support and security processing, and derived copies. Validate every entry against one approved purpose and lawful basis, minimum fields, authority, recipients, lifecycle owner, processors, transfers, and review state.

Use the project-participation boundary before any optional presentation or content lookup. Add explicit access policies for the approved owner, participant, and minimized operations views, with account-neutral denial for invitation and identity enumeration. Keep exceptional support separate from project participation: metadata-only by default, with a verified purpose-bound capability for any temporary content access and a content-free audit record.

Apply one participation content boundary before persistence or transmission to reject credentials, secrets, unauthorized project content, out-of-context participant emails, unrelated identities, and unapproved destinations. Enforce purpose limitation through inventory and destination allowlists plus negative store, event, metric, profile, analytics, advertising, training-use, and unrelated-use checks. Any future measurement interface accepts only aggregate genuinely anonymous values produced after unlinkability checks; it never receives raw participation records or stable identifiers.

## Components Affected

- `SddOrchestrator.Privacy.ProcessingInventory` and `DataProcessingRecord` participation classifications.
- Participation owner, participant, operations, and exceptional-support access policies.
- Project-participation authorization and identity-lifecycle capability consumers.
- Participation content minimization, secret rejection, and credential-transfer denial boundary.
- Deployment privacy processor and transfer configuration checks.
- Participation purpose-limitation and genuinely anonymous aggregate negative proof.

## Data and Access Boundaries

- `DataProcessingRecord`: one configuration record for a participation activity or transfer, including its field names, purpose, lawful basis, authority, recipients, access boundary, lifecycle owner, processors, transfer classification, and review state without copying the governed data.

Required boundaries:

- `DataProcessingRecord` contains classification metadata and field names only; it does not contain invited emails, identity values, invitation material, project content, credentials, notification payloads, support content, log values, or processor payloads.
- Immutable ownership or active `ProjectParticipant` state is authoritative before optional profile or presentation lookup. An unavailable profile cannot remove an authorized recipient or cause an email-derived label fallback.
- The identity-lifecycle provider remains authoritative for re-invitation, departure, revocation links, historical attribution, verified rights, deletion, and anonymization. This slice records and validates those lifecycle references only.
- Owner and participant reads remain project-scoped. Operations receives only approved minimized metadata. Support is content-free unless a verified, least-privilege, purpose-bound, expiring capability authorizes a narrower exception.
- A support audit entry records actor, purpose category, scope, issue time, expiry, revocation state, and decision outcome without project content, participant email, credentials, or secret values.
- Processor and transfer configuration names approved categories and minimum fields; deployment-specific vendor, agreement, region, safeguard, and approval evidence stays in the release gate.
- Aggregate measurement cannot contain or be grouped by account, identity, email or digest, project, workspace, invitation, participant, notification, repository, device, network, session, or another stable or singling-out identifier.

## Interfaces

- Processing-inventory interface: register and validate one participation activity's purpose, basis, fields, authority, recipients, lifecycle owner, processor, transfer, and review classification.
- Lifecycle-classification interface: resolve approved retention, revocation, rights, attribution-necessity, deletion, and anonymization ownership from `capability:participation-identity-lifecycle` without creating a competing rule.
- Participation-access interface: consume `capability:project-participation-boundary` and return only the approved owner, participant, or non-disclosing denial result.
- Operations and support interface: return minimized metadata by default and issue, validate, expire, revoke, and audit one verified exceptional-support capability.
- Content-boundary interface: reject credentials and secrets and remove fields outside the authorized recipient, processor, transfer, or presentation context before persistence or transmission.
- Purpose-limitation interface: reject unapproved destinations and prove the absence of advertising, training, unrelated improvement, product analytics, linkable profiles, and other secondary use.
- Aggregate-boundary interface: accept only pre-aggregated genuinely anonymous measures with no raw participation input or stable identifier.

## Decisions and Tradeoffs

### Extend The Shared Processing Inventory

- Choice: Add participation activities to the existing `ProcessingInventory` and reuse `DataProcessingRecord` rather than create a second privacy registry.
- Reason: One machine-checkable inventory avoids inconsistent purpose, basis, processor, transfer, and lifecycle classifications across product slices.
- Consequence: Participation implementation must satisfy the shared record contract and keep deployment-specific evidence outside the development inventory.

### Consume Final Identity Lifecycle Before Classification

- Choice: Block the first task until the participation identity-lifecycle capability is ready.
- Reason: Inventory entries cannot truthfully classify revocation links, departed identity state, historical attribution, or verified-rights handling against an unresolved lifecycle.
- Consequence: Product and technical design are approved, but implementation remains blocked until the provider proof and readiness write-back are complete.

### Keep Support Separate From Participation

- Choice: Do not model support as an owner, participant, or project role.
- Reason: Standing project membership would grant broader and longer-lived access than the exceptional diagnostic purpose requires.
- Consequence: Support is content-free by default and every exception needs separate verification, scope, purpose, expiry, revocation, and minimized audit proof.

### Reject Before The Boundary

- Choice: Apply credential, secret, project-content, identity, recipient, processor, and destination checks before persistence or transmission.
- Reason: Redaction after storage or delivery leaves unauthorized copies and cannot prove no credential transfer occurred.
- Consequence: Rejected operations expose only a non-disclosing error and diagnostic field names, not rejected values.

### No Participation Analytics Input

- Choice: Do not emit participation records or linkable identifiers into an analytics path; define only a future genuinely anonymous aggregate input boundary.
- Reason: Hashed, encrypted, or pseudonymous participation identifiers remain linkable personal data and cannot satisfy the approved anonymous-only rule.
- Consequence: Current proof is negative. Any future measurement proposal requires a separate approved specification and must produce anonymous aggregate output before crossing this boundary.

## Risks

- An incomplete inventory could create false assurance. Completeness tests enumerate all known participation records and transfers and reject an unclassified activity.
- Access checks performed after content lookup could leak existence or content. Authorization and account-neutral denial run before optional presentation or content resolution.
- Support elevation could become standing access. Capabilities have one purpose and scope, a fixed expiry, explicit revocation, and minimized audit evidence.
- A broad processor classification could transfer unnecessary data. Destination rules bind each processor and transfer category to an approved minimum field set.
- Redaction patterns alone could miss typed credentials or nested content. Field allowlists, typed rejection, and negative persistence and transmission scans complement value detection.
- Aggregate output could remain singling-out or linkable. The boundary rejects stable dimensions and raw participation input and treats any uncertain output as governed personal data.

## Open Questions

- None.
