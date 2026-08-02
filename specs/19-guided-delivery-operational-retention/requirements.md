# Guided Delivery Operational Retention

## Status

Approved

## Outcome

Inactive guided-delivery execution mechanics and operational-security logs are removed within 30 days while active runs, accepted evidence, authoritative workflow history, and necessary minimized security evidence remain available for their approved purposes.

## Users

- Project participants whose guided-delivery data must not be retained longer than necessary.
- Operators relying on short-lived execution recovery and security diagnostics.
- Privacy and security reviewers verifying storage limitation and log minimization.

## In Scope

- Thirty-day cleanup of inactive command payloads, checkpoints, provider-thread references, transient logs, and superseded artifacts.
- Preservation of active execution state and accepted evidence.
- Idempotent, locked, restart-safe retention enforcement and reconciliation.
- A fixed minimized Slice 07 operational-security log field allowlist.
- Credential, participant-email, and project-content exclusion from security logs.
- Thirty-day expiry of Slice 07 operational-security logs.

## Out of Scope

- Notification retention, device relay and cache retention, backup expiry, and project deletion.
- Feature, specification, activity, review, accepted-evidence, or historical-attribution deletion.
- Product analytics or operational metrics outside the approved security purpose.
- Deployment-specific backup, processor, transfer, or legal evidence.

## Primary Workflow

1. A command payload, checkpoint, provider-thread reference, transient log, artifact, or security-log record reaches an inactive or superseded lifecycle state.
2. Retention classifies whether the record remains necessary for an active run, accepted evidence, or the approved security purpose.
3. The locked pruner deletes eligible temporary execution data and expired security logs at the 30-day boundary.
4. Reconciliation safely repeats interrupted work without removing active state or restoring deleted data.
5. Verification confirms that retained security logs contain only approved minimum fields and no raw credential, participant email, or project content.

## Business Rules

- Temporary command payloads, checkpoints, provider-thread references, transient logs, and superseded artifacts are deleted within 30 days after they are no longer active.
- Active run state, current recovery material still required by the run, accepted evidence, and immutable participant-visible history are not temporary data.
- Superseded artifact deletion removes bytes and unnecessary temporary references without rewriting immutable evidence provenance.
- Retention is idempotent, lock-protected, restart-safe, and reconcilable across the authoritative hosted or device boundary.
- Slice 07 security logs use a fixed field allowlist and a non-secret correlation identifier.
- Security logs cannot contain raw credentials, participant emails, feature or specification content, prompts, outputs, comments, evidence bytes, or provider payloads.
- Slice 07 operational-security logs are deleted within 30 days.
- Retention and logging controls cannot create product analytics or stable participant, project, repository, device, worker, feature, or run profiles.

## Acceptance Criteria

- [AC-01] Given an inactive command payload, checkpoint, provider-thread reference, or transient log reaches 30 days after its active purpose ends, when retention runs, then it is deleted while active execution and current recovery state remain intact.
- [AC-02] Given a superseded artifact reaches 30 days after it is no longer active, when retention runs, then its temporary bytes and unnecessary reference are removed without deleting accepted evidence or rewriting immutable provenance.
- [AC-03] Given operational retention is repeated, interrupted, or restarted across hosted or device authority, when reconciliation runs, then eligible records are deleted once and active or accepted records remain available.
- [AC-04] Given a guided-delivery security event is logged, when the record is inspected, then it contains only the approved structured fields and non-secret correlation identifier with no credential, participant email, or project content.
- [AC-05] Given a Slice 07 operational-security log reaches 30 days, when retention runs, then the log is deleted without changing project authorization, feature state, run state, or accepted evidence.

## Open Questions

None.
