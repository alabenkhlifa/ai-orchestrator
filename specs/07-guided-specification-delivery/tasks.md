# Guided Specification And Delivery Tasks

## Status

Blocked

## Active Slice

Deliver one project feature across the `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done` board columns through explicit start, one branch-isolated configured coding-agent run, durable blocking-question resume, bounded retry and cancellation recovery, mandatory verification evidence, an automatic pre-authorized preview when configured, authorized approval or same-run feedback continuation, and in-product action and outcome notifications. Show `Blocked` and `Failed` as statuses without moving the feature to another column.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 1`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 6`.
- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:project-participation-governance` — provider `specs/08-project-participation#Task 5` — required before `Task 6`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 4` — required before `Task 1`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 6`.

Provides:

- `capability:guided-specification-delivery` — ready after `Task 6`.

## Implementation Boundary

Included:

- One project-scoped feature board with the five approved lifecycle columns, gated action-driven transitions, separate visible `Blocked` and `Failed` statuses, and a feature detail workflow.
- Guided requirement structure with visible blocking findings, non-blocking suggestions, and suggestion dismissal.
- Explicit start for one approved specification revision.
- One configured coding-agent and worker boundary without provider-selection UX.
- One isolated feature branch and resumable run.
- Feature creator, project-wide participant assignment, `Assign to me`, assignee-or-creator blocking-question routing, accepted-answer write-back, progress, comments, and typed evidence.
- Same-run automatic and manual retry, terminal failure presentation, explicit cancellation recovery into current readiness, and new-run restart after cancellation.
- Read-only consumption and enforcement of the separately specified current project-participant authorization boundary.
- Configured required-check results, exact branch and verified-revision identity, and supported screenshot capture.
- Automatic use of one preconfigured and authorized branch-preview path after successful verification, without making preview success a review-readiness gate.
- `Ready for review` handoff, authorized approval to `Done`, and feedback-based rejection to `In development`.
- In-product action-required and completion notifications.
- Privacy, access, retention, redaction, and audit controls for the slice.

Excluded:

- Multiple concurrent agents on one feature.
- Worker installation, provisioning, or provider setup UX.
- External notification channels.
- Automatic merge, default-branch writes, production deployment, or release management.
- General-purpose issue tracking and broad collaboration administration.
- Project-participant provisioning, invitations, membership changes, roles, access removal, and their management UI.

Deferred after this slice:

- Multiple agent and model providers.
- Worker pools, scheduling policies, and cross-worker migration.
- Custom board workflows and organization-wide views.
- Email, chat, mobile, or webhook notifications.
- Merge, release, production deployment, rollback, and preview cleanup policies beyond the first configured path.
- Deferred criteria: none.
- Deferred entities: none.

Prerequisite:

- The shared project-storage specification must deliver its authoritative hosted and device adapter boundary before Task 1 and its governance capability before Task 6.
- The focused project-participation specification must deliver current participant identity and authorization, the shared account-level notification foundation, and the versioned `ParticipationRevocation` claim and acknowledgement contract through `capability:project-participation-boundary`, with its governance capability required before Task 6.
- The focused project-specification storage specification must deliver stable specification identity, immutable complete revisions, current snapshots, and hosted and device-authoritative persistence through `capability:project-specification-store`.
- The three operational provider tasks must be complete before Task 1 confirms their consumer contracts and active implementation begins; the three governance capabilities must be complete before Task 6.

## Tasks

- [ ] Task 1 - Approve the feature-delivery product, technical, privacy, and verification contracts.
  - Status: Blocked by the three operational cross-specification capability prerequisites.
  - Purpose: Confirm the approved feature-delivery contracts against the delivered storage-authority, current-participant, and shared specification-store boundaries before implementation begins.
  - Owned surfaces: Active-slice outcome and scope, external project-participation and project-specification capability prerequisites, current-authorization consumer, shared account-level notification extension, versioned `ParticipationRevocation` claim and acknowledgement contract, stable specification and revision consumer contract, participant action and notification rules, lifecycle and state agreement, orchestration and worker contracts, specification write-back and resume contract, evidence and preview contracts, in-product notification contract, privacy data contract, release gate, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Depends on: none
  - Proof: Requirements, design, data contracts, task ownership, task sequence, acceptance-criterion and entity traceability, and canonical verification commands have no unresolved active-slice blockers.

- [ ] Task 2 - Deliver the feature board, guided specification, and readiness workflow.
  - Status: Blocked by Task 1.
  - Purpose: Make the board and start boundary durable and understandable before agent execution exists.
  - Owned surfaces: `Feature`, `ReadinessAssessment`, shared `ProjectSpecification` and `SpecificationRevision` capability consumer, read-only current-participant authorization and project-display-name consumer, participant-email non-disclosure, project-scoped board and feature-detail LiveViews, five fixed lifecycle columns, creator and optional assignment controls, `Assign to me`, responsible-participant resolution, guided requirement structure, blocking and non-blocking finding presentation, non-blocking dismissal, readiness evaluation, gated pre-development lifecycle actions, configured execution-location, agent or model provider, preview-provider and data-transfer summary, disclosure-version comparison, first-start and changed-boundary confirmation, start availability for every current authorized participant, generic status presentation extended by later run tasks, stale and unauthorized participant denial, and supporting domain, persistence, fixtures, and responsive accessibility behavior without a second specification store.
  - Owns: AC-01, AC-03, AC-04, AC-07, AC-08, AC-09, AC-10, AC-11, AC-12, AC-13, AC-14, AC-29, AC-31, AC-36, entity:Feature, entity:ReadinessAssessment
  - Depends on: Task 1
  - Proof: Domain, permission, privacy, and browser tests cover the five lifecycle columns, rejection of free drag-and-drop transitions, gated authorized movement, feature creation with creator and optional assignment, assignment by any current authorized project participant to any other current authorized participant, project-display-name presentation, participant-email non-disclosure, `Assign to me`, stale and unauthorized assignment, action, notification, review, and content-access denial, guided missing information, blocking and non-blocking classification, rejection of blocker dismissal, authorized suggestion dismissal, unavailable start while blocked, readiness changes, execution and provider boundary disclosure, initial confirmation, unchanged-boundary reuse, changed-boundary reconfirmation, revision binding, explicit start authorization, and duplicate-start rejection without any participation mutation.

- [ ] Task 3 - Deliver one branch-isolated agent run with durable progress and blocking-question resume.
  - Status: Blocked by Task 1.
  - Purpose: Execute the approved slice while preserving completed work and routing product decisions back into the specification.
  - Owned surfaces: `AgentRun`, `RunAttempt`, `RunCommand`, `BlockingQuestion`, `ActivityEntry`, hosted and device delivery-store adapters, authoritative transactional state, ordered activity and command outbox, hosted dispatcher claiming, device serialized claiming, expected-state versions, stable command IDs, at-least-once delivery, ordered attempts, one-current-attempt lease and fence, monotonic event sequences, start by any current authorized participant, cancellation by the current run initiator or project owner, cancellation terminality and readiness reevaluation, new-run and new-branch restart after cancellation, one configured worker dispatch, versioned outbound Phoenix Channel worker gateway, worker authentication and capability negotiation, immutable execution manifest and digest, isolated workspace and branch creation, normalized path and working-directory enforcement, immutable starting and effective revision binding, accepted-answer revision transaction, provider-thread-independent continuation checkpoint, normalized run lifecycle and progress events, visible blocked and failed statuses and reasons, assigned-participant or creator question routing, versioned `ParticipationRevocation` claim, idempotent consumer transaction and acknowledgement, assignment clearing, owner question and review responsibility fallback, last-project-display-name non-interactive historical attribution, owner control of continuing active runs, former-participant denial, responder authorization, accepted-answer write-back, generic continuation contract for question answer and later review rejection, explicit retry classification, three-retry jittered exponential backoff, same-worker and same-workspace retry, terminal-failure recording and notification trigger, any-current-participant manual retry, duplicate dispatch, retry, and resume prevention, worker disconnect and restart reconciliation, agent adapter and protocol-version seam, worker-side secret resolution and environment minimization, fixtures, and status UI.
  - Owns: AC-02, AC-05, AC-06, AC-15, AC-17, AC-18, AC-30, AC-32, AC-33, AC-34, entity:AgentRun, entity:RunAttempt, entity:RunCommand, entity:BlockingQuestion, entity:ActivityEntry
  - Depends on: Task 2
  - Proof: Store-contract, transaction, constraint, concurrency, dispatcher, protocol, worker-double, agent-adapter, integration, security, and browser tests cover hosted and device authority without a hosted device-data copy, process-restart recovery, command replay, duplicate and out-of-order events, leases, fence rejection, capability mismatch, cross-workspace denial, workspace traversal and working-directory denial, secret non-propagation, start by any current participant, dispatch, branch isolation, ordered attempts, progress, one focused blocked question, visible `Blocked` and `Failed` statuses while remaining in `In development`, assigned-participant routing, creator fallback, removal during assignment, blocking, review, and an active run, assignment clearing, owner responsibility and run-control handoff, historical attribution, former-participant denial, responder authorization, accepted-answer revision write-back, manifest and revision digest binding, resumable and reconstructed context, retryable and terminal failure classification, three bounded automatic retries, retry exhaustion, any-current-participant manual retry, same-worker enforcement, cancellation by the current initiator or owner, cancellation denial for other participants and former initiators, readiness reevaluation, new-run restart, worker disconnect, stale-process termination, and reconciliation.

- [ ] Task 4 - Collect and present mandatory verification evidence.
  - Status: Blocked by Task 1.
  - Purpose: Let users judge the result from tests, screenshots when supported, branch state, and explicit failures.
  - Owned surfaces: `Evidence`, versioned normalized evidence-event payloads, event schema and payload validation, required-check contract snapshot, worker-derived command and exit results, same-commit verification binding, immutable evidence and supersession links, attempt, command, branch, commit, source, time, duration, digest, applicability and redaction provenance, private authoritative-storage artifact interface, content type and size limits, supported screenshot capture, unsupported or inapplicable screenshot disclosure, raw-provider-event exclusion, agent-prose negative proof, failed and missing proof presentation, success-claim gate, activity integration, fixtures, and evidence UI.
  - Owns: AC-16, AC-19, AC-20, entity:Evidence
  - Depends on: Task 3
  - Proof: Event-schema, ingestion, artifact-store, automated, integration, security, and browser tests cover valid and invalid schema versions, stale fences and sequences, duplicate, out-of-order, oversized, unauthorized, and raw provider events, configured required checks, worker command and exit provenance, agent-prose rejection, same-commit binding, commit-change invalidation, immutable supersession, failed and missing proof, conditional screenshot capture and disclosure, private artifact authorization, content type, size and digest validation, secret and project-content redaction, activity presentation, and rejection of every false success claim.

- [ ] Task 5 - Deliver preview, human-review handoff, and in-product notifications.
  - Status: Blocked by Task 1.
  - Purpose: Give users a testable web result when available and reserve accepted completion for an authorized reviewer.
  - Owned surfaces: `PreviewDeployment`, `ReviewDecision`, Slice 07 `Notification` event types extending the shared account-level notification foundation, one configured preview-adapter contract, idempotent preview request, status and cleanup, configured-path and provider-reference authorization, external credential isolation, exact run, attempt, branch and verified-commit binding, timeout, expiry, supersession, cancellation and project-deletion cleanup, safe links, preview status and non-production labeling, unavailable and failed preview disclosure, `Ready for review` transition independent of preview success, review surface, approval and rejection by the current responsible participant or project owner, rejection feedback and same-run same-branch new-attempt handoff through Task 3's continuation contract, prior review and evidence preservation, at-least-once notification projector, durable lifecycle-event consumption, unique event-type, run-state-version and recipient key, unread and read state, PubSub presentation hint, blocked notification to the current responsible participant, ready-for-review notification to the current responsible participant and owner, terminal-failed notification to the current initiator, current responsible participant, and owner, delivery-time current-participation checks, read-time authorization, recipient deduplication, minimized body, safe internal links to available evidence and preview, fixtures, LiveViews, and responsive accessibility behavior.
  - Owns: AC-21, AC-22, AC-23, AC-24, AC-25, AC-26, AC-27, AC-35, entity:PreviewDeployment, entity:ReviewDecision, entity:Notification
  - Depends on: Task 4
  - Proof: Preview-adapter, notification-projector, integration, security, privacy, and browser tests cover automatic idempotent configured preview, exact verified-commit binding, unavailable preview, timeout, provider failure without review-readiness failure, safe ready link, expiry, supersession, cleanup commands and failures, provider secret non-persistence, non-production labeling, `Ready for review`, rejection of agent and participants other than the current responsible participant or owner, responsible-participant or owner approval to `Done`, responsible-participant or owner rejection with feedback to `In development`, same-run same-branch continuation as a new attempt, preserved prior evidence and review feedback, projector replay and restart, unique recipient keys, durable unread delivery without PubSub, idempotent mark-read, the blocked, ready-for-review, and terminal-failed recipient matrices, stale-recipient insertion and read denial, deduplication, minimized body, and authorized links to available evidence and preview.

- [ ] Task 6 - Enforce the feature-delivery privacy and security contract.
  - Status: Blocked by Task 1, Tasks 2–5, and the three governance capabilities.
  - Purpose: Apply the approved purposes, access boundaries, lifecycles, redaction, processor controls, rights behavior, audit, and anonymous-analytics boundary across every introduced record and integration.
  - Owned surfaces: `DataProcessingRecord`, `DeploymentPrivacyProfile`, complete Slice 07 processing inventory; contract-necessity and security legitimate-interest purpose enforcement; no analytics, advertising, model-training reuse, unrelated product improvement, or secondary-use controls; necessity and project-scoped current-participant access enforcement for specifications, comments, revisions, readiness findings, runs, attempts, commands, execution manifests, leases, fence and sequence metadata, checkpoints, questions, activity, evidence, screenshots, previews, review decisions, notifications, worker and provider metadata, disclosure confirmations, credentials, logs, caches, indexes, backups, exports, support records, and derived records; content-free default and verified time-bounded audited support elevation; hosted relay minimization and 24-hour cleanup for device-authoritative projects; raw-provider-event non-persistence; 30-day temporary command, checkpoint, provider-thread, transient-log, superseded-artifact and security-log cleanup; 90-day notification cleanup; 35-day encrypted-backup expiry; project-deletion cascade and preview, artifact, cache, index and processor cleanup; external-cleanup reconciliation without restored access; verified access, correction, export or portability, erasure, restriction and objection; historical-attribution necessity review and anonymization; worker, model, preview, artifact, hosting, backup and support processor and transfer configuration; provider retention and training-use profile; secret and project-content redaction; required privacy and security review; and `capability:guided-specification-delivery` readiness write-back.
  - Owns: AC-28, AC-37, AC-38, AC-39, entity:DataProcessingRecord, entity:DeploymentPrivacyProfile
  - Depends on: Task 2, Task 3, Task 4, Task 5
  - Proof: Processing-inventory, field-purpose, lawful-basis, necessity, current and removed participant access, cross-project isolation, support-elevation, disclosure-confirmation, retention-clock, pruner, project deletion, external-cleanup reconciliation, preview and artifact cleanup, rights export, correction, restriction, objection, erasure and historical-attribution anonymization, processor, transfer, provider-retention and training-use, backup expiry, relay, cache, log, secret-exposure, project-content exposure, audit-minimization, negative secondary-use, browser-network, analytics-store absence, and deployment-profile checks pass with the required privacy and security review.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Five-column feature lifecycle, gated transition enforcement, project-participant assignment, `Assign to me`, separate `Blocked` and `Failed` statuses, blocker enforcement, suggestion dismissal, readiness, revision, authorization, and duplicate-start tests pass.
- [ ] Agent dispatch, branch isolation, ordered attempts, assignee-or-creator blocked-question routing, write-back, same-run resume, bounded automatic and manual retry, stale-attempt fencing, initiator-or-owner cancellation authorization, readiness reevaluation, new-run restart, and recovery tests pass.
- [ ] Hosted PostgreSQL and worker-owned device delivery-store contracts pass atomic state, activity, command, idempotency, restart, and no-hosted-device-copy tests.
- [ ] Outbound versioned worker protocol, authentication, capability negotiation, at-least-once command replay, acknowledgement, heartbeat, lease, fence, sequence, reconnect, and cross-workspace denial tests pass.
- [ ] Execution manifests bind exact revisions, slices, base and target branches, configured checks, agent and worker references, continuation reasons, and digests without carrying raw credentials.
- [ ] Workspace-root containment, exact agent working directory, one-current-process locking, same-worker retry, provider-thread-loss reconstruction, agent-event normalization, and secret non-propagation tests pass.
- [ ] Participant removal and leave clear current assignment, route pending question and review responsibility to the owner, preserve non-interactive historical attribution, keep active runs under owner control, and deny former-participant access.
- [ ] Current participant presentation uses project display names without exposing other participant emails, and former-participant history preserves the last accepted project display name.
- [ ] Configured required checks, branch and exact verified-revision identity, evidence provenance, conditional screenshot, missing or failed proof, and secret-redaction tests pass.
- [ ] Normalized event schema, stale and invalid event rejection, worker-derived check results, same-commit completion, immutable supersession, private artifact authorization, size, digest, redaction, and agent-prose negative-proof tests pass.
- [ ] Automatic configured preview, unavailable-preview, and failed-preview scenarios pass without production deployment or preview success becoming a review-readiness gate.
- [ ] Preview idempotency, exact-commit binding, timeout, expiry, supersession, safe-link, credential-isolation, cleanup, and provider-failure tests pass against the configured adapter double.
- [ ] `Ready for review`, unauthorized-transition rejection, responsible-participant-or-owner approval to `Done`, and responsible-participant-or-owner feedback-based rejection to the same run and branch as a new `In development` attempt pass.
- [ ] In-product blocked-to-responsible, review-ready-to-responsible-and-owner, and failed-to-initiator-responsible-and-owner notifications pass current-participation, recipient, authorization, deduplication, content-minimization, and evidence-link checks; no external notification channel is invoked.
- [ ] Notification projector replay, restart, unique event-recipient keys, durable unread delivery, PubSub independence, idempotent mark-read, removal denial, minimized body, and safe internal-link tests pass.
- [ ] Desktop and mobile board, feature, activity, blocked, review, and completion scenarios pass.
- [ ] GDPR data contract, access, retention, deletion, processor, transfer, audit, and privacy review are complete.
- [ ] Start-time execution, provider, preview, transfer disclosure and change-triggered confirmation tests pass.
- [ ] Temporary 30-day, notification 90-day, relay and cache 24-hour, security-log 30-day, and backup 35-day lifecycle enforcement passes, including project-deletion and external-cleanup reconciliation.
- [ ] Verified rights, historical-attribution necessity and anonymization, current-participant access, removed-participant denial, support elevation, processor, transfer, provider-use, no-analytics, and no-secondary-use checks pass.
- [ ] `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [ ] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass.
- [ ] Live configured worker and coding-agent smoke proofs pass, or remain explicitly environment-blocked without weakening deterministic adapter proof.
- [ ] New decisions and invalidated proof are written back.

## Blocked Decisions

- No agreement decision remains unresolved. Task 1 is blocked until the storage-authority, participation-boundary, and specification-store capabilities are delivered by their named provider tasks; Task 6 additionally requires the three governance capabilities.

## Release Gate

- Deployment-specific controller details, worker, model, preview, and infrastructure processors, regions, transfer safeguards, notices, incident handling, and enforced retention evidence.
- Deployment-specific provider retention and model-training-use settings, processor agreements, support-access procedure, deletion propagation, and any required DPIA evidence.
- Live configured preview-provider request, access, status, expiry, and cleanup smoke proof when previews are enabled for the deployment.
- Final accountable privacy or legal review for the configured deployment and its subprocessors.

## Progress Log

### 2026-07-28 - Shared specification-store dependency extracted

- Completed: Removed Slice 07 ownership of the shared `SpecificationRevision` persistence model, recorded the project-specification store as a task-level capability prerequisite, and retained Slice 07 ownership of feature workflow, guided editing, readiness, agent delivery, evidence, review, preview, notifications, and their consumer behavior.
- Remaining: Complete the three operational provider tasks before Task 1, then complete the three governance provider tasks before Task 6.
- Failed checks: None; implementation has not started.
- Spec updates: Added canonical capability dependencies, removed `entity:SpecificationRevision` from Task 2 ownership, prohibited duplicate specification persistence, and kept `SpecificationRevision` as a consumed external boundary.

### 2026-07-23 - Initial product-loop draft

- Completed: Captured the guided specification, readiness, explicit start, autonomous implementation, blocking-question resume, evidence, preview, and notification workflow.
- Remaining: Resolve the listed product decisions before transitioning to feature-specific orchestration and worker design.
- Failed checks: None; implementation has not started.
- Spec updates: Created the core product workflow specification, limited its first executable slice to one configured agent path, and recorded the shared Phoenix control-plane decision from Slice 01.

### 2026-07-27 - Completion evidence, preview, and notification checkpoint

- Completed: Approved automatic preview after successful verification only through a preconfigured authorized path, in-product-only first-release notifications, and mandatory configured-check plus exact branch and verified-revision evidence with conditional screenshots and previews.
- Remaining: Complete and approve the separate project-participation prerequisite, resolve participant notification and action authorization, then complete the orchestration, worker, revision, evidence, preview, notification, privacy, and verification designs.
- Failed checks: None; implementation has not started.
- Spec updates: Replaced the resolved product questions, made preview failure non-blocking for review readiness, moved participation management into a separate prerequisite specification, kept only its current-authorization, project-display-name, and removal-handoff consumers in this slice, prohibited participant-email presentation, recorded assignment clearing, owner responsibility and active-run handoff, added stable acceptance-criterion and task labels, assigned every active surface and entity to one primary task, and recorded executable task dependencies without expanding the active outcome.

### 2026-07-28 - Product authorization agreement

- Completed: Approved start for every current participant, cancellation by the current run initiator or owner, review decisions by the current responsible participant or owner, deterministic responsible-participant fallback, event-specific in-product notification recipients with current-participation checks and deduplication, bounded same-run retry, terminal `Failed` presentation, cancellation recovery, and same-run review-rejection continuation.
- Remaining: Complete and verify the project-participation prerequisite, then resolve the orchestration, worker, revision, evidence, preview, notification-mechanism, privacy, and verification designs.
- Failed checks: None; implementation has not started.
- Spec updates: Closed the remaining product and recovery questions, moved requirements to `Approved`, added cancellation, failure-retry, and review-continuation acceptance coverage, mapped each to its owning run or review task, and preserved technical design and prerequisite implementation as later-stage blockers.

### 2026-07-28 - Orchestration and worker design agreement

- Completed: Selected native Phoenix orchestration with storage-mode authority, current state plus durable commands, ordered fenced attempts, at-least-once worker delivery, outbound versioned Phoenix Channels, worker-side secrets and workspace enforcement, revision-bound execution manifests, provider-thread-independent continuation, and three bounded same-worker retries.
- Remaining: Complete and verify the project-participation prerequisite, then resolve evidence and preview contracts, notification mechanics, privacy lifecycle, and canonical verification commands.
- Failed checks: None; implementation has not started.
- Spec updates: Replaced the first four technical questions and blockers, added `RunAttempt` and `RunCommand`, assigned all orchestration surfaces to Task 3, and expanded the gate for hosted and device authority, protocol replay, fencing, manifest binding, workspace safety, and recovery.

### 2026-07-28 - Evidence, preview, notification, and proof agreement

- Completed: Defined normalized evidence events, worker-derived same-commit required-check proof, immutable private artifacts and supersession, one idempotent configured preview adapter, durable recipient-scoped in-product notification projection, the established Phoenix verification gate, live worker and agent smoke proof, and conditional preview release proof.
- Remaining: Complete and verify the project-participation prerequisite and approve the Slice 07 privacy and lifecycle agreement.
- Failed checks: None; implementation has not started.
- Spec updates: Replaced the evidence, preview, notification-mechanism, and verification questions and blockers; expanded Tasks 4 and 5 with their implementation and browser surfaces; and separated deterministic local proof from deployment-dependent live preview evidence.

### 2026-07-28 - Privacy and lifecycle agreement

- Completed: Approved start-time execution and provider disclosure, contract-necessity core processing, security legitimate-interest processing, no Slice 07 analytics or secondary use, storage-mode and transfer boundaries, fixed temporary, notification, relay, log and backup lifecycles, project-deletion cleanup, participant and support access, verified rights, historical-attribution anonymization, processor controls, and the deployment privacy release gate.
- Remaining: Complete and verify the project-participation prerequisite before Task 1 can confirm its consumer contract and implementation can begin.
- Failed checks: None; implementation has not started.
- Spec updates: Closed the final design question and decision blocker, mapped disclosure to Task 2, mapped privacy criteria and existing privacy entities to Task 6, separated the implementation prerequisite from decisions, and retained deployment-specific vendors, transfers, provider-use settings, DPIA or legal review, and live cleanup evidence in the release gate.
