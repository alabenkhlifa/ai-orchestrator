# Guided Specification And Delivery Design

## Context

SDD Orchestrator exists to move feature work from requirements to verified implementation while keeping agent behavior, stop conditions, progress, decisions, and proof visible. The current specifications establish repository, identity, storage, and portability boundaries but do not yet define the core product loop.

OpenAI Symphony provides a language-independent orchestration specification and an experimental Elixir reference implementation for isolated workspaces, agent execution, reconciliation, retries, blocked state, and operational visibility. This feature adapts those capabilities to a specification-first workflow controlled from a project board.

## Proposed Approach

Represent each feature as a durable lifecycle record connected to versioned requirements, readiness findings, an approved implementation slice, agent runs, blocking questions, evidence, preview deployments, and notifications. Present the lifecycle through five first-release board columns: `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`. Treat `Blocked` as an additional visible status so an interrupted run keeps its lifecycle position.

Keep requirement guidance and readiness assessment separate from execution authorization. Starting development creates a run against one approved specification revision and isolated branch. The run emits durable progress and evidence events. A blocking product question pauses the run until an authorized answer is written back to the specification, after which the same run resumes. When participation ends, consume the approved handoff by clearing current assignment, routing pending question and review responsibility to the project owner, preserving historical attribution, and leaving the active run under owner control. Successful agent work ends in human review. Authorized approval moves the feature to `Done`; authorized rejection records feedback and returns it to `In development` so work can resume.

Treat required-check results, exact branch and revision identity, applicable screenshots, and preview outcomes as typed evidence rather than unstructured agent claims. Start an authorized preview automatically after successful verification, while keeping preview absence or failure separate from verification success and human review readiness. Deliver action-required and completion notifications in-product in the first release. Build the product-facing lifecycle inside the Phoenix control plane selected by `specs/01-github-project-onboarding/`; keep the worker, run, and Symphony orchestration protocols open until this feature's product requirements are complete.

## Components Affected

- Project feature board and feature detail view.
- External project-participation authorization boundary.
- Guided requirement authoring and readiness assessment.
- Specification revision and approval boundary.
- Agent-run control and status presentation.
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
- `AgentRun`: one authorized attempt to implement one approved revision and slice.
- `BlockingQuestion`: one focused product decision that pauses a run and identifies its intended responders.
- `ActivityEntry`: an ordered user-visible record of progress, comments, questions, answers, evidence, and outcomes.
- `Evidence`: a typed test result, screenshot, branch reference, verification result, or other approved proof.
- `PreviewDeployment`: a non-production branch deployment and its lifecycle.
- `ReviewDecision`: an authorized approval or feedback-based rejection for one completed run.
- `Notification`: an outcome or action-required message for authorized recipients.

Required boundaries:

- Every feature, revision, run, question, evidence item, preview, and notification belongs to one project.
- Only authorized project participants can read project content, start runs, answer questions, or review evidence.
- Current participant identity and authorization come from a separate project-participation boundary. This slice may read and enforce that state but cannot create, invite, grant, revoke, or otherwise mutate participation.
- Current participant presentation consumes the project-specific display name and never exposes another participant's email.
- Assignment, notification delivery, run control, review, and every project-content read revalidate current participation and fail closed when authorization is stale or absent.
- The participation-removal handoff clears current assignment, routes pending question and review responsibility to the immutable project owner, preserves the last accepted project display name as non-interactive historical attribution, and keeps an active run available only under owner control.
- Agents receive the minimum project, repository, specification, and credential capabilities required for the run.
- Worker and provider secrets remain outside agent-readable requirements, comments, evidence, and analytics.
- A run is bound to one immutable starting specification revision; accepted answers create recorded updates and an auditable resume point.
- Every completion claim is bound to one isolated branch, the exact verified revision, and the configured required-check results.
- Screenshots are required only for visual work when the configured environment can capture a meaningful result.
- Preview deployment requires preconfigured project authorization, starts automatically only after successful verification, and cannot determine verification success or human review readiness.
- The first release creates only in-product notifications; external delivery channels remain outside this slice.
- Local and hosted data follow the authoritative storage mode and lifecycle defined by `specs/05-project-storage-lifecycle/`.

## Interfaces

- Board interface: show the five lifecycle columns, creator, optional assignment, readiness, active run, completion outcome, and a visible `Blocked` status on an interrupted feature without moving it to another column. Let an authorized project participant select any authorized participant for `Assigned` or use `Assign to me`. Do not use free dragging to change lifecycle state; expose the gated workflow action available to an authorized user.
- Participant interface: consume current project-participant identity, project display name, authorization, and removal handoff from the separate participation boundary for assignment, notification, run-control, review, content-access, responsibility routing, historical attribution, and active-run control without exposing participant emails or participation-management actions in this slice.
- Specification guidance interface: describe required information, classify visible findings as blocking or non-blocking, and allow only non-blocking suggestions to be dismissed.
- Start interface: remain unavailable while any blocker exists, then authorize one ready feature revision and create one run without duplicate dispatch.
- Worker interface: start, observe, pause, resume, cancel, and recover a run on a configured local or remote worker.
- Agent interface: provide approved scope and receive structured progress, questions, and evidence without exposing unrelated credentials.
- Question interface: pause the run, record one focused question, tag the feature's assigned participant when present or its creator otherwise, and resume only after accepted specification write-back.
- Evidence interface: validate, store, redact, and present configured required-check results, isolated branch and exact revision identity, applicable screenshots, and preview outcomes with run provenance.
- Preview interface: after verification succeeds, automatically request a non-production deployment only through the project's preconfigured authorized path, observe and link success, and expose absence or failure without blocking `Ready for review`.
- Review interface: present the completed run and its evidence in `Ready for review`, accept a decision only from an authorized user, move an approved feature to `Done`, or record rejection feedback and return it to `In development`.
- Notification interface: deliver action-required and completion events in-product without leaking project content to unauthorized recipients.

## Decisions and Tradeoffs

### Fixed First-Release Board

- Choice: Use `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done` as the five first-release columns, with `Blocked` shown as a status rather than a column.
- Reason: The board should communicate the feature's place in the specification and delivery workflow while preserving that context when progress is temporarily blocked.
- Consequence: A blocked development run remains in `In development` and exposes its reason.

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

### Evidence-Based Completion

- Choice: Require the configured project-check results plus isolated branch and exact verified-revision identity for every completion claim. Require screenshots only for visual work in a capable configured environment, and include a preview link only when an authorized preview path succeeds.
- Reason: Users need inspectable proof rather than an unsupported agent completion message.
- Consequence: Missing or failed required checks or missing branch and revision identity prevent successful completion. Conditional evidence stays visibly unavailable rather than being fabricated or treated as universally mandatory.

### Human Review Before Done

- Choice: End successful agent execution in `Ready for review`; allow an authorized reviewer to approve it into `Done` or reject it with feedback back into `In development`.
- Reason: Agent evidence supports a decision but does not replace human acceptance of the requested product outcome.
- Consequence: Agent success, review readiness, resumed development, and accepted completion are distinct states. The review surface must preserve the run, branch, evidence, preview, reviewer identity, decision, and rejection feedback.

### Branch Preview Instead Of Production Deployment

- Choice: After successful verification, automatically start a non-production branch preview only when the project has a preconfigured and authorized preview path.
- Reason: Project-level authorization permits a useful test result without interrupting every run for repeated approval or granting authority to merge or deploy to production.
- Consequence: Preview absence or failure remains visible but does not block an otherwise verified feature from reaching `Ready for review`. Merge, release approval, production deployment, preview lifetime, and cleanup beyond the configured path require later specifications.

### In-Product Notifications Only

- Choice: Deliver blocked, ready-for-review, and failed run notifications only inside the product in the first release.
- Reason: The first workflow needs durable action and outcome visibility without adding external delivery integrations and their separate processor, retry, consent, and content-exposure boundaries.
- Consequence: Email, chat, mobile, and webhook notifications are deferred. Recipient rules remain a product decision, while in-product delivery, retry, deduplication, and minimization remain technical-design work.

### Shared Phoenix Control Plane

- Choice: Reuse the Phoenix/LiveView/PostgreSQL control-plane foundation selected by `specs/01-github-project-onboarding/` and do not import the experimental Symphony prototype as product code.
- Reason: The application framework is a shared project decision, while run supervision, worker transport, evidence, resume, and reconciliation still need feature-specific design.
- Consequence: Board and durable product state remain in the Phoenix control plane. Technical design is still blocked on the orchestration and worker contracts below, not on another framework selection.

## Risks

- An AI readiness label may create false confidence. Keep findings visible and make start authorization explicit.
- A finding may be classified incorrectly and create false readiness or unnecessary blocking. Preserve reviewability, keep blockers visible, and test classification outcomes against the approved product contract.
- Duplicate dispatch or resume can create competing branches or repeated work. Require durable run identity and idempotent transitions.
- An invalid or stale board action may attempt to bypass the lifecycle. Validate every transition against current feature state, authorization, and gate outcome.
- Agent output may claim success without proof. Derive completion from the approved verification contract and typed evidence.
- An agent or unauthorized participant may attempt to bypass review. Enforce the `Ready for review` boundary and authorized approval at the domain transition.
- Questions may reach the wrong people or expose sensitive content. Restrict assignment actions and targets to authorized project participants and apply the recorded assignee-or-creator routing rule.
- Stale participant state could permit an assignment, notification, action, or content read after access removal. Revalidate the external participant boundary at each protected action and delivery.
- Removal during an active run could orphan responsibility or cancel useful work. Consume the participation handoff idempotently and make the project owner the current controller without restoring former access.
- Screenshots, logs, comments, and preview URLs may expose personal data, source content, or secrets. Apply redaction, access control, retention, and deletion across every copy.
- Preview deployments may create cost or security exposure. Require approved project configuration, isolation, lifecycle limits, and visible non-production status.
- Local and remote workers may disconnect during a run. Preserve durable control-plane state and define reconciliation before implementation.
- A single large workflow could become unimplementable. Keep the first executable slice constrained and defer provider breadth, production delivery, and general collaboration.

## Open Questions

- Which durable command, event, and supervision boundary reuses or reimplements Symphony behavior for local and remote agent runs behind the selected Phoenix control plane?
- Which persistent state model and transition protocol make readiness, dispatch, blocking, resume, verification, and completion idempotent and auditable?
- Which worker protocol and trust model support local and remote execution without exposing control-plane or provider credentials?
- How are specification revisions and accepted blocking answers bound to a resumable agent context?
- Which structured event and evidence contracts support configured checks, exact branch and revision identity, applicable screenshots, comments, and preview outcomes?
- How are preview adapters, secrets, isolation, expiration, cleanup, and failure recovery implemented?
- Which in-product notification persistence, delivery, retry, deduplication, read-state, and content-minimization mechanisms satisfy the approved recipient rules?
- Which automated, integration, security, privacy, agent, browser, and live-preview commands form the verification gate?
