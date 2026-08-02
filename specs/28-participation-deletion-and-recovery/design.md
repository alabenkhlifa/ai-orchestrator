# Participation Deletion And Recovery Design

## Context

Slice 08 already removes primary-store participation identity links through retention and approved rights handling. The shared privacy foundation exposes deployment backup evidence and cleanup handoffs, but the unfinished legacy plan combined backup expiry and downstream propagation with unrelated processing and operational-retention work.

This specification consumes the final primary-store lifecycle and processing contracts. It does not redefine participation authorization, retention necessity, or the authoritative identity records.

## Proposed Approach

Extend the existing deployment privacy profile and rights propagation result with explicit participation deletion and anonymization tombstones. Enforce a maximum 35-day encrypted-backup lifetime and recovery ordering that applies those tombstones before restored participation records become readable.

Send idempotent minimum-field cleanup requests to each configured processor, cache, index, export, and derived-copy adapter. Keep only restricted destination, action, opaque reference, acknowledgement, attempt, and normalized failure state for reconciliation. Authorization and presentation continue to resolve from the primary participation boundary and therefore remain closed while cleanup is pending.

## Components Affected

- `Privacy.DeploymentPrivacyProfile` participation backup contract.
- `Privacy.Rights` deletion and anonymization propagation result.
- Configured processor, cache, index, export, and derived-copy cleanup adapters.
- Restricted cleanup retry and reconciliation worker.
- Participation privacy proof and deployment-evidence validation.

## Data and Access Boundaries

- No new authoritative participation entity is introduced. Cleanup state may retain only an opaque subject reference and minimum destination, action, acknowledgement, attempt, timing, and normalized failure fields.

Required boundaries:

- The provider specifications remain authoritative for participation identity, rights disposition, retention, and purpose classification.
- Backup copies are encrypted, recovery-only, and unavailable to product and ordinary support reads.
- Tombstones are applied before restored participation data can affect authorization, routing, or presentation.
- Non-backup cleanup adapters receive no project content, credential, email, display label, account identifier, or hosted-identity identifier unless that exact destination requires an already-approved opaque subject reference.
- Reconciliation is operations-only, least-privilege, purpose-limited, audited, and excluded from analytics.

## Interfaces

- Backup lifecycle interface: validate encryption, recovery-only access, maximum age, tombstone persistence, and restore ordering.
- Cleanup propagation interface: accept one approved deletion or anonymization action and issue idempotent minimum-field destination requests.
- Reconciliation interface: claim incomplete destinations, preserve acknowledgements, retry normalized failures, and expose no governed content.
- Authorization compatibility interface: prove recovery and retries cannot recreate active participation or identifiable attribution.

## Decisions and Tradeoffs

### Tombstones Before Restored Data

- Choice: Apply participation deletion and anonymization tombstones before restored records can be read or routed.
- Reason: A backup expiry rule alone does not prevent a permitted recovery inside the 35-day window from reviving a removed identity link.
- Consequence: Recovery must pause participation reads until tombstone application and cleanup reconciliation are initialized.

### Minimum Adapter Requests

- Choice: Send opaque, idempotent cleanup references instead of participation content or identity values.
- Reason: A cleanup mechanism must not create another copy of the personal data it removes.
- Consequence: Each configured adapter owns target resolution and returns only an acknowledgement or normalized failure class.

### Access Denial Independent Of Cleanup Completion

- Choice: Keep primary authorization and presentation denial authoritative while downstream cleanup retries.
- Reason: External destinations cannot participate in the primary transaction and must not delay access revocation.
- Consequence: Release can remain blocked by incomplete live evidence even though local implementation and fail-closed behavior are verifiable.

## Risks

- A backup restore could race tombstone application. Enforce tombstone-first recovery and deny participation reads until initialization completes.
- A configured destination may never acknowledge cleanup. Preserve restricted retry state, keep access denied, and surface the release blocker.
- Cleanup metadata could become a new identity index. Allow only opaque references and negative-scan every request and persisted retry record.

## Open Questions

- None.
