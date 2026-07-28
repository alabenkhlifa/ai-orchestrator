# Guided Specification And Delivery Design

## Context

SDD Orchestrator exists to move feature work from requirements to verified implementation while keeping agent behavior, stop conditions, progress, decisions, and proof visible. The current specifications establish repository, identity, storage, and portability boundaries but do not yet define the core product loop.

OpenAI Symphony provides a language-independent orchestration specification and an experimental Elixir reference implementation for isolated workspaces, agent execution, reconciliation, retries, blocked state, and operational visibility. This feature adapts those capabilities to a specification-first workflow controlled from a project board.

## Proposed Approach

Represent each feature as a durable lifecycle record connected to versioned requirements, readiness findings, an approved implementation slice, agent runs, blocking questions, evidence, preview deployments, and notifications. Present the lifecycle through five first-release board columns: `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`. Treat `Blocked` and `Failed` as additional visible statuses so interrupted and terminally failed runs keep their lifecycle position.

Keep requirement guidance and readiness assessment separate from execution authorization. Any current participant may start development, which creates a run against one approved specification revision and isolated branch. The run emits durable progress and evidence events and may be canceled only by its current initiator or the project owner. Cancellation ends that run and returns the feature to the readiness state of its current revision; a later start creates a new run and branch. A blocking product question pauses the run until an authorized answer is written back to the specification, after which the same run resumes. Retryable execution failures use bounded backoff on the same run, workspace, and branch; terminal failure remains visibly `Failed` in `In development` until any current participant retries it or an authorized cancellation ends it. When participation ends, consume the approved handoff by clearing current assignment, routing pending question and review responsibility to the project owner, preserving historical attribution, and leaving the active run under owner control. Successful agent work ends in human review. The current responsible participant or owner may approve it into `Done` or reject it with feedback into `In development`, where the same run and branch continue as a new attempt.

Treat required-check results, exact branch and revision identity, applicable screenshots, and preview outcomes as typed evidence rather than unstructured agent claims. Start an authorized preview automatically after successful verification, while keeping preview absence or failure separate from verification success and human review readiness. Deliver action-required and completion notifications in-product in the first release.

Implement the orchestration semantics natively behind the Phoenix control plane and the authoritative project-storage adapter rather than importing Symphony's in-memory scheduler or issue-tracker loop. Persist current state plus ordered activity and durable commands at the project's selected storage destination. Dispatch those commands at least once to one preconfigured compatible worker over a worker-initiated authenticated TLS channel, and make command IDs, ordered attempts, execution leases, fence tokens, and event sequence numbers prevent duplicate or stale execution from changing authoritative state. Adapt Symphony's isolated-workspace, agent-runner, retry, and reconciliation concepts behind project-specific interfaces.

## Components Affected

- Project feature board and feature detail view.
- External project-participation authorization boundary.
- Guided requirement authoring and readiness assessment.
- Specification revision and approval boundary.
- Agent-run control and status presentation.
- Authoritative delivery-store, command outbox, ordered-attempt, lease, and reconciliation boundaries.
- Local and remote worker dispatch boundary.
- Branch and workspace isolation.
- Blocking-question, tagging, and resume workflow.
- Feature activity, comments, and evidence storage.
- Test and screenshot evidence collection.
- Branch-preview deployment integration.
- Human review and approval.
- In-product and future external notifications.
- Audit, privacy, retention, and secret-redaction controls.

## Data and Access Boundaries

- `Feature`: the stable project-scoped unit shown on the board, with its recorded creator and an optional assigned authorized participant.
- `SpecificationRevision`: the recorded requirements and acceptance agreement used by readiness and execution.
- `ReadinessAssessment`: visible blocking findings, active non-blocking suggestions, dismissed non-blocking suggestions, and satisfied product information for one revision.
- `AgentRun`: one authorized feature-delivery lifecycle that preserves one branch and contains ordered execution attempts until approval, cancellation, or governed cleanup.
- `RunAttempt`: one exclusive worker execution or continuation within a run, bound to an exact specification revision, execution manifest, worker lease, and attempt number.
- `RunCommand`: one durable idempotent start, resume, retry, cancel, or reconcile instruction delivered at least once to the configured worker.
- `BlockingQuestion`: one focused product decision that pauses a run and identifies its intended responders.
- `ActivityEntry`: an ordered user-visible record of progress, comments, questions, answers, evidence, and outcomes.
- `Evidence`: an immutable typed required-check result, screenshot artifact, branch and commit reference, preview outcome, or other approved proof with run, attempt, source, digest, redaction, and supersession provenance.
- `PreviewDeployment`: one idempotent non-production deployment request and observed lifecycle for an exact successfully verified run revision.
- `ReviewDecision`: an authorized approval or feedback-based rejection for one completed run.
- `Notification`: one recipient-scoped durable in-product message with a unique event key, delivery state, read state, safe feature link, and minimized status content.
- `DataProcessingRecord`: the existing deployment inventory entry extended to cover every Slice 07 personal-data and project-content category, purpose, basis, field, access boundary, retention rule, right, processor, and transfer.
- `DeploymentPrivacyProfile`: the existing release-gate record extended with the actual worker, model, preview, artifact, hosting, backup, support, region, transfer, retention, training-use, notice, incident, and review evidence for the deployment.

Required boundaries:

- Every feature, revision, run, question, evidence item, preview, and notification belongs to one project.
- Only authorized project participants can read project content, start runs, answer questions, or review evidence; cancellation and review decisions apply the narrower approved role matrix.
- The current responsible participant resolves to the current assigned participant, otherwise the current creator, with the owner as the fail-closed fallback.
- Current participant identity and authorization come from a separate project-participation boundary. This slice may read and enforce that state but cannot create, invite, grant, revoke, or otherwise mutate participation.
- Current participant presentation consumes the project-specific display name and never exposes another participant's email.
- Assignment, notification delivery, run control, review, and every project-content read revalidate current participation and fail closed when authorization is stale or absent.
- Before the first start and after any execution, provider, preview, or transfer-boundary change, the start interface requires confirmation of the configured processing summary. An unchanged boundary does not interrupt every run.
- The participation-removal handoff clears current assignment, routes pending question and review responsibility to the immutable project owner, preserves the last accepted project display name as non-interactive historical attribution, and keeps an active run available only under owner control.
- Feature, revision, run, attempt, command, activity, question, and evidence authority follows the project's selected storage mode. Hosted projects commit through PostgreSQL; device projects commit through the worker-owned device store without creating a hosted project-data copy.
- Every state-changing user action commits the validated current-state transition, ordered activity entry, and any resulting command in one authoritative-storage transaction.
- Hosted dispatchers claim pending commands with database locking and leases. Device dispatch is claimed inside the serialized worker-owned store. Both adapters expose the same idempotent delivery-store contract.
- Commands are delivered at least once and carry a stable command ID, run ID, ordered attempt number, expected state version, execution-manifest digest, and operation. Duplicate command IDs return the recorded result without starting another process.
- One run has at most one current attempt and one execution lease. Every worker event carries the current fence token and monotonic attempt sequence; stale, expired, duplicate, or out-of-order events cannot change authoritative state.
- Agents receive the minimum project, repository, specification, and credential capabilities required for the run.
- Worker credentials authenticate only the approved workspace or execution target. Provider and repository secrets resolve inside the worker's configured secret boundary and are not included in commands, agent-readable requirements, comments, evidence, events, or analytics.
- A run is bound to one immutable starting specification revision; accepted answers create recorded updates and an auditable resume point.
- Every attempt is bound to one immutable execution manifest containing the run and attempt identity, starting and effective specification revision IDs and digests, approved slice, repository base revision, isolated target branch, required-check contract, configured agent and worker references, and only the project content required for that attempt.
- An accepted blocking answer atomically creates or selects the resulting immutable specification revision, links it to the question resolution, and enqueues the next attempt against that exact revision. Review feedback continues against the current effective revision; feedback that would change the approved product agreement blocks for specification write-back instead of silently changing the manifest.
- Automatic retry, manual retry, blocking-answer resume, and review-rejection continuation preserve one run and branch while creating distinct ordered attempts; cancellation is terminal and a later start creates a new run and branch.
- The worker may resume a compatible live agent thread, but durable recovery never depends on provider thread memory. When a thread cannot resume, the next attempt starts a new thread in the same run workspace from the immutable manifest, accepted specification delta, prior checkpoint, and continuation reason.
- Retry classification is explicit. Transport loss, temporary worker or provider unavailability, rate limits, and recoverable agent-process exits are retryable; invalid authorization, incompatible protocol, unsafe workspace, malformed manifest, missing required configuration, and exhausted execution limits are terminal until corrected or manually retried.
- The first release allows three automatic retries after the initial attempt, using exponential backoff from 15 seconds with jitter and a five-minute cap. Manual retry starts the next attempt without resetting governed history.
- Automatic and manual retry stay on the configured worker and workspace. Worker pools and cross-worker migration remain deferred.
- A worker creates one run workspace under its configured workspace root, validates the normalized path and process working directory, uses the run's stable isolated branch, and prevents agent or hook execution outside that boundary.
- Every completion claim is bound to one isolated branch, the exact verified revision, and the configured required-check results.
- The attempt snapshots the configured required-check contract before execution. Every required result records the exact command, exit outcome, duration, attempt, branch, and commit; all required checks must pass against the same commit that is offered for review.
- Worker events use a versioned normalized envelope with event ID, run and attempt identity, command ID, monotonic sequence, type, occurrence time, source, schema version, and typed payload. Raw provider events are transient and do not become project activity by default.
- Required-check evidence comes from the worker command result rather than an agent narrative. User comments and agent prose may explain evidence but cannot satisfy a required check.
- Evidence is immutable. A corrected, rerun, or later-attempt result creates a new item that explicitly supersedes the older item without erasing prior proof.
- Screenshot artifacts are private project data stored through the authoritative project-storage adapter with content type, byte size, digest, capture applicability, branch, commit, attempt, and redaction state. Public artifact URLs and embedded secrets are prohibited.
- Screenshots are required only for visual work when the configured environment can capture a meaningful result.
- Preview deployment requires preconfigured project authorization, starts automatically only after successful verification, and cannot determine verification success or human review readiness.
- One configured preview adapter exposes idempotent request, status, and cleanup operations. It binds every request to the run, attempt, branch, and verified commit; stores only provider references and safe participant-visible links; and resolves provider credentials outside project records.
- A preview request times out under the configured adapter policy, records `failed` without changing verification success, and becomes `superseded` when a later attempt verifies another commit. Configured expiry and cleanup are displayed when known.
- The first release creates only in-product notifications; blocked events target the current responsible participant, ready-for-review events target the current responsible participant and owner, and failed events target the current initiator, current responsible participant, and owner, with current-participation checks and recipient deduplication.
- Notification creation consumes one durable lifecycle event at least once and uses the unique key of event type, run state version, and recipient identity to create at most one record. PubSub is a presentation hint; the stored unread record is the delivery guarantee.
- Recipient participation and role are resolved immediately before notification insertion. Authorization is rechecked on every list, read, and link-open operation, so removed participants cannot read previously created project notifications.
- Notification content contains the project and feature display context, approved status or required action, event time, and safe internal link. Branch, commit, evidence, and preview details remain behind that authorized link rather than being copied into the notification body.
- Core processing is limited to the participant-requested specification and delivery service under contract necessity. Minimum operational-security processing uses only the documented service-security purpose and approved legitimate-interest assessment.
- Slice 07 creates no product analytics and permits no advertising, model-training reuse, unrelated product improvement, or other secondary purpose.
- Project history and accepted proof remain only for the active project lifetime. Raw provider events are transient; temporary command payloads, checkpoints, provider-thread references, transient logs, and superseded artifacts expire within 30 days after they are no longer active; notifications within 90 days; device relay and cache data within 24 hours; security logs within 30 days; and encrypted rolling backups within 35 days.
- Project deletion revokes access and removes authoritative active copies, then invokes configured preview, artifact, cache, index, and processor cleanup. Cleanup failure remains a restricted reconciliation record and cannot make deleted content accessible.
- Current participants receive project-scoped access. Operations and support content access is disabled by default and requires verified, least-privilege, time-bounded, purpose-limited, audited elevation.
- Verified rights handling reaches authoritative hosted and device records, artifacts, notifications, caches, logs, backups, exports, and configured processors. Historical participant attribution remains identifiable only while project accountability requires it and is anonymized when continued identification is unnecessary.
- Device-authoritative data remains local unless the confirmed configured execution or preview boundary requires an approved transfer. The hosted relay stores no durable device-project copy.
- Local and hosted data follow the authoritative storage mode and lifecycle defined by `specs/05-project-storage-lifecycle/`.

## Interfaces

- Board interface: show the five lifecycle columns, creator, optional assignment, readiness, active run, completion outcome, and visible `Blocked` or `Failed` status without moving the feature to another column. Let an authorized project participant select any authorized participant for `Assigned` or use `Assign to me`. Do not use free dragging to change lifecycle state; expose the gated workflow action available to an authorized user.
- Participant interface: consume current project-participant identity, project display name, authorization, and removal handoff from the separate participation boundary for assignment, notification, run-control, review, content-access, responsibility routing, historical attribution, and active-run control without exposing participant emails or participation-management actions in this slice.
- Specification guidance interface: describe required information, classify visible findings as blocking or non-blocking, and allow only non-blocking suggestions to be dismissed.
- Start interface: remain unavailable while any blocker exists, show the configured execution location, agent or model provider, preview provider, and data-transfer boundary, require confirmation before the first run and after a boundary change, then let any current authorized participant authorize one ready feature revision and create one run without duplicate dispatch.
- Delivery-store interface: transactionally read and transition feature and run state, append ordered activity, enqueue idempotent commands, claim one current attempt, record fenced events, and reconcile through the authoritative hosted or device adapter.
- Dispatcher interface: claim due commands, deliver them at least once, observe acknowledgements and leases, schedule bounded retries, and recover pending work after process restart without treating in-memory OTP state as authoritative.
- Worker gateway interface: negotiate one versioned capability contract over a worker-initiated authenticated TLS channel, authorize the worker for the project execution target, deliver command envelopes, receive acknowledgements, heartbeats, normalized events, and reconciliation snapshots, and reject incompatible or stale workers before execution.
- Worker interface: validate the execution manifest, create or reuse the run workspace and branch, acquire one fenced attempt lease, start, observe, pause, checkpoint, resume, retry, cancel, and reconcile the configured agent process, and prevent a superseded attempt from continuing.
- Agent-adapter interface: target the installed agent protocol version, launch the configured coding agent only inside the validated run workspace, create or resume a provider thread when compatible, normalize provider events into the stable run contract, and expose no worker, control-plane, repository, or unrelated provider credential.
- Question interface: pause the run, record one focused question, tag the feature's assigned participant when present or its creator otherwise, and resume only after accepted specification write-back.
- Reconciliation interface: compare authoritative commands, attempts, leases, worker process state, branch/workspace identity, and last event sequence after reconnect or restart; continue one proven current attempt, fence and stop stale work, or schedule the next bounded retry without cross-worker migration.
- Event-ingestion interface: validate schema version, command, current fence, sequence, source, payload limits, and redaction; idempotently convert approved normalized events into run state, activity, evidence, or questions; and reject raw, duplicate, stale, oversized, or unauthorized payloads.
- Evidence interface: require one immutable typed result per configured check and exact commit, store private artifacts through the authoritative adapter, link superseding proof, redact logs and screenshots before participant presentation, and distinguish absent, unsupported, failed, passed, and superseded evidence.
- Preview-adapter interface: idempotently request one non-production deployment for the verified commit, poll or consume status, mark timeout and provider failure visibly, expose safe ready and expiry metadata, supersede older attempts, and invoke configured cleanup on cancellation, project deletion, or adapter expiry without blocking `Ready for review`.
- Review interface: present the completed run and its evidence in `Ready for review`, accept approval or rejection only from the current responsible participant or project owner, move an approved feature to `Done`, or record rejection feedback and continue the same run and branch as a new attempt in `In development`.
- Notification-projector interface: consume durable lifecycle events at least once, resolve approved roles and current participation at insertion time, enforce one unique event-recipient key, persist unread state before publishing a UI hint, and expose authorized list, mark-read, and safe-link behavior without external delivery.
- Privacy interface: extend the existing processing inventory, retention pruner, verified rights workflow, and deployment privacy profile across every Slice 07 store, worker exchange, provider, artifact, preview, notification, log, cache, backup, export, and derived record without creating a product-analytics pipeline.

## Decisions and Tradeoffs

### Fixed First-Release Board

- Choice: Use `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done` as the five first-release columns, with `Blocked` and `Failed` shown as statuses rather than columns.
- Reason: The board should communicate the feature's place in the specification and delivery workflow while preserving that context when progress is temporarily blocked.
- Consequence: A blocked or terminally failed development run remains in `In development` and exposes its status and reason.

### Gated Lifecycle Transitions

- Choice: Move cards only through authorized workflow actions and validated outcomes; do not allow free drag-and-drop transitions.
- Reason: Board movement must not bypass readiness findings, explicit development authorization, verification evidence, or human review.
- Consequence: The board presents state and available actions, while the lifecycle service validates every transition and rejects direct state changes that do not satisfy the corresponding gate.

### Specification Readiness Before Execution

- Choice: Separate AI readiness assessment from explicit user authorization, prohibit overrides of blocking findings, and permit authorized users to dismiss only non-blocking suggestions.
- Reason: Non-technical users need guidance, but the product must not start costly or consequential work merely because an automated assessment changed.
- Consequence: `Start development` remains unavailable until every blocker is resolved. Readiness findings require a visible blocking classification, suggestion dismissals must not be treated as resolved blockers, readiness and authorization remain distinct durable states, and the starting revision must be recorded.

### Durable Human-In-The-Loop Resume

- Choice: Pause on unresolved product decisions, write accepted answers back to the specification, and resume the same run.
- Reason: Agent questions must improve the durable agreement rather than disappear in comments or require restarting completed work.
- Consequence: Runs need persistent checkpoints, question ownership, revision linkage, and safe resume semantics.

### Blocking Question Routing

- Choice: Record a creator and optional assigned participant on each feature. Route a blocking question to the assigned participant when present and fall back to the creator when unassigned.
- Reason: Responsibility may move away from the person who created the story, while every story still needs a deterministic person to notify.
- Consequence: Question routing requires access-checked `Creator` and optional `Assigned` fields.

### Project-Wide Story Assignment

- Choice: Allow any authorized project participant to assign a story to any other authorized participant in that project, with an `Assign to me` shortcut.
- Reason: Story responsibility should not depend on the creator or require a separate assignment role in the first release.
- Consequence: Assignment selection must be limited to current authorized project participants, and `Assign to me` resolves to the current participant.

### External Project-Participation Prerequisite

- Choice: Define participant provisioning, invitations, membership, roles, access removal, and their lifecycle in a separate focused project-participation specification. This slice consumes only its current authorized-participant boundary.
- Reason: Participation management is an independently valuable access-control workflow with its own identity, invitation, revocation, notification, privacy, and security lifecycle.
- Consequence: Slice 07 remains focused on specification and delivery, but implementation cannot begin until the prerequisite exposes an approved participant-authorization contract. Stale or missing authorization fails closed, and no Slice 07 flow may change participation.

### Removed-Participant Responsibility Handoff

- Choice: Clear current assignment and route pending blocking-question and review responsibility to the immutable project owner when participation ends. Preserve prior contributions under the last accepted project display name as non-interactive historical attribution and keep an active run under owner control instead of canceling it automatically.
- Reason: Removal must end access without erasing project history, losing pending work, or making a membership action implicitly destroy an active run.
- Consequence: The former participant cannot receive project notifications or actions, the owner becomes the deterministic fallback, and historical attribution follows the retention and rights contract defined by the participation prerequisite.

### Responsibility-Based Run Control And Review

- Choice: Let any current authorized participant start a ready feature. Let only the current run initiator or project owner cancel an active run, and only the current responsible participant or project owner approve or reject a feature in `Ready for review`.
- Reason: Starting ready work is a collaborative project action, while cancellation and acceptance change active work or its final product state and need direct responsibility or owner oversight.
- Consequence: Every protected action revalidates current participation and the applicable role. A departed initiator loses cancellation authority, responsibility resolves from current assignment to current creator to owner, and the owner remains the deterministic override and handoff controller.

### Preserved Retry And Explicit Cancellation Recovery

- Choice: Retry transient failures automatically on the same run with bounded backoff. After a non-retryable failure or exhausted budget, keep the feature in `In development` with visible `Failed` status and let any current participant retry the same run. Make cancellation terminal, return the feature to the readiness state of its current revision, and require a later start to create a new run and branch.
- Reason: Transient infrastructure loss should not discard accepted work or create duplicate runs, while an explicit cancellation must provide a clear stop boundary and prevent an old execution context from silently restarting.
- Consequence: Runs contain ordered execution attempts and preserve branch, workspace, checkpoint, activity, and evidence across retries. Canceled history remains governed but cannot resume. Exact retry classification, budget, timing, lease, cleanup, and reconciliation mechanisms are technical-design decisions.

### Evidence-Based Completion

- Choice: Require the configured project-check results plus isolated branch and exact verified-revision identity for every completion claim. Require screenshots only for visual work in a capable configured environment, and include a preview link only when an authorized preview path succeeds.
- Reason: Users need inspectable proof rather than an unsupported agent completion message.
- Consequence: The execution manifest snapshots required checks. The worker records typed immutable command results against one exact commit; a later commit invalidates those results for completion until checks rerun. Conditional evidence stays visibly unavailable rather than being fabricated or treated as universally mandatory.

### Normalized Events And Private Evidence Artifacts

- Choice: Accept only versioned normalized worker events and store typed evidence plus private authoritative-storage artifacts; do not persist raw provider event streams or treat agent prose as proof.
- Reason: Provider protocols change, low-level streams may contain secrets or unnecessary content, and successful verification needs machine-verifiable provenance.
- Consequence: Event ingestion validates schema, identity, fence, sequence, size, and redaction before state changes. Check results include command and exit provenance. Screenshots and larger logs use private digest-addressed artifacts. Corrections and reruns supersede rather than mutate prior evidence.

### Human Review Before Done

- Choice: End successful agent execution in `Ready for review`; allow the current responsible participant or project owner to approve it into `Done` or reject it with feedback back into `In development`.
- Reason: Agent evidence supports a decision but does not replace human acceptance of the requested product outcome.
- Consequence: Agent success, review readiness, resumed development, and accepted completion are distinct states. Rejection creates a new attempt on the same run and branch. The review surface must preserve the run, attempts, branch, evidence, preview, reviewer identity, decision, and rejection feedback.

### Branch Preview Instead Of Production Deployment

- Choice: After successful verification, automatically start a non-production branch preview only when the project has a preconfigured and authorized preview path.
- Reason: Project-level authorization permits a useful test result without interrupting every run for repeated approval or granting authority to merge or deploy to production.
- Consequence: Preview absence or failure remains visible but does not block an otherwise verified feature from reaching `Ready for review`. Merge, release approval, production deployment, preview lifetime, and cleanup beyond the configured path require later specifications.

### One Idempotent Configured Preview Adapter

- Choice: Define one adapter with idempotent request, status, and cleanup operations for the project's pre-authorized preview path. Bind requests to the exact verified run attempt, branch, and commit.
- Reason: The active slice needs deterministic preview behavior without selecting or provisioning providers, embedding provider credentials, or making preview infrastructure the source of verification truth.
- Consequence: The adapter stores only provider references, safe links, status, failure, expiry, and cleanup metadata. Timeout, absence, and failure remain visible and non-blocking. A later verified attempt supersedes the older preview; provider-specific provisioning and cleanup beyond the configured path remain deferred.

### Targeted In-Product Notifications Only

- Choice: Deliver run notifications only inside the product in the first release. Send blocked events to the current responsible participant, ready-for-review events to the current responsible participant and owner, and failed events to the current initiator, current responsible participant, and owner. Exclude stale recipients and deduplicate people who hold multiple roles.
- Reason: The first workflow needs durable action and outcome visibility for the smallest accountable audience without adding external delivery integrations or notifying every project participant.
- Consequence: Email, chat, mobile, and webhook notifications are deferred. Notification persistence, delivery, replay, deduplication, read state, and content minimization follow the durable projection decision below.

### Durable Notification Projection

- Choice: Project lifecycle events into recipient-scoped notification records through an at-least-once projector with a unique event-type, run-state-version, and recipient key. Treat durable unread state as delivery and PubSub only as a live UI hint.
- Reason: In-product delivery should survive application restarts and disconnected browsers without adding an external messaging provider or duplicating events after projector replay.
- Consequence: Recipient authorization is resolved before insertion and checked again on read. Duplicate roles create one record. Removed participants lose access to existing project notifications. Mark-read is idempotent, and notification bodies remain minimal while details stay behind the authorized feature link.

### Shared Phoenix Control Plane

- Choice: Reuse the Phoenix/LiveView/PostgreSQL control-plane foundation selected by `specs/01-github-project-onboarding/` and do not import the experimental Symphony prototype as product code.
- Reason: Symphony's scheduler is issue-tracker-driven and intentionally in-memory, while this product requires durable multi-user actions and authoritative hosted or device project storage.
- Consequence: Phoenix owns the hosted delivery service, dispatcher supervision, worker gateway, PubSub presentation, and hosted PostgreSQL adapter. The device worker owns the device adapter. Symphony remains a behavior and safety reference, not a second runtime or state authority.

### Current State Plus Durable Command Outbox

- Choice: Persist validated current state, append-only user-visible activity, and durable `RunCommand` records rather than adopting full event sourcing or treating OTP process memory as authoritative.
- Reason: Board reads need direct current state, audits need ordered durable history, and worker delivery must survive restarts and duplicate transport without requiring state reconstruction from every low-level agent event.
- Consequence: Each authoritative-storage transaction checks the expected state version, applies one legal transition, appends its activity, and enqueues resulting commands. Hosted command claims use PostgreSQL locking and leases; the device adapter provides equivalent serialized semantics locally.

### Ordered Attempts With Fenced At-Least-Once Delivery

- Choice: Deliver versioned run commands at least once and make the worker execute one numbered `RunAttempt` under one expiring lease and fence token.
- Reason: Exactly-once network delivery is not reliable, and reconnects, retries, and multi-node dispatch can otherwise launch duplicate agent processes or accept late events from superseded work.
- Consequence: Command IDs are idempotent, one run has one current attempt, events are monotonic per attempt, and stale fences fail closed. Reconciliation proves and continues one current process or stops it before the same worker begins the next attempt.

### Storage-Mode-Aware Orchestration Authority

- Choice: Put feature-delivery state, commands, activity, and evidence metadata in the project's authoritative storage destination through one delivery-store contract.
- Reason: `specs/05-project-storage-lifecycle/` prohibits hosting device-authoritative specifications, runs, and generated project data merely to operate the dashboard.
- Consequence: Hosted projects use PostgreSQL transactions and dispatcher claims. Device projects use the worker-owned device store and send only the separately approved transient control and presentation data through the hosted relay. No orchestration path creates a distributed transaction or hosted device-project copy.

### Outbound Versioned Worker Protocol

- Choice: Extend the existing worker-initiated TLS transport into a versioned Phoenix Channel contract for command delivery, acknowledgements, heartbeats, normalized events, and reconciliation snapshots.
- Reason: Local and user-managed workers should not expose inbound ports, and Phoenix already supplies the supervised authenticated channel boundary for the control plane.
- Consequence: Local workers reuse workspace-bound pairing authorization. Preconfigured hosted or remote workers supply their separately provisioned execution-target authorization. Protocol capability negotiation rejects incompatible workers before dispatch; provisioning and credential UX remain outside this slice.

### Worker-Side Secret And Workspace Boundary

- Choice: Send immutable execution manifests and opaque configuration references, resolve repository and provider secrets inside the configured worker boundary, and launch the agent only in a normalized run workspace under the configured root.
- Reason: Control-plane or worker credentials must not become agent input, and a branch name or feature label is not sufficient filesystem isolation.
- Consequence: The agent subprocess receives only required environment and capabilities. The worker strips its own credentials, validates workspace containment and exact working directory, owns the isolated branch and process lock, and normalizes protocol-specific agent events before they can enter durable project activity.

### Revision-Bound Resumable Context

- Choice: Bind every attempt to an immutable execution-manifest digest and exact effective `SpecificationRevision`; treat provider thread continuation as an optimization rather than the durable checkpoint.
- Reason: Blocking answers and review feedback must be auditable, while a worker restart or provider thread loss must not erase the approved scope or force the product to invent context.
- Consequence: Accepted product answers create and link a revision before a continuation command commits. A new provider thread can reconstruct the next attempt from the manifest, accepted delta, branch/workspace checkpoint, prior evidence, and continuation reason. Contradictory review feedback blocks for specification write-back.

### Bounded Same-Worker Recovery

- Choice: Classify failures, retry retryable failures three times after the initial attempt with jittered exponential backoff starting at 15 seconds and capped at five minutes, and keep every retry on the same configured worker and run workspace.
- Reason: Bounded local recovery handles transient loss without creating indefinite cost or the source and secret transfer boundary required for cross-worker migration.
- Consequence: Exhausted or non-retryable failure becomes the approved terminal `Failed` state. Manual retry creates the next numbered attempt. Worker pools, migration, and failover require a later specification.

### Canonical Local Verification And Release Smoke Proof

- Choice: Use the established Phoenix gate for deterministic implementation proof: `mix check`; the explicit formatting, warnings, Credo, Dialyzer, dependency-audit, Sobelow, and test commands; `npm --prefix assets ci`; `npm --prefix assets run test:e2e`; `MIX_ENV=prod mix assets.deploy`; and `MIX_ENV=prod mix release`. Put store-adapter, command replay, concurrency, worker-protocol, agent-adapter, evidence, preview-adapter, notification, privacy, and failure tests under that gate.
- Reason: The active contract must be reproducible without depending on deployment credentials, while the selected real worker, agent, and preview path still need smoke evidence before release.
- Consequence: Protocol-compatible worker, agent, and preview doubles are required local proof. Live configured worker and coding-agent smoke tests are required before the slice is treated as operationally verified; unavailable credentials or services are recorded as environment blockers rather than skipped. A live preview-provider smoke test is a release gate only when that deployment enables previews.

### Start-Time Processing Boundary Confirmation

- Choice: Show the configured execution location, agent or model provider, preview provider when present, and whether project content leaves the authoritative store before the first start. Require confirmation again only after that disclosed boundary changes.
- Reason: Explicit development start must also be an informed action when source context, specifications, prompts, outputs, or evidence can cross a device, hosting, worker, model, or preview boundary.
- Consequence: The confirmed disclosure version and time are governed personal data. Configuration changes invalidate the prior confirmation without changing readiness or starting work automatically.

### Approved Slice 07 Development Privacy Contract

- Choice: Extend the approved Slice 01 development contract and Slice 05 storage authority across the complete Slice 07 processing inventory.
- Purpose and basis: Process feature content, specifications, participant identity, source context, prompts, agent output, runs, attempts, commands, questions, activity, evidence, previews, reviews, and notifications only as necessary to provide the participant-requested specification and delivery service. Process minimum security records only for the documented service-security purpose and approved legitimate-interest assessment.
- Prohibited uses: Create no Slice 07 product analytics and do not reuse project or personal data for advertising, model training, unrelated product improvement, or another secondary purpose. Aggregate anonymous analytics remain a project-wide future boundary, not an activity introduced by this slice.
- Device and transfer boundary: Device-authoritative records remain in the worker-owned store. The hosted relay retains only approved transient control or presentation data for at most 24 hours and creates no project-data copy. Any configured remote worker, model, artifact, or preview transfer must appear in the confirmed start disclosure and deployment profile.
- Lifecycle: Retain active feature history, normalized activity, minimal run and attempt metadata, accepted evidence, reviews, and necessary historical attribution only while the active project requires them. Do not persist raw provider events. Delete temporary command payloads, checkpoints, provider-thread references, transient logs, and superseded artifacts within 30 days after they are no longer active; notifications within 90 days; operational-security logs within 30 days; and encrypted rolling backups within 35 days. Project deletion removes authoritative active copies and triggers configured preview, artifact, cache, index, and processor cleanup.
- Access and support: Limit project content to current participants and approved worker or provider capabilities. Operations and support access is content-free by default; exceptional access is verified, least-privilege, time-bounded, purpose-limited, and audited.
- Rights: Extend the verified operator workflow to applicable access, correction, export or portability, erasure, restriction, and objection across active and derived copies and configured processors. Preserve identifiable historical attribution only while necessary for project accountability; anonymize it when continued identification is unnecessary.
- Processors and release: Workers, model providers, preview providers, artifact stores, hosting, backups, and support services are processors or recipients only under the actual deployment classification. Implementation and local verification may proceed under this stable contract. Public release remains blocked on actual controller contact, vendors and agreements, regions and transfers, provider retention and training-use settings, notices, incident handling, enforced deletion, any required DPIA or legal review, and final accountable approval.

### No Slice 07 Product Analytics

- Choice: Do not collect feature, workflow, run, worker, model, evidence, review, preview, or notification product analytics in this slice.
- Reason: Analytics is unnecessary to deliver or verify the first product loop and would create another processing purpose and linkability risk across especially sensitive project content.
- Consequence: Verification rejects analytics stores, requests, events, identifiers, and metrics. Necessary operational and security telemetry remains governed personal data under the approved short retention.

## Risks

- An AI readiness label may create false confidence. Keep findings visible and make start authorization explicit.
- A finding may be classified incorrectly and create false readiness or unnecessary blocking. Preserve reviewability, keep blockers visible, and test classification outcomes against the approved product contract.
- Duplicate dispatch or resume can create competing branches or repeated work. Require durable run identity and idempotent transitions.
- Retry or review rejection can accidentally start a competing attempt. Serialize attempt creation, fence stale workers, and keep one current execution lease per run.
- An invalid or stale board action may attempt to bypass the lifecycle. Validate every transition against current feature state, authorization, and gate outcome.
- Agent output may claim success without proof. Derive completion from the approved verification contract and typed evidence.
- An agent or unauthorized participant may attempt to bypass review. Enforce the `Ready for review` boundary and authorized approval at the domain transition.
- Questions may reach the wrong people or expose sensitive content. Restrict assignment actions and targets to authorized project participants and apply the recorded assignee-or-creator routing rule.
- Stale participant state could permit an assignment, notification, action, or content read after access removal. Revalidate the external participant boundary at each protected action and delivery.
- Removal during an active run could orphan responsibility or cancel useful work. Consume the participation handoff idempotently and make the project owner the current controller without restoring former access.
- Screenshots, logs, comments, and preview URLs may expose personal data, source content, or secrets. Apply redaction, access control, retention, and deletion across every copy.
- Preview deployments may create cost or security exposure. Require approved project configuration, isolation, lifecycle limits, and visible non-production status.
- Local and remote workers may disconnect during a run. Preserve durable state at the authoritative project store, use bounded retry and reconciliation, and do not emit terminal failure before the approved recovery budget ends.
- A single large workflow could become unimplementable. Keep the first executable slice constrained and defer provider breadth, production delivery, and general collaboration.

## Open Questions

None.
