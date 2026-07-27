# Guided Specification And Delivery Tasks

## Status

Blocked

## Active Slice

Deliver one project feature across the `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done` board columns through explicit start, one branch-isolated configured coding-agent run, durable blocking-question resume, mandatory verification evidence, an automatic pre-authorized preview when configured, authorized approval or feedback-based rejection, and in-product action and outcome notifications. Show `Blocked` as a status without moving the feature to another column.

## Implementation Boundary

Included:

- One project-scoped feature board with the five approved lifecycle columns, gated action-driven transitions, a separate visible `Blocked` status, and a feature detail workflow.
- Guided requirement structure with visible blocking findings, non-blocking suggestions, and suggestion dismissal.
- Explicit start for one approved specification revision.
- One configured coding-agent and worker boundary without provider-selection UX.
- One isolated feature branch and resumable run.
- Feature creator, project-wide participant assignment, `Assign to me`, assignee-or-creator blocking-question routing, accepted-answer write-back, progress, comments, and typed evidence.
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

- A separate focused project-participation specification must define and deliver current participant identity, authorization, and access-removal behavior before this slice implements assignment, notification, run-control, review, or project-content authorization.

## Tasks

- [ ] Task 1 - Approve the feature-delivery product, technical, privacy, and verification contracts.
  - Status: Blocked.
  - Purpose: Resolve the remaining authorization, orchestration, worker, revision, evidence, preview, notification, privacy, and proof decisions before implementation.
  - Owned surfaces: Active-slice outcome and scope, external project-participation prerequisite and consumer contract, participant action and notification rules, lifecycle and state agreement, orchestration and worker contracts, specification write-back and resume contract, evidence and preview contracts, in-product notification contract, privacy data contract, release gate, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Depends on: none
  - Proof: Requirements, design, data contracts, task ownership, task sequence, acceptance-criterion and entity traceability, and canonical verification commands have no unresolved active-slice blockers.

- [ ] Task 2 - Deliver the feature board, guided specification, and readiness workflow.
  - Status: Blocked by Task 1.
  - Purpose: Make the board and start boundary durable and understandable before agent execution exists.
  - Owned surfaces: `Feature`, `SpecificationRevision`, `ReadinessAssessment`, read-only current-participant authorization and project-display-name consumer, participant-email non-disclosure, project-scoped board and feature-detail LiveViews, five fixed lifecycle columns, creator and optional assignment controls, `Assign to me`, guided requirement structure, blocking and non-blocking finding presentation, non-blocking dismissal, readiness evaluation, gated pre-development lifecycle actions, start availability, stale and unauthorized participant denial, and supporting domain, persistence, fixtures, and responsive accessibility behavior.
  - Owns: AC-01, AC-03, AC-04, AC-07, AC-08, AC-09, AC-10, AC-11, AC-12, AC-13, AC-14, AC-29, AC-31, entity:Feature, entity:SpecificationRevision, entity:ReadinessAssessment
  - Depends on: Task 1
  - Proof: Domain, permission, and browser tests cover the five lifecycle columns, rejection of free drag-and-drop transitions, gated authorized movement, feature creation with creator and optional assignment, assignment by any current authorized project participant to any other current authorized participant, project-display-name presentation, participant-email non-disclosure, `Assign to me`, stale and unauthorized assignment, action, notification, review, and content-access denial, guided missing information, blocking and non-blocking classification, rejection of blocker dismissal, authorized suggestion dismissal, unavailable start while blocked, readiness changes, revision binding, explicit start authorization, and duplicate-start rejection without any participation mutation.

- [ ] Task 3 - Deliver one branch-isolated agent run with durable progress and blocking-question resume.
  - Status: Blocked by Task 1.
  - Purpose: Execute the approved slice while preserving completed work and routing product decisions back into the specification.
  - Owned surfaces: `AgentRun`, `BlockingQuestion`, `ActivityEntry`, authorized start and cancellation actions, one configured worker dispatch, isolated branch creation, immutable starting-revision binding, run lifecycle and progress events, visible blocked status and reason, assigned-participant or creator question routing, participation-removal handoff, assignment clearing, owner question and review responsibility fallback, last-project-display-name non-interactive historical attribution, owner control of continuing active runs, former-participant denial, responder authorization, accepted-answer write-back, checkpoint and resume, duplicate dispatch and resume prevention, cancellation, worker disconnect, reconciliation, and supporting domain, persistence, fixtures, and status UI.
  - Owns: AC-02, AC-05, AC-06, AC-15, AC-17, AC-18, AC-30, entity:AgentRun, entity:BlockingQuestion, entity:ActivityEntry
  - Depends on: Task 2
  - Proof: Integration tests cover dispatch, branch isolation, progress, one focused blocked question, visible `Blocked` status while remaining in `In development`, assigned-participant routing, creator fallback, removal during assignment, blocking, review, and an active run, assignment clearing, owner responsibility and run-control handoff, historical attribution, former-participant denial, responder authorization, accepted-answer write-back, idempotent resume, cancellation, worker disconnect, and reconciliation.

- [ ] Task 4 - Collect and present mandatory verification evidence.
  - Status: Blocked by Task 1.
  - Purpose: Let users judge the result from tests, screenshots when supported, branch state, and explicit failures.
  - Owned surfaces: `Evidence`, configured required-check execution and results, isolated branch and exact verified-revision identity, visual-result and capture-capability classification, supported screenshot capture, unsupported or inapplicable screenshot disclosure, evidence provenance, failed and missing proof presentation, success-claim gate, redaction boundary, and supporting domain, persistence, fixtures, activity integration, and evidence UI.
  - Owns: AC-16, AC-19, AC-20, entity:Evidence
  - Depends on: Task 3
  - Proof: Automated, integration, security, and browser tests cover configured required checks, failed and missing proof, branch and exact verified-revision binding, conditional screenshot capture and disclosure, evidence provenance, secret redaction, activity presentation, and rejection of every false success claim.

- [ ] Task 5 - Deliver preview, human-review handoff, and in-product notifications.
  - Status: Blocked by Task 1.
  - Purpose: Give users a testable web result when available and reserve accepted completion for an authorized reviewer.
  - Owned surfaces: `PreviewDeployment`, `ReviewDecision`, `Notification`, automatic preview request after successful verification, configured-path authorization, branch, revision, and run binding, preview status and non-production labeling, unavailable and failed preview disclosure, `Ready for review` transition independent of preview success, review surface, authorized approval and rejection actions, rejection-feedback resume handoff, blocked and terminal in-product notifications, recipient resolution, links to available evidence and preview, deduplication, and supporting domain, persistence, fixtures, LiveViews, and responsive accessibility behavior.
  - Owns: AC-21, AC-22, AC-23, AC-24, AC-25, AC-26, AC-27, entity:PreviewDeployment, entity:ReviewDecision, entity:Notification
  - Depends on: Task 4
  - Proof: Integration and browser tests cover automatic configured preview, unavailable preview, preview failure without review-readiness failure, branch, revision, and run linkage, non-production labeling, `Ready for review`, rejection of agent or unauthorized completion, authorized approval to `Done`, authorized rejection with feedback to `In development`, resumable work, notification recipients, deduplication, authorization, status content, and links to available evidence and preview.

- [ ] Task 6 - Enforce the feature-delivery privacy and security contract.
  - Status: Blocked by Task 1.
  - Purpose: Apply the approved purposes, access boundaries, lifecycles, redaction, processor controls, rights behavior, audit, and anonymous-analytics boundary across every introduced record and integration.
  - Owned surfaces: Active processing inventory; purpose, lawful-basis, necessity, and access enforcement for specifications, comments, revisions, readiness findings, runs, questions, activity, evidence, screenshots, previews, review decisions, notifications, worker and provider metadata, credentials, logs, caches, indexes, backups, exports, and derived records; retention and deletion enforcement; data-subject rights; processor and transfer configuration; secret and project-content redaction; audit minimization; aggregate genuinely anonymous analytics; negative secondary-use controls; and required privacy and security review.
  - Owns: AC-28
  - Depends on: Task 2, Task 3, Task 4, Task 5
  - Proof: Data-inventory, purpose and basis, access, cross-project isolation, retention, deletion, rights, processor, transfer, backup, cache, log, secret-exposure, project-content exposure, audit-minimization, negative secondary-use, and anonymous-analytics checks pass with the required privacy and security review.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Five-column feature lifecycle, gated transition enforcement, project-participant assignment, `Assign to me`, separate `Blocked` status, blocker enforcement, suggestion dismissal, readiness, revision, authorization, and duplicate-start tests pass.
- [ ] Agent dispatch, branch isolation, assignee-or-creator blocked-question routing, write-back, resume, cancellation, and recovery tests pass.
- [ ] Participant removal and leave clear current assignment, route pending question and review responsibility to the owner, preserve non-interactive historical attribution, keep active runs under owner control, and deny former-participant access.
- [ ] Current participant presentation uses project display names without exposing other participant emails, and former-participant history preserves the last accepted project display name.
- [ ] Configured required checks, branch and exact verified-revision identity, evidence provenance, conditional screenshot, missing or failed proof, and secret-redaction tests pass.
- [ ] Automatic configured preview, unavailable-preview, and failed-preview scenarios pass without production deployment or preview success becoming a review-readiness gate.
- [ ] `Ready for review`, unauthorized-transition rejection, authorized approval to `Done`, and feedback-based rejection to resumable `In development` scenarios pass.
- [ ] In-product blocked, review-ready, and failed notifications pass recipient, authorization, deduplication, content-minimization, and evidence-link checks; no external notification channel is invoked.
- [ ] Desktop and mobile board, feature, activity, blocked, review, and completion scenarios pass.
- [ ] GDPR data contract, access, retention, deletion, processor, transfer, audit, and privacy review are complete.
- [ ] Build, formatting, lint, static, security, and canonical test commands pass.
- [ ] New decisions and invalidated proof are written back.

## Blocked Decisions

- Create and approve the separate project-participation specification and its current-participant authorization contract, then resolve which participants receive each in-product notification and may start, cancel, approve, and reject runs.
- Define the durable orchestration boundary for reusing or reimplementing OpenAI Symphony behavior behind the selected Phoenix control plane.
- Define persistent lifecycle, event, idempotency, checkpoint, and reconciliation contracts.
- Define local and remote worker trust, transport, isolation, credential, and agent-provider boundaries.
- Define specification revision, blocking-answer write-back, and resumable agent-context contracts.
- Define evidence, screenshot, preview deployment, notification, retention, redaction, and cleanup contracts.
- Approve the slice GDPR processing inventory and required privacy or legal reviews.
- Define canonical build, test, security, browser, worker, agent, and preview verification commands.

## Release Gate

- Deployment-specific controller details, worker, model, preview, and infrastructure processors, regions, transfer safeguards, notices, incident handling, and enforced retention evidence.
- Final accountable privacy or legal review for the configured deployment and its subprocessors.

## Progress Log

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
