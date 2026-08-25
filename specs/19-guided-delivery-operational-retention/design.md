# Guided Delivery Operational Retention Design

## Context

The guided-delivery core persists durable workflow state and also creates temporary execution mechanics needed for retry, resume, reconciliation, artifact handling, and short-lived diagnosis. The approved privacy contract gives inactive command payloads, checkpoints, superseded artifacts, expired preview deployments, spent attempt-lease material, the worker-local provider-thread reference, and operational-security logs a 30-day limit. Accepted evidence and active recovery state have different purposes and must survive temporary-data pruning.

The project already has a shared privacy-retention runner and project-storage governance. This child specification extends those mechanisms without redefining authoritative storage or implementing notification, relay, cache, backup, rights, or project-deletion lifecycles.

## Proposed Approach

Define explicit lifecycle selectors for inactive execution mechanics and superseded artifact bytes. Each selector computes eligibility from authoritative state and a purpose-ended timestamp rather than creation time alone. Extend the shared locked retention runner with hosted and device adapter operations that delete eligible records idempotently and record minimized reconciliation outcomes.

Create a fixed structured security-log contract for Slice 07 event categories. The logger accepts only an allowlisted event type, outcome, occurrence time, non-secret correlation reference, and minimized operational classification. It rejects or omits credentials, participant emails, project content, and provider payloads. Apply a separate 30-day log rule through the same retention runner.

## Components Affected

- Shared privacy-retention runner, lock, scheduler, and reconciliation path.
- Hosted and device delivery-store temporary-data operations.
- Command, checkpoint, artifact, preview-deployment, and attempt-lease lifecycle selectors.
- The worker's own run state on the device, which holds the provider-thread reference.
- Authoritative private artifact deletion seam.
- Slice 07 structured operational-security logger and diagnostic scans.

## Data and Access Boundaries

This slice introduces no new product or analytics entity. Temporary execution records remain owned by their existing guided-delivery stores, and security logs remain operational records under the approved security purpose. It does introduce one operational record of its own, so that a rule that fails or is interrupted is discoverable rather than silent:

- `RetentionRuleOutcome`: the durable per-rule result of one retention pass — rule name, outcome, attempt count, last attempt time, and a non-secret correlation reference. It carries no participant, project content, or deleted-record identifier, exists only for the approved operational purpose, and is itself pruned on the same 30-day boundary it enforces.

Required boundaries:

- Eligibility is resolved inside the project's authoritative hosted or device boundary; no hosted copy is created to prune device-authoritative data.
- Active run, attempt, command, checkpoint, and artifact state is read consistently before deletion.
- Accepted evidence records remain immutable even when an associated superseded artifact byte copy expires.
- Retention diagnostics contain rule name, count, result, and non-secret correlation only, not deleted content or identifiers that create a stable profile.
- Security logs are accessible only for the approved operational-security purpose and through the separately approved support boundary.
- Deleted temporary data cannot be restored by reconciliation.

## Interfaces

- Temporary-data selector: identify inactive command payloads and checkpoints whose purpose ended at least 30 days earlier, together with the transient result and failure detail they carry.
- Preview-deployment selector: identify terminal deployments past the same boundary whose remote counterpart is confirmed released, on both the hosted and device authority.
- Attempt-lease clearing: blank spent lease owner, lease expiry, and fence token on a terminal attempt without deleting the attempt.
- Worker run-state pruning: remove the provider-thread reference from the worker's local run state once its run is terminal and past the boundary.
- Artifact-retention interface: delete eligible superseded artifact bytes while preserving immutable evidence provenance and accepted artifacts.
- Retention-runner interface: claim one rule under a lock, prune through the correct authority, persist minimized completion or failure state, and resume safely after restart.
- Security-log interface: accept only approved event types and fixed minimum fields, returning a typed refusal for forbidden content.
- Security-log retention interface: delete Slice 07 operational-security records at the 30-day boundary.

## Decisions and Tradeoffs

### Eligibility Starts When The Purpose Ends

- Choice: Calculate the 30-day period from inactive or superseded state, not record creation.
- Reason: A long-running attempt may legitimately need an old checkpoint, while a newly superseded artifact no longer has an active purpose.
- Consequence: Each temporary record needs an authoritative purpose-ended signal or conservative ineligibility.
- Device qualification: the device value shapes carry no Ecto timestamps, so no device record has a purpose-ended instant. The device rules use the only instant each record does carry — a command's scheduled delivery time and a question's asked time — both of which are at or before the hosted purpose-ended time. The device half therefore never retains a record longer than the hosted half would and can release marginally earlier. Eligibility still requires the record to be terminal or resolved and its run to be finished, so the earlier instant changes only when a spent record goes, never whether something still in use is taken.

### Retention Follows The Records That Exist, Not The Category Names

- Choice: Express every rule against an entity the approved processing inventory already classifies. Transient diagnostic output expires with the command result or `text/plain` artifact that carries it, and the provider-thread reference is pruned where it actually lives, in the worker's local run state.
- Reason: The umbrella wording named "transient logs" and "provider-thread references" as if each were a stored record. Neither is. Creating one so retention has something to delete would add personal-data storage in the name of minimization, and leaving the names unattached would make an approved criterion unprovable.
- Consequence: The privacy commitment is unchanged and every category is enforced, but the hosted, device, and worker-local rules fail independently and are proved separately.

### The Supersession Instant Is The Replacement's Timestamp

- Choice: Measure the artifact window from the replacement evidence row, not the superseded one. Hosted uses the replacement's server-written `inserted_at`; device uses its worker-declared `recorded_at`.
- Reason: An evidence row has no `updated_at` at all — it is declared `updated_at: false` and a database trigger freezes every column except the supersession link and state version, because a proof is not something that gets modified. The replacement is inserted in the same atomic commit as the supersession link, so its timestamp is the supersession instant. Hosted prefers the server-written value because it cannot be backdated by a worker; the device value shapes do not carry `inserted_at`, so the declared time is the only instant that survives there, and on a device the worker is the authority anyway.
- Consequence: The two authorities read different columns for the same meaning, exactly as the temporary-data rules already do. The superseded row's own `recorded_at` is deliberately not used: it always precedes the supersession and would delete bytes before the approved window elapsed.

### Preserve Evidence Provenance When Bytes Expire

- Choice: Delete superseded temporary artifact bytes without rewriting immutable evidence rows.
- Reason: Historical proof must still show what was superseded even when unnecessary private bytes no longer need storage.
- Consequence: Presentation reports an expired artifact as unavailable while retaining its digest and supersession provenance.

### One Locked Retention Runner, Separate Rules

- Choice: Reuse scheduling, locking, restart, and reconciliation while keeping execution, artifact, and security-log selectors independent.
- Reason: Shared operational mechanics avoid competing pruners, while separate selectors keep proof and lifecycle ownership clear.
- Consequence: A failure in one rule is visible and retryable without skipping or weakening another rule.

### Rule-Level Failure State Is Persisted, Not Re-Derived

- Choice: Give the retention runner a durable per-rule outcome record, following the existing participation cleanup-request precedent, rather than returning in-memory counts alone.
- Reason: The current shared pruner reports counts and forgets them, so an interrupted or failing rule is invisible until someone notices data past its limit. Restart discovery and reconciliation cannot be proved against a value that only exists inside one pass.
- Consequence: This slice adds an operational record of its own. It holds rule name, outcome, attempt count, and non-secret correlation only, and is itself subject to the minimization rules applied to retention diagnostics.

### A Preview Record May Only Outlive Its Remote Counterpart, Never The Reverse

- Choice: Release a preview-deployment record only when its cleanup state records a confirmed provider-side release. Anything else — never requested, requested and still awaited, or failed — retains the record at any age. Retention itself never calls a preview provider.
- Reason: A preview has a counterpart at a third-party provider. The record is the only thing that identifies it. Deleting the record while the remote deployment is still live orphans it permanently, and it may keep serving the project's content with nothing left that could ever find it again. That is a worse data-protection outcome than keeping an internal row past its window, so the ordering is one-directional: the remote copy goes first, then the record.
- Consequence: This rule is only as effective as the workflow that triggers the release. No such trigger exists today for a preview that merely expires — the release seam is implemented and tested but is called from nowhere in production — so the rule is correct and currently inert. That gap belongs to the preview lifecycle, not to retention; `specs/21-guided-delivery-deletion-and-recovery` Task 4 already owns the project-deletion path, and the expiry path has no owner yet.

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
- The worker-local rule runs on a device that may be offline for longer than the boundary. Eligibility is re-derived from the run's terminal lifecycle on the next start rather than from a schedule the device may have missed, and an unreachable device pauses only that rule.
- Deleting a preview record that a retained sibling still names would null that link and violate the paired supersession constraint, aborting the whole retention pass rather than one rule. A due record is held back until the record referring to it is due as well.
- Clearing lease fields in place could be mistaken for deleting an attempt. The rule updates named columns and its proof asserts the attempt row and its participant-visible outcome are untouched.

## Open Questions

None.
