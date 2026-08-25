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

- Thirty-day cleanup of inactive command payloads, checkpoints, superseded artifacts, terminal preview deployments whose remote counterpart is confirmed released, and spent attempt-lease material.
- Thirty-day removal of the worker-local provider-thread reference once a run reaches a terminal lifecycle.
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

- Temporary command payloads, checkpoints, superseded artifacts, expired preview deployments, and spent attempt-lease material are deleted within 30 days after they are no longer active.
- Transient diagnostic output is not a record of its own. It is carried by a command's result and failure code and by `text/plain` evidence artifacts, and it expires with the record that holds it rather than through a separate rule.
- The provider-thread reference is worker-local. It exists only in the worker's own run state on the device, is never stored hosted, and is removed there once its run is terminal and 30 days have passed.
- Clearing spent lease material never deletes the attempt row, because attempt history is participant-visible and belongs to a different lifecycle.
- A preview deployment record is released only once its remote counterpart is confirmed released. A record whose provider-side deployment was never requested, is still awaited, or failed to release is retained regardless of age, because deleting it would orphan a remote deployment that may keep serving the project's content with nothing left to identify it. Retaining a database row is the lesser harm.
- Retention never asks a preview provider to release anything. It reads the confirmed outcome of a release another workflow performed.
- Active run state, current recovery material still required by the run, accepted evidence, and immutable participant-visible history are not temporary data.
- Superseded artifact deletion removes bytes and unnecessary temporary references without rewriting immutable evidence provenance.
- Retention is idempotent, lock-protected, restart-safe, and reconcilable across the authoritative hosted or device boundary.
- Slice 07 security logs use a fixed field allowlist and a non-secret correlation identifier.
- Security logs cannot contain raw credentials, participant emails, feature or specification content, prompts, outputs, comments, evidence bytes, or provider payloads.
- Slice 07 operational-security logs are deleted within 30 days.
- Retention and logging controls cannot create product analytics or stable participant, project, repository, device, worker, feature, or run profiles.

## Acceptance Criteria

- [AC-01] Given an inactive command payload or checkpoint reaches 30 days after its active purpose ends, when hosted retention runs, then it is deleted with the transient result and failure detail it carries, while active execution and current recovery state remain intact.
- [AC-02] Given a superseded artifact reaches 30 days after it is no longer active, when retention runs, then its temporary bytes and unnecessary reference are removed without deleting accepted evidence or rewriting immutable provenance.
- [AC-03] Given operational retention is repeated, interrupted, or restarted across hosted or device authority, when reconciliation runs, then eligible records are deleted once and active or accepted records remain available.
- [AC-04] Given a guided-delivery security event is logged, when the record is inspected, then it contains only the approved structured fields and non-secret correlation identifier with no credential, participant email, or project content.
- [AC-05] Given a Slice 07 operational-security log reaches 30 days, when retention runs, then the log is deleted without changing project authorization, feature state, run state, or accepted evidence.
- [AC-06] Given a device-authoritative project holds an inactive command payload or checkpoint that reaches 30 days, when retention runs against the device authority, then it is removed there without creating any hosted copy of device-authoritative data.
- [AC-07] Given a run reaches a terminal lifecycle and 30 days pass, when the worker prunes its own run state, then the provider-thread reference is removed from the device while the run's participant-visible history is unchanged.
- [AC-08] Given a preview deployment reaches a terminal status and 30 days pass, and its remote counterpart is confirmed released, when retention runs, then its deployment record is removed without deleting the feature, run, or accepted evidence it belonged to; a record whose remote release is unrequested, pending, or failed is retained at any age.
- [AC-09] Given a run attempt is terminal and reaches 30 days, when retention runs, then its lease owner, lease expiry, and fence token are cleared while the attempt row and its participant-visible outcome remain intact.
- [AC-10] Given a device-authoritative project holds a superseded artifact that reaches 30 days, when retention runs against the device authority, then its bytes are removed there without creating any hosted copy and without rewriting the evidence record that names it.
- [AC-11] Given a device-authoritative project holds a terminal preview deployment whose remote counterpart is confirmed released and which reaches 30 days, when retention runs against the device authority, then its record is removed there without creating any hosted copy.

## Open Questions

None.
