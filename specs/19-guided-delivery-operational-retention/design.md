# Guided Delivery Operational Retention Design

## Context

The guided-delivery core persists durable workflow state and also creates temporary execution mechanics needed for retry, resume, reconciliation, artifact handling, and short-lived diagnosis. The approved privacy contract gives inactive command payloads, checkpoints, provider-thread references, transient logs, superseded artifacts, and operational-security logs a 30-day limit. Accepted evidence and active recovery state have different purposes and must survive temporary-data pruning.

The project already has a shared privacy-retention runner and project-storage governance. This child specification extends those mechanisms without redefining authoritative storage or implementing notification, relay, cache, backup, rights, or project-deletion lifecycles.

## Proposed Approach

Define explicit lifecycle selectors for inactive execution mechanics and superseded artifact bytes. Each selector computes eligibility from authoritative state and a purpose-ended timestamp rather than creation time alone. Extend the shared locked retention runner with hosted and device adapter operations that delete eligible records idempotently and record minimized reconciliation outcomes.

Create a fixed structured security-log contract for Slice 07 event categories. The logger accepts only an allowlisted event type, outcome, occurrence time, non-secret correlation reference, and minimized operational classification. It rejects or omits credentials, participant emails, project content, and provider payloads. Apply a separate 30-day log rule through the same retention runner.

## Components Affected

- Shared privacy-retention runner, lock, scheduler, and reconciliation path.
- Hosted and device delivery-store temporary-data operations.
- Command, checkpoint, provider-thread, transient-log, and artifact lifecycle selectors.
- Authoritative private artifact deletion seam.
- Slice 07 structured operational-security logger and diagnostic scans.

## Data and Access Boundaries

This slice introduces no new product or analytics entity. Temporary execution records remain owned by their existing guided-delivery stores, and security logs remain operational records under the approved security purpose.

Required boundaries:

- Eligibility is resolved inside the project's authoritative hosted or device boundary; no hosted copy is created to prune device-authoritative data.
- Active run, attempt, command, checkpoint, and artifact state is read consistently before deletion.
- Accepted evidence records remain immutable even when an associated superseded artifact byte copy expires.
- Retention diagnostics contain rule name, count, result, and non-secret correlation only, not deleted content or identifiers that create a stable profile.
- Security logs are accessible only for the approved operational-security purpose and through the separately approved support boundary.
- Deleted temporary data cannot be restored by reconciliation.

## Interfaces

- Temporary-data selector: identify inactive command payloads, checkpoints, provider-thread references, and transient logs whose purpose ended at least 30 days earlier.
- Artifact-retention interface: delete eligible superseded artifact bytes while preserving immutable evidence provenance and accepted artifacts.
- Retention-runner interface: claim one rule under a lock, prune through the correct authority, persist minimized completion or failure state, and resume safely after restart.
- Security-log interface: accept only approved event types and fixed minimum fields, returning a typed refusal for forbidden content.
- Security-log retention interface: delete Slice 07 operational-security records at the 30-day boundary.

## Decisions and Tradeoffs

### Eligibility Starts When The Purpose Ends

- Choice: Calculate the 30-day period from inactive or superseded state, not record creation.
- Reason: A long-running attempt may legitimately need an old checkpoint, while a newly superseded artifact no longer has an active purpose.
- Consequence: Each temporary record needs an authoritative purpose-ended signal or conservative ineligibility.

### Preserve Evidence Provenance When Bytes Expire

- Choice: Delete superseded temporary artifact bytes without rewriting immutable evidence rows.
- Reason: Historical proof must still show what was superseded even when unnecessary private bytes no longer need storage.
- Consequence: Presentation reports an expired artifact as unavailable while retaining its digest and supersession provenance.

### One Locked Retention Runner, Separate Rules

- Choice: Reuse scheduling, locking, restart, and reconciliation while keeping execution, artifact, and security-log selectors independent.
- Reason: Shared operational mechanics avoid competing pruners, while separate selectors keep proof and lifecycle ownership clear.
- Consequence: A failure in one rule is visible and retryable without skipping or weakening another rule.

### Structured Security Logs Only

- Choice: Log fixed typed outcomes rather than free-form provider or project text.
- Reason: Free-form diagnostics can preserve credentials and content beyond their approved purpose.
- Consequence: Some debugging detail is unavailable after normalization, and deeper content access requires separately authorized support handling.

## Risks

- A stale lifecycle read could delete active recovery state. Selection and deletion revalidate authoritative state under the retention operation.
- Hosted and device adapters could disagree about eligibility. Shared contract tests run the same fixtures against both authorities.
- Artifact cleanup could erase accepted proof. The selector excludes accepted current evidence and tests immutable provenance separately from bytes.
- Failure logs could include the content being deleted. Diagnostics use fixed rule and error categories and scan emitted fields.
- A stopped pruner could extend retention indefinitely. Restart and reconciliation proof makes overdue eligible records discoverable and retryable.

## Open Questions

None.
