# Participation Operational Retention Design

## Context

Slice 08 already provides participation email-delivery diagnostics, a shared account-level notification store, and a supervised hourly `Privacy.Retention` workflow guarded by a PostgreSQL advisory lock. Its identity-lifecycle continuation owns invitation cleanup and every direct participant or revocation identity-link release. The remaining operational records have separate purposes and deadlines but extend the same `Privacy.Retention.prune_all/1` and `Privacy.RetentionPruner` execution surface.

This child specification isolates those remaining retention rules so implementation can be serialized around the shared runner. It consumes `capability:participation-identity-lifecycle` before adding another rule, preserving one authority for the revocation handoff lifecycle and avoiding a second selector for `ParticipationRevocation.former_hosted_identity_id`.

## Proposed Approach

Extend `Privacy.Retention.prune_all/1` in three serialized increments. First add a named selector for finalized `ParticipationEmailDelivery` records at 30 days. Then add a namespace-scoped selector for participation `AccountNotification` records at 90 days. Finally introduce a fixed participation security-event interface backed by a retention-capable sink, add its 30-day prune operation to the same runner, and reconcile all participation retention categories through the existing scheduler and advisory lock.

Each selector calculates eligibility from its authoritative lifecycle time, rechecks the record state in the delete operation, returns only a category count or fixed failure category, and remains safe on repeat execution. The shared runner invokes the already-delivered identity-lifecycle rule but this specification does not implement or alter that provider-owned selector.

## Components Affected

- `SddOrchestrator.Privacy.Retention.prune_all/1` category registration and results.
- `SddOrchestrator.Privacy.RetentionPruner` scheduling, advisory lock, restart, and reconciliation behavior.
- `SddOrchestrator.Participation.ParticipationEmailDelivery` lifecycle selection.
- Participation-namespace records in `SddOrchestrator.Notifications.AccountNotification`.
- Participation structured security logger and retention-capable log adapter.
- Deployment privacy profile and release evidence for the configured security-log sink.

## Data and Access Boundaries

This specification introduces no product or analytics entity. It applies lifecycle operations to existing provider-owned delivery and notification records and to fixed operational-security events under the approved security purpose.

Required boundaries:

- Delivery cleanup reads only delivery status and authoritative attempt or completion timestamps needed for eligibility; it does not inspect stored recipient addresses or reconstruct message content.
- Notification cleanup reads event namespace, occurrence time, and read state only as needed for selection and proof; it does not follow the safe link or inspect project content.
- The participation namespace is selected explicitly so shared `delivery.*` and future non-participation notification records remain outside this rule.
- Security events have a closed schema and never accept arbitrary metadata, operation results, exception text, payloads, identifiers, or user-provided strings.
- The correlation identifier is fresh and non-secret, is not derived from an account, identity, email, project, repository, invitation, participant, notification, device, or network value, and expires with the event.
- Retention diagnostics expose only rule name, count, fixed result category, and occurrence time; they cannot create a stable person, project, repository, or recipient profile.
- Cleanup cannot cascade into invitations, participants, profiles, revocations, accounts, projects, or authorization state.
- Direct identity-link erasure and acknowledgement-sensitive revocation cleanup remain exclusively owned by `specs/25-participation-identity-lifecycle/`.

## Interfaces

- Email-delivery retention interface: select finalized participation delivery diagnostics at the 30-day boundary and delete only those diagnostic rows.
- Account-notification retention interface: select read and unread `participation.*` events at the 90-day boundary and leave every other namespace unchanged.
- Participation security-log interface: accept only approved event types and fixed minimum fields, emit through a retention-capable sink, and return the original operation result without inspecting it for log content.
- Security-log retention interface: delete eligible participation security events at the 30-day boundary and return a minimized category result.
- Shared runner interface: execute all registered rules under one advisory lock, expose per-category counts or fixed outcomes, and allow an overdue record to be discovered again after interruption or restart.
- Identity-lifecycle compatibility interface: confirm the provider-owned invitation and direct-link rules remain registered without copying their selectors or changing their results.

## Decisions and Tradeoffs

### One Shared Runner With Serialized Rule Ownership

- Choice: Implement the three operational-retention tasks in dependency order against the existing `Privacy.Retention.prune_all/1` and scheduler.
- Reason: Parallel edits would compete for the same rule registry, result map, lock, restart behavior, and reconciliation tests.
- Consequence: Tasks 1 through 3 cannot be developed concurrently, but each task leaves one complete independently provable rule before the next extension.

### Lifecycle Time Instead Of Record Age Alone

- Choice: Measure delivery cleanup from the last authoritative attempt or completion and notification cleanup from the event occurrence time.
- Reason: Creation time can precede the operational event whose short diagnostic or notification purpose establishes the retention window.
- Consequence: Missing or invalid lifecycle timestamps fail closed as ineligible and surface through minimized reconciliation rather than causing speculative deletion.

### Namespace-Scoped Shared Notification Cleanup

- Choice: Delete only approved `participation.*` account-notification events rather than applying the 90-day rule to the whole shared store.
- Reason: Slice 07 and later features share `AccountNotification` but may have different lifecycle contracts.
- Consequence: Each future namespace must supply its own retention rule and cannot inherit this deadline accidentally.

### Retention-Capable Structured Security Sink

- Choice: Emit participation security events through a closed application interface whose configured sink also exposes deletion before a cutoff to the shared runner.
- Reason: A documented 30-day policy without a callable deletion boundary cannot provide deterministic local lifecycle proof.
- Consequence: Development and tests use a deterministic retention-capable adapter; production sink configuration and live enforced expiry remain release-gate evidence.

### Identity Lifecycle Remains Provider-Owned

- Choice: Require the completed identity-lifecycle capability before extending the shared runner and treat its direct-link rules as immutable provider input.
- Reason: Reimplementing acknowledgement or 30-day revocation cleanup here would create two authorities over the same identity link.
- Consequence: This slice may detect a missing provider rule during reconciliation but routes repair back to the provider rather than changing the selector.

## Risks

- A broad notification query could delete guided-delivery events. Filter by the approved participation namespace and prove negative namespace cases.
- Deleting a delivery diagnostic could cascade into authoritative state. Keep diagnostic references non-owning and assert unchanged invitation, participant, profile, revocation, and account rows.
- Free-form security logging could retain personal data or project content. Use a closed event struct, coarse outcomes, generated correlation, and negative scans of every emitted field.
- A stopped or contended pruner could extend retention. Prove lock behavior, supervised restart, overdue re-discovery, repeat safety, and category reconciliation.
- Another task could duplicate the revocation identity-link rule. Require provider readiness first and add compatibility tests that reject duplicate registration or changed ownership.

## Open Questions

None.
