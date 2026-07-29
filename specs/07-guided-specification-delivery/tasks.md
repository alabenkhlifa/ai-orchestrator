# Guided Specification And Delivery Tasks

## Status

In Progress

The product, orchestration, privacy, and verification agreements remain approved. Task 7 delivered the protocol and execution-manifest foundation, Task 1 confirmed the three delivered provider contracts, and Task 14 delivered the fail-closed participation guard every later action uses. The readiness path (Tasks 45, 10, 11, 12), the orchestration foundation (Tasks 15, 16, 17, 18, 3), the worker path (Tasks 19, 20, 43), and assignment and comments (Tasks 9, 46) are complete, and Task 13 now starts one run end to end. Task 21 (normalized progress and run-status presentation) is the next executable task. The board's desktop and mobile browser matrix now runs for real against a dev/test-only session bootstrap, so no delivery task carries an environment-blocked browser proof; the live worker and coding-agent smoke proofs remain environment-blocked for their own separate reason. `capability:project-participation-governance` remains unavailable, which affects Task 40 only.

## Active Slice

Deliver one project feature across the `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done` board columns through explicit start, one branch-isolated configured coding-agent run, durable blocking-question resume, bounded retry and cancellation recovery, mandatory verification evidence, an automatic pre-authorized preview when configured, authorized approval or same-run feedback continuation, and in-product action and outcome notifications. Show `Blocked` and `Failed` as statuses without moving the feature to another column.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 1`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 39`.
- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:project-participation-governance` — provider `specs/08-project-participation#Task 5` — required before `Task 40`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 1`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 40`.

Provides:

- `capability:guided-specification-delivery` — ready after `Task 6`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Existing task labels are preserved; newly split tasks use the next unused labels and are listed by dependency order rather than numeric order.

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

- The shared project-storage specification must deliver its authoritative hosted and device adapter boundary before Task 1 and its governance capability before Task 39.
- The focused project-participation specification must deliver current participant identity and authorization, the shared account-level notification foundation, and the versioned `ParticipationRevocation` claim and acknowledgement contract through `capability:project-participation-boundary` before Task 1, with its governance capability required before Task 40.
- The focused project-specification storage specification must deliver stable specification identity, immutable complete revisions, current snapshots, and hosted and device-authoritative persistence through `capability:project-specification-store` before Task 1, with its governance capability required before Task 40.
- Task 7 may establish the provider-independent protocol and manifest codec before the provider capabilities are available. The three operational provider tasks must be complete before Task 1 confirms their consumer contracts and provider-consuming implementation begins; project-storage governance is required before Task 39, while participation and specification governance are required before Task 40.

## Tasks

- [x] Task 7 - Implement the worker protocol and execution-manifest codec.
  - Size: Standard
  - Purpose: Establish the provider-independent versioned command, event, acknowledgement, heartbeat, reconciliation, and immutable execution-manifest shapes.
  - Owned surfaces: Protocol version and capability values, command and normalized-event envelopes, stable IDs, expected state version, attempt number, fence token, sequence, acknowledgement and heartbeat payloads, reconciliation snapshot, immutable execution manifest and digest, configured reference fields, payload limits, deterministic encoding, decoding, and fixtures.
  - Owns: none (protocol foundation)
  - Depends on: none
  - Proof: Focused codec, version, capability, deterministic digest, round-trip, malformed, oversized, unknown-version, missing-field, and secret-field rejection tests pass without project persistence.

- [x] Task 1 - Approve the feature-delivery product, technical, privacy, and verification contracts.
  - Size: Standard
  - Purpose: Confirm the approved feature-delivery contracts against the delivered storage-authority, current-participant, and shared specification-store boundaries before provider-consuming implementation begins.
  - Owned surfaces: Active-slice outcome and scope, delivered capability consumer contracts, participant action and notification rules, lifecycle and state agreement, orchestration and worker contracts, specification write-back and resume contract, evidence and preview contracts, privacy data contract, release gate, task ownership, task sequence, traceability, and canonical verification agreement.
  - Owns: none (agreement gate)
  - Depends on: Task 7
  - Proof: Requirements, design, provider contracts, data boundaries, task ownership, task sequence, traceability, and canonical verification commands have no unresolved active-slice blocker.

- [x] Task 14 - Implement the current-participant authorization guard.
  - Size: Standard
  - Purpose: Give every Slice 07 action and project-content read one fail-closed participant and project-display-name check.
  - Owned surfaces: `capability:project-participation-boundary` consumer, current owner and participant identity, project display name, participant-email non-disclosure, project scoping, stale, removed, left, absent, and cross-project denial, protected action guard, content-existence non-disclosure, and fixtures.
  - Owns: AC-29
  - Depends on: Task 1
  - Proof: Focused owner, participant, stale, removed, left, absent, project-isolation, display-name, email non-disclosure, action, and content-existence tests pass without participation mutation.

- [x] Task 8 - Implement the feature lifecycle domain.
  - Size: Standard
  - Purpose: Establish one durable project-scoped feature with explicit lifecycle and state-version invariants.
  - Owned surfaces: `Feature`, hosted schema and migration, stable project scope, creator reference, optional assigned reference, lifecycle column, visible status field, expected-state version, legal transition table, stale-state rejection, constraints, fixtures, and device-adapter value shape.
  - Owns: entity:Feature
  - Depends on: Task 14
  - Proof: Focused migration, changeset, constraint, lifecycle value, legal and illegal transition, stale version, project isolation, device-shape, and rollback tests pass.

- [x] Task 2 - Deliver the feature lifecycle board.
  - Size: Standard
  - Purpose: Make the fixed lifecycle and gated movement durable and understandable before agent execution.
  - Owned surfaces: Project-scoped board and feature-detail LiveViews, five fixed columns, lifecycle card grouping, creator and assignment display seam, no-drag behavior, gated action presentation, generic status seam for later blocked and failed states, empty and populated states, fixtures, and responsive accessibility behavior.
  - Owns: AC-01, AC-03
  - Depends on: Task 8
  - Proof: Focused query, authorization, LiveView, desktop, and mobile browser tests cover five columns, empty and populated boards, direct and drag rejection, cross-project isolation, creator labels, keyboard, and focus.

- [x] Task 9 - Deliver project-participant assignment and responsibility.
  - Size: Standard
  - Purpose: Keep current story responsibility explicit without exposing participant email.
  - Owned surfaces: Creator and optional `Assigned` presentation, current-participant selector, assignment to another current participant, `Assign to me`, responsible-participant resolution, creator and owner fallback, project display names, stale target rejection, assignment activity, fixtures, and responsive accessible controls.
  - Owns: AC-07, AC-08, AC-31
  - Depends on: Task 2
  - Proof: Focused domain, authorization, participant-selector, stale-target, assignment, self-assignment, fallback, display-name, email non-disclosure, activity, and browser tests pass.

- [x] Task 45 - Implement the configured readiness-guidance adapter.
  - Size: Standard
  - Purpose: Ask one configured model boundary for structured missing, ambiguous, conflicting, blocking, and non-blocking findings without allowing it to mutate requirements.
  - Owned surfaces: Readiness-guidance behaviour, configured provider and model reference, minimum specification and feature input projection, structured finding schema, blocking classification, explanation field, versioned response, timeout and failure result, prompt and output limits, secret and participant-email exclusion, no automatic write-back, fixtures, and deterministic adapter double.
  - Owns: none (readiness adapter)
  - Depends on: Task 2, Task 14
  - Proof: Focused adapter, schema, blocking and non-blocking classification, missing, ambiguous, conflicting, timeout, malformed, oversized, secret, email, no-write-back, and deterministic-double tests pass.

- [x] Task 10 - Deliver guided requirements and blocking readiness.
  - Size: Standard
  - Purpose: Explain required product information and keep unresolved blockers visible.
  - Owned surfaces: `ReadinessAssessment`, shared `ProjectSpecification` and `SpecificationRevision` consumer, exact revision binding, guided requirement structure, blocking and non-blocking finding schema, understandable finding explanations, current assessment replacement, visible blocker list, blocker non-dismissal, start-disabled result, fixtures, and feature-detail presentation without duplicate specification persistence.
  - Owns: AC-09, AC-10, AC-11, entity:ReadinessAssessment
  - Depends on: Task 45
  - Proof: Focused specification-store contract, assessment, classification, revision, blocker, non-dismissal, stale-head, authorization, presentation, and no-duplicate-store tests pass.

- [x] Task 11 - Deliver suggestion dismissal and development readiness.
  - Size: Standard
  - Purpose: Let authorized users dismiss only non-blocking suggestions and expose readiness when every blocker is resolved.
  - Owned surfaces: Non-blocking suggestion dismissal, blocking-classification revalidation, assessment version check, ready-state transition, `Start development` availability, dismissal activity, unauthorized and stale denial, fixtures, and LiveView result.
  - Owns: AC-04, AC-12, AC-13
  - Depends on: Task 10
  - Proof: Focused suggestion, blocker, readiness, concurrency, stale-version, authorization, activity, and LiveView tests pass without automatically starting execution.

- [x] Task 12 - Deliver start-time processing-boundary disclosure.
  - Size: Standard
  - Purpose: Make execution, provider, preview, and data-transfer boundaries visible before consequential processing starts.
  - Owned surfaces: Configured execution location, agent or model provider, preview provider, authoritative-store transfer summary, disclosure version and digest, first-start confirmation, unchanged-boundary reuse, changed-boundary invalidation and reconfirmation, confirmation time, fixtures, and accessible start dialog.
  - Owns: AC-36
  - Depends on: Task 11, Task 14
  - Proof: Focused configuration, version, digest, first, unchanged, changed, transfer-summary, authorization, and desktop and mobile dialog tests pass.

- [x] Task 15 - Implement hosted run and attempt persistence.
  - Size: Standard
  - Purpose: Establish one branch-preserving run with ordered exclusive attempts in hosted authoritative storage.
  - Owned surfaces: `AgentRun`, `RunAttempt`, hosted migrations and schemas, project and feature scope, initiator, starting and effective revision references, isolated branch identity, lifecycle and status, ordered attempt number, one-current-attempt uniqueness, execution-manifest digest, lease and fence fields, expected-state version, constraints, and fixtures.
  - Owns: entity:AgentRun, entity:RunAttempt
  - Depends on: Task 1
  - Proof: Focused migration, changeset, constraint, ordering, exclusivity, revision, branch, lease, fence, project-isolation, and rollback tests pass.

- [x] Task 16 - Implement the hosted durable command outbox and dispatcher.
  - Size: Standard
  - Purpose: Persist and claim worker instructions without relying on OTP process memory.
  - Owned surfaces: `RunCommand`, hosted migration and schema, stable command ID, operation, expected state version, manifest digest, due time, delivery and acknowledgement state, result replay, transaction contribution, PostgreSQL locking and lease claim, supervised dispatcher, restart recovery, and fixtures.
  - Owns: entity:RunCommand
  - Depends on: Task 15
  - Proof: Focused transaction, claim, lock, lease, stable-ID, duplicate, acknowledgement, replay, restart, concurrency, and rollback tests pass.

- [x] Task 17 - Implement ordered feature activity.
  - Size: Standard
  - Purpose: Preserve user-visible comments, progress, questions, answers, evidence references, and outcomes in authoritative order.
  - Owned surfaces: `ActivityEntry`, hosted migration and schema, project, feature, run, attempt, actor, type, occurrence order, minimized normalized payload, append transaction contribution, immutable history, pagination seam, authorization, fixtures, and no raw provider-event field.
  - Owns: entity:ActivityEntry
  - Depends on: Task 15
  - Proof: Focused migration, ordering, immutability, actor, type, transaction, authorization, pagination, payload-minimization, raw-event absence, and concurrency tests pass.

- [x] Task 46 - Deliver participant feature comments.
  - Size: Standard
  - Purpose: Let current participants add one authorized project-scoped comment to ordered feature activity.
  - Owned surfaces: Comment action, current-participant revalidation, project and feature scope, display-name attribution, comment content limits and redaction, one transactionally appended `ActivityEntry`, duplicate-submission protection, stale and removed denial, participant-email non-disclosure, fixtures, and responsive accessible comment form.
  - Owns: AC-42
  - Depends on: Task 14, Task 17
  - Proof: Focused authorization, project isolation, display-name, email non-disclosure, content limit, redaction, duplicate, ordering, stale and removed denial, LiveView, desktop, and mobile tests pass.

- [x] Task 18 - Implement the device-authoritative delivery-store adapter.
  - Size: Standard
  - Purpose: Provide equivalent feature, run, attempt, command, and activity transactions without a hosted device-project copy.
  - Owned surfaces: Shared delivery-store behaviour, hosted adapter conformance, worker-owned device persistence, state transition and activity plus command transaction, serialized command claim, attempt lease and fence, expected-version enforcement, restart behavior, protocol value shapes, fixtures, and negative hosted-copy enforcement.
  - Owns: none (device adapter)
  - Depends on: Task 16, Task 17
  - Proof: Focused shared-contract, device persistence, transaction, claim, restart, concurrency, idempotency, failure, isolation, and no-hosted-copy tests prove parity with the hosted adapter.

- [x] Task 3 - Implement authoritative run-state transactions.
  - Size: Standard
  - Purpose: Apply one validated run transition, activity append, and resulting command atomically in either authoritative storage adapter.
  - Owned surfaces: Shared run-transition service, expected feature and run state versions, legal run and attempt transitions, atomic feature and run update, ordered `ActivityEntry` append, optional `RunCommand` insertion, hosted `Ecto.Multi` contribution, device transaction contribution, idempotent operation key, rollback, fixtures, and adapter-contract tests.
  - Owns: none (transaction invariant)
  - Depends on: Task 15, Task 16, Task 17, Task 18
  - Proof: Focused hosted and device transition, expected-version, activity ordering, command insertion, idempotency, concurrency, injected failure, rollback, and no-partial-state tests pass.

- [x] Task 19 - Implement the authenticated worker gateway.
  - Size: Standard
  - Purpose: Deliver versioned commands and receive normalized worker state through a worker-initiated channel.
  - Owned surfaces: Outbound Phoenix Channel topic, workspace or execution-target authentication, capability negotiation, command delivery, acknowledgement, heartbeat, normalized-event and reconciliation-snapshot intake, connection state, incompatible-version denial, cross-workspace denial, reconnect seam, fixtures, and worker double.
  - Owns: none (worker gateway)
  - Depends on: Task 7, Task 16
  - Proof: Focused channel, authentication, capability, delivery, acknowledgement, heartbeat, reconnect, incompatible, stale, cross-workspace, and worker-double tests pass.

- [x] Task 20 - Implement worker workspace and branch isolation.
  - Size: Standard
  - Purpose: Ensure one run executes only inside its normalized workspace and isolated branch.
  - Owned surfaces: Workspace-root configuration, normalized run path, traversal denial, exact process working directory, isolated branch creation and reuse, base revision validation, target-branch stability, one-current-process lock, cancellation stop seam, repository content boundary, fixtures, and worker-side tests.
  - Owns: none (worker isolation)
  - Depends on: Task 7, Task 19
  - Proof: Focused workspace, traversal, symlink, working-directory, branch, base-revision, process-lock, stale-process, cancellation-seam, and repository fixture tests pass.

- [x] Task 43 - Implement the configured coding-agent adapter.
  - Size: Standard
  - Purpose: Launch and observe one configured agent without passing worker, repository, or unrelated provider credentials into agent input.
  - Owned surfaces: Agent-adapter behaviour, installed protocol version, configured executable and model reference, manifest input projection, worker-side provider and repository secret resolution, minimized environment, process launch and observation, compatible provider-thread create or resume, normalized progress and terminal events, secret stripping, fixtures, and deterministic agent double.
  - Owns: none (agent adapter)
  - Depends on: Task 20
  - Proof: Focused adapter, version, launch, resume, new-thread fallback, environment allowlist, secret non-propagation, event normalization, process failure, and agent-double tests pass.

- [x] Task 13 - Deliver explicit development start.
  - Size: Standard
  - Purpose: Create one authorized run, activity entry, and start command for the exact ready revision without duplicate dispatch.
  - Owned surfaces: Current readiness and disclosure confirmation revalidation, any-current-participant start authorization, immutable starting revision and approved slice binding, hosted and device start transaction, new stable run and branch identity, initial attempt, start activity, command outbox insertion, duplicate-start rejection, feature transition to `In development`, fixtures, and start result.
  - Owns: AC-14, AC-15
  - Depends on: Task 3, Task 9, Task 12, Task 43
  - Proof: Focused hosted and device transaction, authorization, revision, disclosure, duplicate, concurrency, branch, command, activity, rollback, and no-automatic-start tests pass.

- [x] Task 21 - Deliver normalized progress and run-status presentation.
  - Size: Standard
  - Purpose: Convert approved worker progress into durable activity and visible lifecycle status.
  - Owned surfaces: Normalized progress event validation, current fence and sequence check, idempotent activity append, run progress state, visible `In development`, `Blocked`, and `Failed` status seam, raw-provider-event exclusion, redaction, feature-detail activity stream, fixtures, and responsive status UI.
  - Owns: AC-16
  - Depends on: Task 3, Task 13, Task 17, Task 19
  - Proof: Focused valid, duplicate, stale-fence, out-of-order, oversized, unauthorized, redacted, raw-provider-event, activity, status, and LiveView tests pass.

- [x] Task 22 - Deliver durable blocked-run and question state.
  - Size: Standard
  - Purpose: Pause one current attempt on one focused product question while preserving accepted work.
  - Owned surfaces: `BlockingQuestion`, hosted schema and migration, device-adapter value shape, question text and context limits, run, attempt, branch, workspace, checkpoint and pending state, atomic blocked transition and activity, no blocked column, one-open-question invariant, visible reason, fixtures, and blocked UI.
  - Owns: AC-02, AC-17, entity:BlockingQuestion
  - Depends on: Task 21
  - Proof: Focused migration, blocked transition, checkpoint, one-question, duplicate, stale-event, branch and workspace preservation, status, activity, and browser tests pass.

- [x] Task 23 - Route blocking-question responsibility.
  - Size: Standard
  - Purpose: Tag the current assigned participant or creator with owner fallback when responsibility is stale.
  - Owned surfaces: Assigned-first and creator fallback resolution, current-participant revalidation, owner fallback, responder set, project display-name presentation, participant-email non-disclosure, stale and former-participant denial, question activity tags, fixtures, and UI presentation.
  - Owns: AC-05, AC-06
  - Depends on: Task 9, Task 22
  - Proof: Focused assigned, unassigned, creator, stale assigned, stale creator, owner fallback, responder authorization, display-name, email non-disclosure, and browser tests pass.

- [x] Task 24 - Deliver accepted-answer specification write-back and resume.
  - Size: Standard
  - Purpose: Record the accepted product decision in the shared specification before the same run continues.
  - Owned surfaces: Authorized responder action, accepted answer, expected-head `SpecificationStore` append, immutable resulting revision, question-resolution link, effective revision and manifest update, continuation checkpoint, next attempt and resume command transaction, same run, branch and workspace preservation, provider-thread-independent reconstruction, activity, fixtures, and conflict result.
  - Owns: AC-18
  - Depends on: Task 10, Task 22, Task 23
  - Proof: Focused authorization, expected-head, revision, transaction, rollback, same-run, branch, workspace, checkpoint, new-thread reconstruction, duplicate answer, stale question, activity, and resume tests pass.

- [x] Task 25 - Deliver bounded automatic and manual retry.
  - Size: Standard
  - Purpose: Recover transient failures on the same run and workspace without indefinite cost or duplicate attempts.
  - Owned surfaces: Explicit retry classification, three automatic retries after the initial attempt, jittered exponential backoff from 15 seconds with five-minute cap, same worker, workspace and branch, ordered next attempt, checkpoint and evidence preservation, terminal `Failed` transition and reason, post-terminal notification event, any-current-participant manual retry, duplicate prevention, fixtures, and failed-status UI.
  - Owns: AC-34
  - Depends on: Task 21, Task 24
  - Proof: Focused classification, timing, retry budget, same-worker, same-workspace, attempt ordering, checkpoint, terminal state, manual authorization, duplicate, concurrency, activity, and status UI tests pass.

- [x] Task 26 - Deliver authorized cancellation and restart readiness.
  - Size: Standard
  - Purpose: Make cancellation terminal while preserving governed history and requiring a new run for later development.
  - Owned surfaces: Current initiator and owner authorization, other and former-participant denial, cancel command, worker stop acknowledgement seam, terminal canceled state, activity and evidence preservation, current-revision readiness reevaluation, `Ready for development` or `Draft` transition, no resume, later new-run and new-branch requirement, fixtures, and cancellation UI.
  - Owns: AC-32, AC-33
  - Depends on: Task 11, Task 13, Task 25
  - Proof: Focused initiator, owner, other, former, cancel command, repeat, worker response, history, readiness outcomes, no-resume, new-run, new-branch, and browser tests pass.

- [x] Task 27 - Consume participation revocation.
  - Size: Standard
  - Purpose: End former-participant responsibility and access without canceling active work.
  - Owned surfaces: Versioned `ParticipationRevocation` claim, payload validation, idempotent authoritative transaction, current assignment clearing, pending question and review owner fallback, last display-name historical attribution, active-run owner control, former-participant denial, acknowledgement after commit, replay, fixtures, and absence of participation mutation.
  - Owns: AC-30
  - Depends on: Task 9, Task 22, Task 26
  - Proof: Focused removal and leave, assignment, question, review, active run, historical label, owner control, former denial, transaction, replay, acknowledgement, rollback, and negative participation-mutation tests pass.

- [x] Task 28 - Reconcile authoritative state and worker execution.
  - Size: Standard
  - Purpose: Recover after process, channel, or worker restart without accepting stale work or starting a competing attempt.
  - Owned surfaces: Authoritative command, attempt, lease, fence, branch, workspace, process, and last-sequence comparison, reconnect snapshot handling, live-current continuation, stale-process fencing and stop, expired-lease handling, next bounded retry scheduling, same-worker enforcement, hosted and device adapter integration, fixtures, and reconciliation activity.
  - Owns: none (recovery invariant)
  - Depends on: Task 3, Task 18, Task 20, Task 25, Task 26, Task 27
  - Proof: Focused control-plane restart, worker restart, disconnect, live process, stale process, expired lease, fence, sequence, retry scheduling, same-worker, hosted, device, and no-competing-attempt tests pass.

- [ ] Task 4 - Collect normalized required-check evidence.
  - Size: Standard
  - Purpose: Accept only worker-derived typed proof and preserve each evidence item immutably.
  - Owned surfaces: `Evidence`, hosted schema and migration, device-adapter value shape, versioned evidence event payload, schema and limit validation, worker command and exit provenance, run, attempt, command, branch, commit, source, time, duration, digest, applicability and redaction provenance, immutable supersession link, raw-provider-event and agent-prose denial, fixtures, and ingestion transaction.
  - Owns: entity:Evidence
  - Depends on: Task 21, Task 28
  - Proof: Focused migration, event schema, valid, invalid, stale, duplicate, out-of-order, oversized, unauthorized, worker-derived, agent-prose denial, immutability, supersession, hosted, and device tests pass.

- [ ] Task 29 - Implement private evidence-artifact storage.
  - Size: Standard
  - Purpose: Store screenshots and larger approved proof privately through the authoritative project-storage boundary.
  - Owned surfaces: Private artifact-store behaviour, hosted and device adapters, project and evidence authorization, content type, byte-size and digest limits, encrypted or protected storage reference, redaction state, no public URL, no embedded credential, retrieval and deletion seam, fixtures, and deterministic adapter double.
  - Owns: none (artifact adapter)
  - Depends on: Task 4
  - Proof: Focused adapter-contract, authorization, content type, size, digest, storage, retrieval, deletion, public-link denial, credential scan, hosted, and device tests pass.

- [ ] Task 44 - Deliver conditional screenshot evidence.
  - Size: Standard
  - Purpose: Capture meaningful visual proof when supported and report inapplicability without fabricating evidence.
  - Owned surfaces: Visual-result applicability decision, configured capture capability, worker screenshot command result, exact attempt, branch and commit binding, private artifact handoff, redaction state, unsupported and inapplicable result, capture failure, fixtures, and presentation metadata.
  - Owns: AC-20
  - Depends on: Task 29, Task 43
  - Proof: Focused visual and non-visual work, supported, unsupported, inapplicable, failed capture, same-commit, artifact, redaction, and no-invented-evidence tests pass.

- [ ] Task 30 - Enforce same-commit verification completion.
  - Size: Standard
  - Purpose: Permit a successful claim only when every configured required check proves the exact commit offered for review.
  - Owned surfaces: Required-check contract snapshot, complete result set, exact branch, revision and commit binding, passed, failed, missing and superseded evaluation, commit-change invalidation, screenshot applicability integration, success-claim gate, verified completion event, fixtures, and failure reason.
  - Owns: AC-19
  - Depends on: Task 4, Task 44
  - Proof: Focused complete, failed, missing, wrong-branch, wrong-revision, wrong-commit, later-commit, superseded, conditional screenshot, duplicate, and false-success tests pass.

- [ ] Task 31 - Present verification evidence in feature activity.
  - Size: Standard
  - Purpose: Let authorized participants inspect required checks, screenshots, provenance, failures, and superseded proof.
  - Owned surfaces: Evidence activity entries, typed check and screenshot presentation, attempt, branch, commit, source, time, duration, digest and redaction metadata, passed, failed, missing, unsupported and superseded states, private artifact authorization, fixtures, and responsive accessible evidence UI.
  - Owns: AC-40
  - Depends on: Task 17, Task 30
  - Proof: Focused query, authorization, typed state, provenance, failure, missing, unsupported, supersession, private artifact, desktop, mobile, keyboard, and focus tests pass.

- [ ] Task 5 - Deliver the ready-for-review handoff.
  - Size: Standard
  - Purpose: Move verified work to human review without allowing the agent to complete the feature.
  - Owned surfaces: Verified-completion consumption, `Ready for review` transition, agent-to-`Done` denial, current responsible participant and owner review responsibility, review-ready activity, preview-independent readiness, fixtures, and feature-detail state.
  - Owns: AC-23
  - Depends on: Task 30, Task 31
  - Proof: Focused verified, unverified, agent-denial, preview absent, preview failed, responsibility, transition, activity, and LiveView tests pass.

- [ ] Task 32 - Implement the configured preview adapter and deployment lifecycle.
  - Size: Standard
  - Purpose: Start one authorized non-production preview for the exact verified commit without making it verification truth.
  - Owned surfaces: `PreviewDeployment`, hosted schema and migration, device-adapter value shape, configured preview-adapter behaviour, path and provider-reference authorization, external credential isolation, idempotent request, run, attempt, branch and verified-commit binding, status, timeout, expiry, supersession, cleanup command seam, safe link, fixtures, and adapter double.
  - Owns: AC-21, entity:PreviewDeployment
  - Depends on: Task 30
  - Proof: Focused migration, adapter, authorization, idempotency, exact commit, success, timeout, expiry, supersession, cleanup command, credential absence, safe link, hosted, and device tests pass.

- [ ] Task 33 - Present preview availability and failure.
  - Size: Standard
  - Purpose: Show non-production preview status without blocking review readiness or inventing a link.
  - Owned surfaces: Preview unavailable, pending, ready, failed, timed-out, expired and superseded presentation, non-production label, safe-link authorization, failure reason, configured expiry and cleanup state, feature activity, fixtures, and responsive accessible UI.
  - Owns: AC-22
  - Depends on: Task 32
  - Proof: Focused no-path, pending, success, provider failure, timeout, expiry, supersession, safe-link, unauthorized-link, review-readiness independence, desktop, and mobile tests pass.

- [ ] Task 34 - Deliver authorized review approval and rejection.
  - Size: Standard
  - Purpose: Reserve the final product decision for the current responsible participant or project owner.
  - Owned surfaces: `ReviewDecision`, hosted schema and migration, device-adapter value shape, review surface, current responsible participant and owner authorization, other-participant and agent denial, approval record and `Done` transition, rejection record and required feedback, reviewer identity, evidence and preview references, fixtures, and responsive accessible UI.
  - Owns: AC-24, AC-25, entity:ReviewDecision
  - Depends on: Task 5, Task 31
  - Proof: Focused migration, responsible, owner, other, agent, stale participant, approval, `Done`, rejection feedback requirement, evidence presentation, hosted, device, and browser tests pass.

- [ ] Task 35 - Continue rejected work on the same run and branch.
  - Size: Standard
  - Purpose: Preserve review feedback and prior proof while starting one new attempt in `In development`.
  - Owned surfaces: Rejection-feedback activity, `In development` transition, same run, branch and workspace, next ordered attempt, continuation manifest and command, prior evidence and review preservation, contradictory-product-feedback block for specification write-back, idempotency, fixtures, and resumed-development status.
  - Owns: AC-26, AC-35
  - Depends on: Task 24, Task 34
  - Proof: Focused same-run, branch, workspace, ordered attempt, feedback, prior evidence, prior review, contradictory agreement, duplicate, rollback, command, activity, and status tests pass.

- [ ] Task 36 - Project run events into minimized notifications.
  - Size: Standard
  - Purpose: Deliver blocked, review-ready, and terminal-failed events to the smallest current authorized recipient set.
  - Owned surfaces: Slice 07 `Notification` event types extending `AccountNotification`, at-least-once lifecycle-event consumption, blocked, review-ready and failed recipient matrices, delivery-time current-participation checks, role deduplication, unique event-type, run-state-version and recipient key, minimized body, event time, one safe feature link, replay and restart behavior, fixtures, and no external channel.
  - Owns: AC-27, entity:Notification
  - Depends on: Task 5, Task 22, Task 25, Task 35
  - Proof: Focused projector, blocked, review-ready, failed, stale recipient, duplicate role, replay, restart, minimized body, safe link, and negative external-channel tests pass.

- [ ] Task 37 - Deliver durable notification list and read behavior.
  - Size: Standard
  - Purpose: Keep unread action state durable while denying removed participants on every read and link open.
  - Owned surfaces: Project-authorized notification list, unread state, idempotent mark-read, PubSub presentation hint, disconnected-browser and restart delivery, read-time current-participation check, safe-link open authorization, removed-participant denial, fixtures, and responsive accessible notification UI.
  - Owns: AC-41
  - Depends on: Task 36
  - Proof: Focused list, unread, mark-read, replay, no-PubSub, restart, current and removed participant, safe-link, cross-project, desktop, mobile, keyboard, and focus tests pass.

- [ ] Task 38 - Enforce the Slice 07 processing and access contract.
  - Size: Standard
  - Purpose: Limit feature-delivery data to the approved service and security purposes and authorized recipients.
  - Owned surfaces: `DataProcessingRecord`, complete processing inventory and field-purpose map, contract-necessity and security legitimate-interest basis, current-participant project access, cross-project isolation, content-free default support, verified least-privilege time-bounded audited elevation, credential and project-content redaction, audit minimization, fixtures, and no raw-provider-event persistence.
  - Owns: AC-28, entity:DataProcessingRecord
  - Depends on: Task 14, Task 31, Task 33, Task 35, Task 37, Task 46
  - Proof: Focused inventory, purpose and basis, current and removed access, cross-project isolation, support elevation, credential, project-content, raw-event, and audit-minimization tests pass.

- [ ] Task 39 - Enforce temporary execution-data retention.
  - Size: Standard
  - Status: Blocked until `capability:project-storage-governance` and preceding implementation tasks are complete.
  - Purpose: Remove inactive execution mechanics after their short recovery and diagnostic purpose ends.
  - Owned surfaces: `capability:project-storage-governance` consumer, 30-day temporary command payload, checkpoint, provider-thread reference, transient-log and superseded-artifact cleanup, active run and accepted-evidence preservation, retention-pruner rules, idempotency, lock, restart, reconciliation, and fixtures.
  - Owns: AC-37
  - Depends on: Task 28, Task 29, Task 38
  - Proof: Focused 30-day boundary, command, checkpoint, provider-thread, transient-log, superseded-artifact, active-run, accepted-evidence, idempotency, lock, restart, and reconciliation tests pass.

- [ ] Task 47 - Enforce Slice 07 notification retention.
  - Size: Standard
  - Purpose: Remove in-product delivery records after their approved lifetime without changing workflow state.
  - Owned surfaces: 90-day Slice 07 `AccountNotification` cleanup rule, read and unread selection, feature, run and participant authorization non-mutation, idempotent pruning, lock, restart, reconciliation, and fixtures.
  - Owns: AC-43
  - Depends on: Task 37, Task 38
  - Proof: Focused 90-day boundary, read, unread, feature, run, participant, idempotency, lock, restart, and reconciliation tests pass.

- [ ] Task 48 - Enforce device relay and cache cleanup.
  - Size: Standard
  - Purpose: Keep device-authoritative project data from becoming a durable hosted copy.
  - Owned surfaces: 24-hour hosted relay and cache cleanup rules, device-authoritative selection, active transport allowance, durable-copy denial, cache and relay reconciliation, idempotency, restart, fixtures, and negative hosted-storage scan.
  - Owns: AC-44
  - Depends on: Task 18, Task 38
  - Proof: Focused 24-hour boundary, active transport, relay, cache, durable-copy absence, idempotency, restart, reconciliation, and hosted-storage tests pass.

- [ ] Task 49 - Enforce minimized Slice 07 security logs.
  - Size: Standard
  - Purpose: Retain only short-lived security evidence without raw credentials or unauthorized project content.
  - Owned surfaces: Fixed structured security-log fields, non-secret correlation identifier, feature, run, worker and provider event minimization, credential and project-content redaction, 30-day expiry rule, audit minimization, diagnostic scans, and fixtures.
  - Owns: AC-45
  - Depends on: Task 38, Task 39
  - Proof: Focused structured-log, field allowlist, correlation, credential, project-content, failure-path, 30-day expiry, audit-minimization, and diagnostic tests pass.

- [ ] Task 50 - Enforce encrypted-backup expiry.
  - Size: Standard
  - Purpose: Bound recovery copies without allowing deleted project access to return.
  - Owned surfaces: 35-day encrypted rolling-backup expiry configuration, approved recovery-only boundary, deletion tombstone handling, `DeploymentPrivacyProfile` backup evidence seam, reconciliation, fixtures, and release-gate classification.
  - Owns: AC-46
  - Depends on: Task 38, Task 39
  - Proof: Focused 35-day boundary, recovery authorization, deletion tombstone, no-restored-access, reconciliation, deployment-profile seam, and release-gate checks pass.

- [ ] Task 51 - Enforce project deletion and external cleanup reconciliation.
  - Size: Standard
  - Purpose: End access and remove active authoritative and configured external copies while making cleanup failures recoverable but inaccessible.
  - Owned surfaces: Immediate access revocation, hosted and device authoritative deletion, preview, artifact, cache, index and processor cleanup requests, acknowledgement and failure state, restricted reconciliation record, retry, no restored access, fixtures, and project-deletion activity.
  - Owns: AC-47
  - Depends on: Task 29, Task 32, Task 39, Task 47, Task 48, Task 49, Task 50
  - Proof: Focused hosted and device deletion, immediate denial, preview, artifact, cache, index, processor, acknowledgement, failure, retry, reconciliation, activity, and no-restored-access tests pass.

- [ ] Task 40 - Enforce verified rights and historical anonymization.
  - Size: Standard
  - Status: Blocked until the participation and specification governance capabilities and Task 51 are complete.
  - Purpose: Apply verified rights across authoritative and derived delivery records without exposing another participant or erasing necessary accountability.
  - Owned surfaces: `capability:project-participation-governance` and `capability:project-specification-governance` consumers, verified access, correction, export or portability, erasure, restriction and objection, hosted and device records, artifacts, notifications, caches, logs, backups, processors, historical-attribution necessity review, last-label anonymization, stable project accountability, fixtures, and authorization.
  - Owns: AC-38
  - Depends on: Task 27, Task 38, Task 51
  - Proof: Focused rights, authorization, hosted, device, artifact, notification, cache, log, backup, processor, historical necessity, anonymization, stable history, and cross-participant isolation tests pass.

- [ ] Task 41 - Prohibit product analytics and secondary use.
  - Size: Standard
  - Purpose: Keep feature, run, worker, evidence, preview, review, and notification data out of analytics, training, and unrelated processing.
  - Owned surfaces: No product analytics store, request, event, identifier, or metric, no advertising, model-training reuse, unrelated improvement, or secondary use, raw credential exclusion, worker, model and preview content-routing checks, device-authoritative durable-copy denial, operational telemetry classification, browser-network checks, fixtures, and negative scans.
  - Owns: AC-39
  - Depends on: Task 38, Task 39, Task 40
  - Proof: Focused analytics-store, browser-network, telemetry, metric, identifier, advertising, training, secondary-use, credential, provider-routing, and durable-device-copy checks pass.

- [ ] Task 42 - Record deployment processor and transfer controls.
  - Size: Standard
  - Purpose: Keep locally provable processing configuration separate from deployment-specific release evidence.
  - Owned surfaces: `DeploymentPrivacyProfile`, worker, model, preview, artifact, hosting, backup and support processor classifications, regions, transfer safeguards, provider retention and training-use settings, controller and notice fields, incident and support procedure, deletion enforcement, DPIA or legal review state, start-disclosure linkage, release-gate validation, and fixtures.
  - Owns: entity:DeploymentPrivacyProfile
  - Depends on: Task 12, Task 33, Task 38, Task 41
  - Proof: Focused profile schema, processor, region, transfer, provider-use, disclosure-link, release-gate, missing-deployment-evidence, and configuration validation tests pass without treating local controls as legal approval.

- [ ] Task 6 - Complete the feature-delivery privacy and security review.
  - Size: Standard
  - Status: Blocked until the preceding delivery, privacy, lifecycle, and governance tasks are complete.
  - Purpose: Confirm the complete board, orchestration, worker, evidence, preview, review, and notification flow follows the approved contract before publishing readiness.
  - Owned surfaces: Consolidated processing inventory, access, lifecycle, rights, processor, transfer, disclosure, support, redaction, audit, no-analytics, secondary-use and device-copy review, release-gate classification, required privacy and security approval, and `capability:guided-specification-delivery` readiness write-back.
  - Owns: none (governance gate)
  - Depends on: Task 5, Task 37, Task 40, Task 41, Task 42, Task 51
  - Proof: Focused cross-task privacy, security, lifecycle, rights, processor, transfer, disclosure, redaction, support, audit, no-analytics, device-copy, and required-review checks pass before capability readiness is recorded.

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

- No agreement decision remains unresolved. Task 7 is immediately executable. Task 1 is blocked until the storage-authority, participation-boundary, and specification-store capabilities are delivered by their named provider tasks; Task 39 additionally requires project-storage governance, and Task 40 requires participation and specification governance.

## Release Gate

- Deployment-specific controller details, worker, model, preview, and infrastructure processors, regions, transfer safeguards, notices, incident handling, and enforced retention evidence.
- Deployment-specific provider retention and model-training-use settings, processor agreements, support-access procedure, deletion propagation, and any required DPIA evidence.
- Live configured preview-provider request, access, status, expiry, and cleanup smoke proof when previews are enabled for the deployment.
- Final accountable privacy or legal review for the configured deployment and its subprocessors.

## Progress Log

### 2026-07-29 - Task 28 complete: authoritative state and worker execution reconciled

- Completed: Added `Delivery.Reconciliation`. A worker's snapshot is compared against authoritative state — current attempt, fence, lease, branch, workspace, and last observed sequence — and resolves to exactly one typed decision, so each outcome is testable in isolation rather than inferred from side effects.
- The four outcomes: `continue` when the worker's process really is the current attempt; `fence_stale_worker` when it reports an attempt that is no longer current, which tells it to stop and changes nothing authoritative; `schedule_retry` when the lease expired with no live process and budget remains, superseding the attempt and scheduling the next bounded retry on the same run, branch, and worker; and `terminal` when the budget is exhausted, which fails the run visibly and enqueues nothing.
- Boundary held: A stale fence changes nothing — run, attempt, feature, activity, and command were each asserted unchanged. No path can create a competing attempt: any commit that creates one ends the existing current attempt in the same transaction, which the one-current-attempt index would reject otherwise. Recovery stays same-worker; cross-worker migration remains deferred.
- Restart path: `recover/2` returns expired command claims to the queue, because nothing in process memory is authoritative — a dispatcher that died mid-delivery leaves rows only the database can hand back.
- Reuse rather than restatement: The retry budget and jittered backoff come from `Retry`, so reconciliation and the failure path cannot disagree about how long to wait or how many times to try.
- Failed checks: A control-plane restart test initially failed on both authorities and was resolved before completion. Final proof passes with real exit status: the reconciliation suite across both hosted and device authorities, `mix test` (1678 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 4 (normalized required-check evidence) is next, then 29, 44, and 30. After Task 30 the graph widens and Tasks 31 and 32 become independent.
- Spec updates: Marked Task 28 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 27 complete: participation revocation consumed

- Completed: Added `Delivery.RevocationConsumer`. It claims the versioned `ParticipationRevocation` handoffs Slice 08 produces, applies each one to this slice's own records, and acknowledges only after that transaction commits.
- Boundary held (AC-30): This slice mutates no participation record — the negative proof compares the participation rows before and after the handoff. It consumes the producer contract through `Participation.Boundary` and owns only the feature-delivery consequences of someone leaving.
- What changes and what does not: Current assignment clears on every affected feature. Pending blocking-question and review responsibility then route to the immutable owner on their own, because `Assignment.responsible/2` and `QuestionRouting` derive responsibility from *current* participation rather than a stored field — proved by test rather than reimplemented. Prior activity keeps its actor reference untouched, so historical contribution survives the departure. The active run is deliberately not cancelled: it stays live under owner control, because a membership action must not silently destroy work in progress.
- Replay safety: Acknowledgement happens only after commit, so a crash in between is safe — the same handoff is claimed again and its application is a no-op. That ordering is what makes at-least-once delivery from the producer harmless.
- Failed checks: None. Final proof passes with real exit status: the revocation-consumer suite, `mix test` (1638 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 28 (reconcile authoritative state and worker execution) is next; it is the last task before the evidence chain opens up.
- Spec updates: Marked Task 27 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 26 complete: authorized cancellation and restart readiness

- Completed: Added `Delivery.Cancellation` and the cancel action on the feature detail screen. Cancelling supersedes the current attempt, ends the run, tells the worker to stop, records the outcome, and returns the feature to the readiness state of its current revision.
- Authority is narrow and deliberate (AC-32): Only the run's current initiator or the project owner may cancel. Another fully authorized current participant is refused, and a former initiator loses the authority when their participation ends while the owner keeps it. All four cases are proved, because the point of the rule is that cancelling active work is not the same collaborative act as starting it.
- Terminal with governed history (AC-33): The canceled run, its branch identity, its activity, and its evidence remain as records; there is no resume. The feature returns to `Ready for development` when its current revision still satisfies readiness and to `Draft` otherwise, decided through `Readiness.start_available?/4` rather than a stored flag. A later start creates a different run on a different branch, asserted end to end — a canceled run must never block or silently continue into the next one.
- Repeating a cancel on an already-canceled run is refused without enqueuing a second stop command.
- Recorded inconsistency: `start.ex` sets a command's `expected_state_version` from the post-commit run version while `answers.ex` and `retry.ex` use the pre-commit one. Nothing consumes the field yet, so it changes no behaviour today; it must be settled before `CommandTransport.EnvelopeSource` is installed and a worker begins acting on it.
- Failed checks: None. Final proof passes with real exit status: the cancellation suite plus the feature-detail LiveView suite, `mix test` (1622 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 27 (consume participation revocation) is next, then Task 28 reconciles authoritative state with worker execution.
- Spec updates: Marked Task 26 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 25 complete: bounded automatic and manual retry

- Completed: Added `Delivery.Retry` and the failed-run presentation with its retry action. A `failed` worker event is classified, retried on the same run within a bounded budget, or made terminally visible with its reason.
- Boundary held (AC-34): Retry classification is explicit, and an unrecognised reason is `:terminal` — the product never retries a failure it does not understand. The budget is three automatic retries after the initial attempt; backoff is jittered exponential from 15 seconds capped at five minutes, with the jitter injectable so the timing is asserted deterministically. Backoff is scheduling rather than sleeping: a retry is a command that is not due yet, so a pending retry survives a control-plane restart.
- Terminal failure: An exhausted budget or a non-retryable reason moves the run to `failed` with its reason and shows `Failed` as a status while the feature keeps its place in `In development`. No retry command is enqueued, asserted against the outbox count — a terminal failure that quietly queued more work would be the worst possible outcome.
- Same run, same branch, same workspace: Every retry continues the same run and branch as the next ordered attempt with a higher fence, so the superseded worker cannot act and accepted work is not repeated. Manual retry is available to any current participant, matching the recorded rule that starting and retrying are collaborative while cancellation and review are not.
- Mechanism recorded: The delivery-store contract gained `latest_attempt`, implemented by both adapters. A continuation after a *terminal* attempt has nothing current to read and still needs the ordering and fence the next attempt must advance past, which `current_attempt` cannot supply.
- Failed checks: None. Final proof passes with real exit status: the retry suite plus the feature-detail LiveView suite, `mix test` (1599 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 26 (authorized cancellation and restart readiness) is next.
- Spec updates: Marked Task 25 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 24 complete: accepted-answer write-back and resume

- Completed: Added `Delivery.Answers` and the answer form on the feature detail screen. An accepted answer is written into the shared specification as a new revision, and only then does the same run continue.
- Ordering is the contract (AC-18): The append happens first, under expected-head concurrency, and only a committed revision may resume anything. It is deliberately outside the resume transaction — the specification store is a separate authority with its own concurrency rule, and a distributed transaction across the two is what the storage design forbids. The worst case is therefore a recorded decision whose resume failed, which is recoverable, rather than a run continuing against an agreement that was never written.
- Same run, same branch, same workspace: All three are asserted unchanged. Only the attempt number, the fence token, and the effective revision move, which is what lets accepted work survive the pause instead of being repeated. The prior attempt is superseded in the same commit, so the paused worker's fence is useless the moment the next attempt exists. The run's immutable starting revision is never rewritten.
- Feature placement: The blocked status clears while the feature keeps its place in `In development`, asserted directly.
- Provider-thread independence: The next attempt is reconstructable from its manifest digest, the accepted revision, the preserved checkpoint, and the continuation reason alone — the stored attempt value was asserted to carry no thread reference. A thread lost while a human was thinking costs nothing.
- New invariant: An answered question now names the revision its answer produced, enforced by a check constraint. Without the link the durable agreement and the question that changed it are two records nobody can join. Three existing tests that resolved a question without a revision were updated to satisfy the invariant rather than the invariant being relaxed.
- Failed checks: Two agent attempts at this task died on infrastructure (one stalled, one lost its connection), so it was implemented directly; the partial work they left — an `AgentRun.resume_changeset/5` folding the run's three facts into one update precisely to avoid a double write, plus `resume_run` and `resolve_question` store operations — was sound and was kept. The question lookup first scanned activity for runs, which found nothing when a question was recorded without one; it now asks `Blocking.for_feature/3` directly. A named question that is not the open one reports `:question_mismatch` rather than `:no_open_question`, because working from a stale screen is a different thing from having nothing to answer. Strict Credo also flagged parameter count, resolved with a context map. Final proof passes with real exit status: 15 answer tests, 29 feature-detail LiveView tests, `mix test` (1564 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 25 (bounded automatic and manual retry) is next.
- Spec updates: Marked Task 24 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 23 complete: blocking-question responsibility routing

- Completed: Added `Delivery.QuestionRouting` and the responder presentation on the feature detail screen. An open question names who it is waiting on, and only that person may answer it.
- Boundary held (AC-05, AC-06): The assigned participant is tagged even when the creator is someone else, and the creator is tagged when `Assigned` is empty — both asserted by name. When the assignee has left, and when the assignee *and* the creator have both left, responsibility routes to the immutable project owner rather than to a former participant. A person who is not a current responder is refused without learning who the real responder is.
- Presentation: Responders are participation-boundary member results — project display name, role, account reference — and no participant email appears in any return value, activity payload, or rendered output, which is asserted directly. The recorded question names its responder by account reference only; display names resolve at render, so a later rename or departure is reflected rather than frozen.
- Mechanism recorded: Routing consumes `Assignment.responsible/2` rather than restating the assignee-creator-owner rule. One resolution, one place — the routing rule and the screen's "answers questions" label cannot drift apart.
- Failed checks: None. Final proof passes with real exit status: the routing suite plus the feature-detail LiveView suite, `mix test` (1542 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 24 (accepted-answer specification write-back and resume) is next; it consumes the routed responder's authorization.
- Spec updates: Marked Task 23 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 22 complete: durable blocked-run and question state

- Completed: Added `blocking_questions` with its migration and schema, the `Delivery.Blocking` domain, and the blocked presentation on the feature detail screen. A `blocked` worker event pauses the run, records one focused question with its context, and preserves the branch, workspace, and checkpoint so accepted work is not repeated.
- Boundary held (AC-02): The feature keeps its place in `In development` and shows `Blocked` as a status; it never moves to a column of its own, which is asserted directly. A blocked run is paused, not failed, and its history says which.
- One question invariant (AC-17): At most one open question exists per run, enforced by a partial unique index in the same shape as the one-current-attempt index. A second `blocked` event for a run that already has an open question records no second question.
- Trust checks unchanged: A blocked event proves the same three things every worker event must — protocol schema, current fence, advancing sequence — so a superseded worker cannot block a run it no longer owns.
- Mechanism recorded: Those three checks were extracted from `EventIngestion` into a shared public `accept/4`. Each event type is owned by a different task, but what makes a worker's word trustworthy is identical for all of them, so the checks live in one place instead of being restated per owner — and cannot drift apart. The delivery-store contract gained `insert_blocking_question`, `fetch_feature`, and `open_question`, implemented by both adapters.
- Failed checks: None. Final proof passes with real exit status: 26 blocking tests plus the feature-detail LiveView suite, `mix test` (1518 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 23 (routing blocking-question responsibility) is next and consumes the question this task records.
- Spec updates: Marked Task 22 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 21 complete: normalized progress and run-status presentation

- Completed: Added `Delivery.EventIngestion`, the only path by which a worker event becomes durable project state, and `Delivery.RunStatus`, the visible-status seam. An accepted event appends one normalized activity entry, advances the attempt's observed sequence, and moves a pending run to running.
- Boundary held (AC-16): A worker is the least trusted thing in the system, so every event proves three things before it can change anything — the envelope against the protocol schema, the fence token against the run's *current* attempt, and the sequence against what that attempt has already seen. A superseded worker holding the old fence can keep talking and move nothing: the run, the attempt, and the history were each asserted unchanged. A replayed sequence is a duplicate rather than a second entry, and an out-of-order one is refused.
- Raw events excluded: What survives is a minimized projection of approved fields — event type, source, sequence, attempt number, and a bounded summary — never the provider's own shape, which was asserted absent from the stored payload. A malformed envelope, an unknown field, an unsupported protocol version, an oversized payload, and a credential-shaped field are each refused before storage rather than redacted after.
- Scope held: An event type this task does not own (`blocked`, `failed`, `evidence`, `verification_completed`, `canceled`) is refused as `:unsupported_event` rather than half-applied, so the tasks that own those transitions still own them. An event for an unknown run, a run with no current attempt, or another project's run is refused.
- Mechanism recorded: An attempt reaches `running` only from `dispatched`, so progress ingestion no longer moves the attempt's own lifecycle — that belongs to the acknowledgement path. This also keeps one commit writing each record exactly once, which matters because a second write in the same commit would see the version its sibling step just bumped and fail as stale.
- Failed checks: Both of the above were real defects the tests found: ingestion first assumed a direct `pending → running` attempt transition, which is not in the transition table, and then wrote the attempt twice in one commit. Final proof passes with real exit status: 17 ingestion and status tests, `mix test` (1489 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 22 (durable blocked-run and question state) is next and owns the `blocked` event this task deliberately refuses.
- Spec updates: Marked Task 21 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 13 complete: explicit development start

- Completed: Added `Delivery.Start`. One press creates one run bound to one immutable starting revision, one isolated branch, one first attempt bound to its immutable execution manifest, the activity that records it, and one durable start command — in a single authoritative transaction, in either storage authority.
- Revalidated at the instant of the press (AC-15): Current participation, current readiness against the revision *actually in play*, and confirmation of the processing boundary *currently in force* are all re-checked here rather than trusted from the screen that drew the button. A revision edited after readiness blocks the start, and so does a processing boundary changed after confirmation — both proved by making the change between preparing the feature and pressing. Any current participant may start; an outsider and a departed participant cannot.
- Nothing starts by itself (AC-14): Becoming ready was asserted to create no run, no attempt, and no command. The button is the only thing that starts work.
- Duplicate start rejected: A second start while a run is live is refused as `:already_started` and leaves exactly one run and one command. Starting again after cancellation creates a different run on a different branch, which is the recorded contract — cancellation is terminal and a later start is a new run, never a resume.
- Mechanism recorded: The execution manifest binds the run identity, so the run id is generated before the transaction and accepted by `AgentRun.create_changeset` rather than autogenerated; the attempt then records that manifest's digest. The branch name derives from the run identity rather than the feature title, which a person can rename. The test reconstructs the manifest independently and asserts its digest equals the stored one, so the digest is proved to be the digest of a real manifest rather than an opaque value.
- Failed checks: The manifest's continuation map requires an explicit `prior_attempt_number` alongside its reason — `nil` for an initial attempt — which surfaced immediately as `:invalid_continuation` rather than silently accepting a partial continuation. Strict Credo also flagged nesting depth in the live-run lookup. Final proof passes with real exit status: 17 start tests, `mix test` (1472 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 21 (normalized progress and run-status presentation) is next. The `CommandTransport.EnvelopeSource` seam Task 19 recorded is still uninstalled, so a queued start command stays queued rather than reaching a worker; the tasks that own run dispatch install it.
- Spec updates: Marked Task 13 complete and refreshed the slice status; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 43 complete: configured coding-agent adapter

- Completed: Added `Delivery.AgentAdapter` with its behaviour, minimum input projection, launch and observation surface, event normalization, and a scriptable double. The agent is launched only inside the validated run workspace working directory from Task 20; a directory that fails containment refuses to launch.
- Boundary held: The projected agent input carries identities, digests, the approved slice, the target branch, the required-check contract, and the continuation reason — never a worker, control-plane, repository, or unrelated provider credential. The subprocess receives only an explicit environment allowlist, so the worker's own environment does not survive into it. Adapter events are normalized into the existing protocol envelope with secret stripping applied on the way; an event that cannot be normalized is dropped with a typed reason rather than passed through raw.
- Thread handling recorded: A provider thread is an optimization, never the checkpoint. A refused, expired, or unknown thread is a warm-start loss rather than an attempt failure — the same projected input starts a new thread instead — and the launch result reports `:new` or `:resumed` so a caller can tell which happened. Only those specific start errors fall back; a genuine launch failure is still a failure.
- Compatibility: The installed agent protocol version is checked before launch, so an incompatible agent is refused rather than started and abandoned.
- Failed checks: None. Focused proof passes with real exit status: 47 agent-adapter tests, `mix test` (1455 passing), `mix credo --strict`, `mix sobelow --config`, `mix format --check-formatted`, and `mix compile --warnings-as-errors`.
- Remaining: Task 13 (explicit development start) is now unblocked — every one of its prerequisites is complete.
- Spec updates: Marked Task 43 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 20 complete: worker workspace and branch isolation

- Completed: Added `Delivery.Worker.Workspace`, `Worker.Branch`, and `Worker.ProcessLock`. A run gets one normalized workspace under the configured root, one stable isolated branch validated against its manifest, and one current process protected by a fenced on-disk lock.
- Containment proved: A candidate path must be its own real path under the resolved real root, so traversal, absolute segments, separator-carrying segments, and symlink escapes are all refused — and all with the same `:workspace_escape`, so a caller gets a refusal rather than a diagnosis of which check failed. The symlink guarantee was verified by mutation: replacing the real-path pin with plain string expansion fails exactly the three link tests and passes the other fifty, which is what proves those tests are testing the link resolution rather than the expansion.
- Branch boundary: The default branch is refused by any spelling (`main`, `master`, `HEAD`, `refs/heads/main`, case-insensitively), so a run can never write to it. The base revision must match the manifest before work begins, and one run always resolves the same branch — a request naming a different branch for that run is rejected. Worker bookkeeping (the branch record, lock, and stop marker) lives beside the checkout rather than inside it, so it never enters the tree being committed. The git boundary shells out with an argument list rather than a shell, refuses any argument readable as a flag, and sets `GIT_TERMINAL_PROMPT=0` so it cannot acquire a credential by asking.
- Fencing recorded: A higher fence token takes the lock from a lower one unconditionally, even when the holder's process is alive; a lower fence is refused even when the holder is dead. Equal fences fall back to liveness, and an unreadable liveness probe answers "alive". Fencing, never liveness, is the guaranteed way past a stuck holder.
- Mechanism recorded: `Branch` re-validates the manifest through `ExecutionManifest.new/1` rather than restating the branch grammar, so nothing is redefined and a tampered manifest is rejected as invalid. A genuine `mkdir_p` or write failure reports `:workspace_unavailable` rather than `:workspace_escape`, because an I/O failure is not a containment failure and saying so would be dishonest.
- Failed checks: None in this task. Adding its 53 tests did expose a pre-existing flake in the Slice 08 invitation-proof test, which asserts on a recorded magic-link attempt without resetting the passwordless limiter's shared global bucket; once enough of the suite ran first, the request was throttled correctly and account-neutrally, so nothing was recorded. Three other suites already reset the limiter for exactly this reason and that one did not; it now does, and the full suite is deterministic across three seeds. Final proof passes with real exit status: 53 isolation tests, `mix test` (1408 passing), `mix credo --strict`, `mix sobelow --config`, and `mix compile --warnings-as-errors`.
- Remaining: Task 43 (configured coding-agent adapter) is unblocked by this, and Task 13 follows it.
- Spec updates: Marked Task 20 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 12 complete: start-time processing-boundary disclosure

- Completed: Added `Delivery.ProcessingDisclosure` with `processing_confirmations` and the accessible start dialog on the feature detail screen. Before development can start, the screen names where the work runs, which coding agent and model provider it uses, whether a preview provider is configured, and whether project content leaves its authoritative store.
- Boundary held (AC-36): The agreement is stored as the digest of exactly what was shown, not a boolean. That is what makes a configuration change invalidate it — the person did not agree to a boundary that did not exist yet — while an unchanged boundary reuses the earlier confirmation so a routine run is not interrupted. Changing any single disclosed field was asserted to change the agreement, and reordering the transfer list was asserted not to. Each person confirms for themselves, confirmations are scoped to one project, and a departed participant's confirmation stops counting.
- Failed checks: The LiveView caught a real defect. The confirm handler validated the clicked digest against the disclosure assigned at mount, so a configuration change while the dialog was open would have been confirmed anyway — precisely the case the disclosure exists to prevent. It now checks against the boundary in force at that moment and re-shows the changed one instead. Strict Credo also flagged a single-clause `with`. Final proof passes with real exit status: 16 disclosure tests, 19 feature-detail LiveView tests, `mix test` (1355 passing), and `mix credo --strict`.
- Remaining: Task 13 (explicit development start) consumes this confirmation and is unblocked once Task 43 lands; Task 20 (worker isolation) is in progress.
- Spec updates: Marked Task 12 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 11 complete: suggestion dismissal and development readiness

- Completed: Added `Delivery.Suggestions` with the dismissal action and the explicit promotion to `Ready for development`. Any current participant may dismiss a suggestion or promote a feature whose blockers are all resolved.
- Boundary held (AC-11, AC-12): A blocking finding is refused however the request is phrased, and so is an unknown finding — neither is silently recorded. The blocking classification is re-read from the stored assessment at the moment of the action rather than trusted from the request, so a finding that has since become blocking cannot be dismissed on the strength of a stale screen. Dismissing every suggestion never clears a blocker for promotion, which is asserted directly. An outsider and a departed participant are both refused.
- Readiness is a decision, not a side effect (AC-04, AC-13): `promote/4` commits its own transition with its own activity entry through `RunTransitions`, so the board shows a decision that happened rather than a state someone inferred, and a repeated promotion is absorbed by the operation key. A feature with a remaining blocker cannot be promoted.
- Nothing starts (AC-14): Promotion was asserted to create no run and no command. Ready is an invitation; starting development still needs a person to press the button, which Task 13 delivers.
- Mechanism recorded: Freshness is checked before dismissibility. Against a superseded finding list nothing else the request says is meaningful, and reporting "that finding is gone" would be a confusing way to say "the list changed" — a reassessment now correctly yields `:stale_assessment` rather than `:not_dismissible`.
- Failed checks: The check order above was the first defect, surfaced by the reassessment test. One assertion also expected a single dismissal to empty a two-suggestion list. Final proof passes with real exit status: 17 dismissal and readiness tests and `mix credo --strict`.
- Remaining: Task 12 (start-time processing-boundary disclosure) is next on the readiness path.
- Spec updates: Marked Task 11 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 19 complete: authenticated worker gateway

- Completed: Added `SddOrchestratorWeb.WorkerSocket`, `WorkerChannel`, and `Delivery.CommandTransport.Channel`, plus a worker double. Workers dial in over TLS to `/worker`, so a local or user-managed worker needs no inbound port, and command delivery is a server push rather than a poll.
- Boundary held: The socket token is signed with `Phoenix.Token` under its own salt, mirroring the hosted session cookie, and its claims are revalidated before they become socket assigns. A join is checked against the token's project *before* negotiation, so a cross-workspace join is refused before any contract exists; every other topic hits the fallback and is refused as unknown. Protocol negotiation rejects an unsupported version or a missing capability at join time, so an incompatible worker is never registered and no command can reach it. Malformed, oversized, and stale inbound payloads are rejected by the existing codec and change no state — the channel writes no project state itself, publishing events on PubSub for the ingestion tasks instead.
- Mechanism recorded: Attached workers register in a duplicate-key `Registry` keyed by project. Duplicate keys are deliberate — a reconnect may overlap its predecessor, and at-least-once delivery with idempotent command IDs makes that overlap a redelivery rather than a second run. Losing every registration on restart is correct: each worker reconnects, and the queue was never in that process. `:no_worker` and `:incompatible_worker` stay distinguishable, and both leave the command claimed rather than failed.
- Decision recorded: `RunCommand` stores identities, a manifest digest, and a due time — never the manifest body or a cancellation reason — so a claimed row alone cannot rebuild the protocol envelope its worker must receive. Rather than widen the outbox schema, the gateway added a `CommandTransport.EnvelopeSource` seam configured through `:command_envelope_source`, mirroring the transport's own default-to-unavailable pattern. With no source installed, delivery returns an error and the command stays queued and due again. The enqueueing tasks that own that content install the real source; Task 13 is the first.
- Failed checks: None. Focused proof passes with real exit status: 38 worker-gateway tests, `mix credo --strict`, and `mix compile --warnings-as-errors`.
- Remaining: Task 20 (worker workspace and branch isolation) is unblocked by this and is next on the worker path.
- Spec updates: Marked Task 19 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 10 complete: guided requirements and blocking readiness

- Completed: Added `readiness_assessments` with its migration and schema plus `Delivery.Readiness`, the consumer that asks the shared specification store for the current revision, asks the configured guidance boundary what it still needs, and records the verdict.
- Boundary held (AC-09, AC-10, AC-11): The verdict is bound to the exact revision it judged by identity *and* digest, so editing the requirements invalidates readiness rather than silently carrying it forward — proved by appending a real revision and watching `Start development` become unavailable again. A blocking finding is never dismissible, and the blocker list ignores `dismissed_ids` entirely, so there is no code path that hides one even when a dismissal names it. Start availability requires a current assessment, bound to the revision in play, with no remaining blocker; an absent or superseded assessment is not readiness.
- No duplicate persistence: The assessment stores the specification identity, revision identity, and digest — never the requirement text. The `readiness_evaluated` activity records only the verdict's shape (counts and whether it is ready), which was asserted to contain neither the requirements nor a finding explanation. Requirements stay in `capability:project-specification-store`, which this slice consumes and does not copy.
- Mechanism recorded: One current assessment per feature is a unique index on `feature_id`; a new evaluation replaces the old one and bumps a version, because a feature has one readiness answer and a history of contradictory verdicts would tell a user nothing. That version is what Task 11's dismissal is checked against, so a dismissal aimed at a superseded finding list is rejected rather than applied to different findings. A guidance timeout or failure is reported as its typed reason and records no assessment at all — an absent verdict is not a passing one.
- Failed checks: The guidance projection takes `id` and `digest` keys on the revision map, not `revision_id`/`revision_digest`; the mismatch surfaced immediately as `:invalid_revision_id` rather than silently projecting nothing. The specification-store `create/4` also takes its documents under a `documents` key, which the shared fixtures already encode. Final proof passes with real exit status: 17 readiness tests, `mix test` (1318 passing), and `mix credo --strict`.
- Remaining: Task 11 (suggestion dismissal and development readiness) builds directly on the recorded assessment and its version.
- Spec updates: Marked Task 10 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 3 complete: authoritative run-state transactions

- Completed: Added `Delivery.RunTransitions`, the one place a feature's column, its run's state, its attempt, its history, and its next worker instruction change together. Each request commits exactly one authoritative transaction through the shared `DeliveryStore` step list, so a hosted and a device-authoritative project apply identical rules. Added the `transition_feature` and `set_feature_status` operations both adapters needed for it.
- Boundary held: An illegal feature transition, an illegal run transition, and a request built from a superseded record each leave the store exactly as it was — no column moved, no history appended, no command enqueued. A visible status is recorded without moving the feature out of `In development`, which is what keeps `Blocked` and `Failed` statuses rather than columns.
- Idempotency recorded: Requests carry an operation key stamped into the activity payload, so the append-only history is itself the ledger. A retried request, a double-clicked button, and a redelivered worker event find their own earlier effect and return `applied?: false` with the original entry instead of applying twice; two different keys on one feature remain two transitions. This is what makes it safe for a caller to retry a transition it is unsure committed.
- Failed checks: Three real defects. The hosted adapter had been folding `:lifecycle_column` errors into `:stale_state`, which conflated an illegal transition with a superseded one — retrying the first can never help, so a caller must be able to tell them apart; the check now covers version errors only. The parity tests then exposed that a device-authoritative project's feature has to exist in the device store, which the hosted fixture alone does not arrange, so each authority now seeds its own world. One count assertion also included the readiness transition from setup and was made specific to the retried key. Final proof passes with real exit status: 21 transition tests across both authorities, `mix test` (1263 passing), and `mix credo --strict`.
- Remaining: Task 19 (worker gateway) is in progress; Task 13 (explicit development start) is the first task to compose this service into a product action.
- Spec updates: Marked Task 3 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 18 complete: device-authoritative delivery-store adapter

- Completed: Added the shared `Delivery.DeliveryStore` contract with its hosted PostgreSQL adapter and worker-owned device adapter, and extended the device-store boundary with a serialized delivery namespace (`commit_delivery/2`, `get_delivery/3`, `list_delivery/2`).
- Mechanism recorded: Writes are an ordered list of named steps rather than changesets, because a changeset is a hosted concept. The hosted adapter interprets the steps as one `Ecto.Multi`; the device adapter validates them in the caller, then hands the worker one all-or-nothing batch applied under its single serialized process. A step may reference an earlier step's result with `{:ref, step, field}`, which is what lets one commit create a run, its first attempt, the activity naming both, and the start command — atomically, in either authority.
- Parity proved: Every behavioural test is written once and run against both authorities — atomic multi-step commit, cross-step references, all-or-nothing rollback on an invalid step, run and current-attempt reads, expected-version enforcement, illegal-transition rejection, one-current-attempt exclusivity, lease claim and sequence fencing, activity ordering, command replay under one ID, claim, and acknowledgement replay. Two implementations are only safe if they answer the same way, so the proof is the shared suite rather than two separate ones.
- No hosted copy (specs/05): A full device commit leaves every hosted delivery table byte-identical while the records genuinely exist on the device, and device and hosted activity for the same feature are invisible to each other. An unsupported authority fails closed rather than guessing a store.
- Failed checks: Two real defects surfaced. `Enum.reduce/3` passes `(element, accumulator)`, so the hosted adapter built its `Ecto.Multi` with the arguments transposed. More significantly, `optimistic_lock/2` only takes effect inside `Repo.update`, which the device adapter never calls — so `apply_changes/1` left the version unmoved and a superseded write looked current. The device adapter now applies the increment itself and compares against the version its caller read, which is what the expected-version parity test pins. `Activity.next_sequence/1` also gained a clause for attrs with no feature, so the changeset reports the missing feature rather than the helper raising over a symptom. Final proof passes with real exit status: 29 parity tests across both adapters, `mix test` (1242 passing), `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 3 (authoritative run-state transactions) composes validated transitions on top of this contract.
- Spec updates: Marked Task 18 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 45 complete: configured readiness-guidance adapter

- Completed: Added `Delivery.ReadinessGuidance` — the one configured model boundary that reports what a specification still needs — with its behaviour, minimum input projection, strict response validation, blocking classification, and a scriptable double.
- Boundary held: What leaves the control plane is a minimum projection of the feature title, the exact revision identity and digest, and the requirement text. Participant email addresses, credentials, and repository content cannot reach a provider by construction rather than by filtering: an unknown input field is rejected outright, and both directions are scanned for secret- and email-shaped content. What comes back is validated before it can influence readiness — unknown response or input version, unknown category, non-boolean blocking flag, duplicate or malformed finding, an answer bound to a different revision, and an oversized payload are each rejected with their own typed reason.
- Guidance is advice, never authority: the adapter performs no persistence at all, which is proved by reading the compiled module's BEAM import chunk and asserting it calls nothing under `Ecto` or the repository. Task 10 owns the durable assessment.
- Decision recorded: The default adapter returns `{:error, :guidance_unavailable}` rather than an empty finding list, and a timeout and a provider failure are distinct typed reasons. An empty finding list is exactly the shape of "nothing blocks this feature", so returning one from a boundary that failed would mark features development-ready without anything having assessed them. This matches how `CommandTransport.Unavailable` fails closed for an absent worker.
- Failed checks: None. Focused proof passes with real exit status: 37 readiness-guidance tests, `mix format --check-formatted`, `mix credo --strict`, and `mix compile --warnings-as-errors`.
- Remaining: Task 10 (guided requirements and blocking readiness) consumes this next.
- Spec updates: Marked Task 45 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 46 complete: participant feature comments

- Completed: Added `Delivery.Comments` and the comment section on the feature detail screen. A comment is one `ActivityEntry` of type `comment` rather than a separate record, so what people said sits in the same ordered history as agent progress, questions, answers, and evidence — a reviewer reads one story instead of reconciling two timelines.
- Boundary held: A comment is explanatory only and can satisfy no required check and move no column; participant prose and agent prose have the same standing as evidence, which is none. Authorization is revalidated on every post: an outsider, an unauthenticated visitor, a departed participant, another project's feature, and an unknown feature are all refused with nothing appended.
- Redaction proved: A comment is the one payload written freely by a person, so a pasted credential (OpenAI, GitHub PAT and fine-grained PAT, PEM private key, AWS key id) or any address is refused at submission rather than stored and redacted later. Attribution uses the project display name; the stored entry was asserted to contain no address.
- Duplicate submission: Identical text repeated as the same person's immediately preceding comment is rejected as a resubmission, which is what a double-clicked button produces. The same text after someone else's comment is a real comment, and two people may say the same thing.
- Failed checks: The comment button first used a `message-square` icon that the project's fixed inline icon set does not carry, which failed every render. It now uses `pencil` rather than extending the shared presentation foundation owned by another slice. Final proof passes with real exit status: 18 comment tests, 15 feature-detail LiveView tests, 15 `chromium` feature-delivery browser scenarios, `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 18 (device delivery-store adapter) and Task 3 (run-state transactions) continue the orchestration path.
- Spec updates: Marked Task 46 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 9 complete: project-participant assignment and responsibility

- Completed: Added `Delivery.Assignment` and the feature-detail assignment controls. Any current participant may set `Assigned` to any current participant of the same project or take it themselves, and the screen shows the creator, the assignee, and — separately — who would actually be asked a question right now.
- Boundary held: Responsibility is derived rather than stored: the current assignee if they are still a participant, otherwise the current creator if they still are, otherwise the immutable owner. Both fallbacks are proved with a real removal, including the case where the assignee and the creator have both left, so a question can never route to someone whose access ended. The selector is exactly the project's current members, so a departed person cannot be chosen; a target who leaves between render and submit is rejected as `:invalid_target` with nothing changed. An outsider, an unauthenticated visitor, and a departed participant all fail closed, and a feature from another project is unreachable.
- Presentation (AC-31): Every identity is a project display name. The selector, the labels, the derived responsibility line, and the activity payload were each asserted to contain no address, and a departed member has no label at all rather than an invented one — the caller renders its own neutral historical text.
- Mechanism recorded: The assignment and its `assignment_changed` activity commit in one `Ecto.Multi`, so history cannot disagree with the field, and a rejected assignment records nothing. The activity payload names accounts only; display names resolve at render from current participation, so a later rename or departure is reflected instead of frozen into history. Writes carry the caller's expected state version, so a stale board tab is rejected rather than overwriting a newer assignment.
- Failed checks: One pre-existing browser assertion proved "no direct column choice" by counting every `select` on the screen, which the new assignment control legitimately breaks. It was narrowed to what it actually meant — the gated-action area has no select, and no option anywhere offers a lifecycle column — which is a stronger check than the count it replaced. Final proof passes with real exit status: 24 assignment tests, 11 feature-detail LiveView tests, 13 `chromium` feature-delivery browser scenarios, `mix format --check-formatted`, and `mix credo --strict`.
- Remaining: Task 45 (readiness-guidance adapter) is next on the readiness path; Task 18 and Task 3 continue the orchestration path.
- Spec updates: Marked Task 9 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 16 complete: durable command outbox and dispatcher

- Completed: Added `run_commands` with its migration and schema, the `Delivery.CommandOutbox` claim and replay surface, the `Delivery.CommandTransport` hand-off boundary, and the supervised `Delivery.Dispatcher`. A start, resume, retry, cancel, or reconcile instruction is a durable row with a due time, not a message in process memory.
- Boundary held: Enqueueing contributes to the caller's transaction, so a command cannot exist for a state change that rolled back. One instruction is one row however often it is enqueued: the recorded command is returned with its acknowledged result rather than starting a second process, and reusing one command ID for a different operation is surfaced as `:command_id_reused` instead of being silently dropped. Claims use `FOR UPDATE SKIP LOCKED` with an expiring lease, so two concurrent dispatchers take different rows and never the same one. An acknowledgement is recorded once and replayed thereafter, so a reconnecting worker's duplicate acknowledgement cannot overwrite the first answer.
- Restart recovery proved: A dispatcher that dies mid-delivery leaves claimed rows behind; `release_expired/1` returns them to the queue once their lease passes, while a live claim and an acknowledged command are both left alone. Backoff is scheduling rather than sleeping — a retry is a command that is not due yet — so a pending retry survives a control-plane restart.
- Mechanism recorded: The primary key is supplied by the enqueueing transaction, which makes `on_conflict: :nothing` unusable for idempotency — Ecto returns the unpersisted struct as though it had been written, so a conflict is undetectable. The outbox reads the recorded row first and falls back to re-reading on the insert race instead. `CommandTransport` keeps the hand-off separate from durability, so the queue is proven without a worker and Task 19 can attach the channel without touching claim, lease, or replay semantics; its default reports no connected worker, which leaves work queued rather than failing it. The dispatcher is supervised and started in dev and prod, and driven directly in tests through `config :sdd_orchestrator, start_command_dispatcher: false` so a timer never races the Ecto sandbox.
- Remaining: Task 9 (assignment and responsibility) is next; Task 18 then gives the device adapter the same contract, and Task 3 composes state, activity, and command into one transaction.
- Failed checks: None. Focused proof passes with real exit status: 28 outbox and dispatcher tests, `mix format --check-formatted`, and `mix credo --strict`.
- Spec updates: Marked Task 16 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 17 complete: ordered feature activity

- Completed: Added `activity_entries` with its migration and schema plus the `Delivery.Activity` append and read surface. Every entry belongs to one project and feature, optionally names its run and attempt, records who acted, and carries a minimized normalized payload at an authoritative position.
- Boundary held: History is append-only at the database, not by convention — a `BEFORE UPDATE` trigger rejects any rewrite, including `Repo.update_all` and a console session, while deletion stays available so project deletion and retention still work. Ordering comes from a per-feature sequence assigned inside the appending transaction, so a clock skew cannot reorder a feature's story and two concurrent appends can never share a position. Machine output can never be attributed to a person: only a `participant` entry may carry an account, and an `agent` or `system` entry with one is rejected by both the changeset and a check constraint.
- Minimization proved: A payload carrying a raw provider stream, transcript, or credential-shaped field (`raw_event`, `stdout`, `prompt`, `messages`, `api_key`, `email`, and the rest of the rejected list) is refused at the changeset at any nesting depth, as is an oversized payload. A stream that is never stored cannot leak, so this is enforced on the way in rather than redacted on the way out.
- Mechanism recorded: `Activity.append_multi/3` contributes the append to the caller's own `Ecto.Multi` and accepts a function of the transaction's changes, which is what lets every later state-changing action commit its transition and its history together or not at all. Reads authorize through `ParticipantGuard` on every call and page by sequence.
- Remaining: Task 16 (durable command outbox) is next, then Task 9 can record its assignment activity here.
- Failed checks: None. Focused proof passes with real exit status: 26 activity tests, `mix format --check-formatted`, and `mix credo --strict`.
- Spec updates: Marked Task 17 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 15 complete: hosted run and attempt persistence

- Completed: Added `agent_runs` and `run_attempts` with their migration and schemas. A run is created once per feature, owns one isolated branch for its whole lifetime, and records its immutable starting revision plus a separately movable effective revision; an attempt is one ordered exclusive execution bound to its execution-manifest digest.
- Boundary held: Specification revisions are referenced by identity and digest, never by foreign key, so a device-authoritative project's revisions cannot become a second copy in this database. Exclusivity is enforced in three independent layers: the attempt number is unique per run so an ordering gap is visible rather than overwritten, a partial unique index permits at most one attempt in a non-terminal state, and a unique monotonic fence token per run lets a superseded worker's late events fail closed. Two concurrent inserts leave exactly one current attempt. A lease is stored as an owner/expiry pair, cannot be claimed on a terminal attempt, and is released on every terminal transition, so an expired worker never looks current during reconciliation. A failure reason exists only while the run is failed, and the observed event sequence and attempt counter move forward only.
- Mechanism recorded: Run and attempt writes carry the caller's expected state version and an optimistic lock, matching the `Feature` contract from Task 8, so a stale board tab or replayed action is rejected rather than applied. Both schemas expose `to_value/1` and `from_value/1` so Task 18's device adapter holds the same shapes without Ecto.
- Remaining: Task 17 (ordered feature activity) and Task 16 (durable command outbox) build directly on this; the run-state transaction that composes them is Task 3.
- Failed checks: None. Focused proof passes with real exit status: 28 run-persistence tests, `mix format --check-formatted`, and `mix credo --strict`.
- Spec updates: Marked Task 15 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 2 browser matrix unblocked

- Completed: The desktop and mobile browser matrix recorded as environment-blocked on Task 2 now runs for real. Ten scenarios cover the five fixed lifecycle columns empty and populated, the creator label, the visible status that does not move a card out of its column, the absence of any drag affordance (no `draggable` attribute and no handle on any card), card-to-detail navigation with no direct column choice, and adding a feature to `Draft` — with keyboard, focus-ring, viewport, and axe passes on both `chromium` and `mobile-chromium`. The environment-blocked `Status:` line is removed because the condition it recorded no longer holds.
- Mechanism recorded: The blocker was that Playwright could establish neither auth boundary. `SddOrchestratorWeb.E2EBootstrapController` at `/_e2e/session`, owned by specs/08's write-back of the same date, establishes the application and hosted sessions and seeds a board by walking the real transition table from `Draft`. It is harness code, not product behavior: no acceptance criterion, entity, or task ownership changed here.
- Security boundary: Both the controller module and its route are compiled in only under `Application.compile_env(:sdd_orchestrator, :e2e_bootstrap, false)`, which no production configuration sets; a `MIX_ENV=prod` build compiles 31 routes with no `/_e2e/session`, and the built release contains no such module or path at all. The action also answers `404` at runtime when the flag is off.
- Remaining: Unchanged. Task 9 (project-participant assignment and responsibility) is still the next executable task, and `capability:project-participation-governance` remains unavailable, which affects Task 40 only. The live configured worker and coding-agent smoke proofs in the verification gate remain environment-blocked for their own separate reason and are untouched by this change.
- Failed checks: None. Proof passes with real exit status: `npm --prefix assets run test:e2e` (69 passing on `chromium` and 69 on `mobile-chromium`, of which 10 per project are these feature-delivery scenarios) and `mix check` (1037 passing).
- Spec updates: Removed the satisfied environment-blocked `Status:` line from Task 2. Requirements, design, acceptance criteria, ownership, task sizes, and capability edges are unchanged.

### 2026-07-29 - Task 2 complete: feature lifecycle board

- Completed: Added the project feature board at `/projects/:id/features` and the feature detail screen at `/projects/:id/features/:feature_id`, plus the grouped board query. All five lifecycle columns always render, including empty ones, so the board's shape communicates the workflow rather than following the data. Cards show the feature title, its visible status when it has one, and the creator and assignee by project display name.
- Boundary held: There is no way to move a card from the board. It carries no drag affordance, no hook, and no click handler — a card's only interaction is a link to the feature's own screen, where the gated action for the current column is presented. Every illegal or direct transition is rejected by the lifecycle domain, and `Blocked` renders as a status on an `In development` card with no column of its own. People are labelled by project display name only; a departed member's features stay visible under a neutral label with no address exposed. A participant reaches the board through their hosted session, while an outsider, an unauthenticated visitor, and a cross-project feature identifier are all returned without disclosing project content.
- Remaining: Task 9 (project-participant assignment and responsibility) is next, then the readiness adapter and guided requirements.
- Failed checks: Three assertions needed correcting rather than the code: two CSS selectors were unquoted around UUID values, and the no-drag proof originally crashed the view by pushing an unhandled event; it now asserts structurally that a card carries no click handler or destination value. Final proof passes with real exit status: 11 board and detail LiveView tests, `mix test` (1024 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 2 complete and recorded its environment-blocked browser modality; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 8 complete: feature lifecycle domain

- Completed: Added the `features` table with its migration, the `Delivery.Feature` schema, and the `Delivery.Features` domain. A feature is project-scoped, records its creator and an optional assigned participant as account references, starts in `Draft`, and carries a state version. The complete legal transition table is declared in one place, and `Done` has no exit.
- Boundary held: There is no column setter — only a transition against the table — so a dragged card or a direct state change cannot bypass a gate; every move outside the table is rejected and leaves the committed column and version untouched. The state version is enforced twice: the caller's expected version must match the loaded record, and the update is filtered on that version, so a row that moved between load and write is reported stale rather than overwritten. `Blocked` and `Failed` are statuses that keep the feature in `In development`, enforced by the changeset and by a database check constraint. Reads and writes go through the participation guard, so a removed participant immediately loses both. The device-adapter value shape round trips without Ecto and rejects malformed values.
- Remaining: Task 2 (the feature lifecycle board) is next, followed by assignment, the readiness adapter, and guided requirements.
- Failed checks: The first stale-version proof exposed that comparing the in-memory struct alone still let a superseded write land, because the update was keyed only by primary key; the changesets now use `optimistic_lock/2` and the domain converts the resulting stale-entry error into `:stale_state`. Final proof passes with real exit status: 15 lifecycle tests, `mix test` (1013 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 8 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 14 complete: current-participant authorization guard

- Completed: Added `Delivery.ParticipantGuard`, the single fail-closed check every feature-delivery action and project-content read uses. It consumes `capability:project-participation-boundary` and adds nothing to it: `authorize/2` resolves the acting person as a current member, `authorize_action/3` maps each protected Slice 07 action to the project capability it requires, `current_members/2` lists members only for a caller who may read the project, and `owner/1` resolves the deterministic responsibility fallback.
- Boundary held: A member result carries stable identity, role, and project display name only — no participant email reaches this slice, in the result or in its inspection. An absent identity, a stale or removed participant, a person who left, and a cross-project identity all receive the identical `:unauthorized` result, and an unknown or malformed project is indistinguishable from an unauthorized one, so content existence is never disclosed. An unknown action name is denied rather than allowed. Removal takes effect on the next call for every protected action, and a sequence of guard calls leaves participation and profile rows byte-identical.
- Remaining: Task 8 (the feature lifecycle domain) is next, followed by the dependency-ordered board, orchestration, evidence, review, notification, and privacy tasks.
- Failed checks: The full run exposed that Task 7's persistence scan counted every file in the delivery namespace, so the new guard broke its expected count; the scan now names the six protocol modules explicitly, which is the claim it was actually making. Final proof passes with real exit status: 10 guard tests, `mix test` (998 passing), `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`.
- Spec updates: Marked Task 14 complete; requirements, design, ownership, and capability edges are unchanged.

### 2026-07-29 - Task 1 complete: delivered provider contracts confirmed

- Completed: Confirmed the approved feature-delivery contracts against the three now-delivered provider boundaries. `capability:project-storage-authority` supplies the hosted and device storage-mode authority this slice binds feature, run, command, activity, and evidence records to. `capability:project-specification-store` supplies stable specification identity, immutable complete revisions, current reads, consistent snapshots, and restoration participation through `SddOrchestrator.SpecificationStore`, which matches the specification-store consumer interface: this slice appends revisions through it and defines no second store. `capability:project-participation-boundary` supplies `Participation.Boundary` — current owner and active participants as stable identity, role, and project display name with no email, fail-closed denial for stale, removed, left, absent, and cross-project identities, direct reads with no cache, the versioned `ParticipationRevocation` claim and acknowledgement contract, and the shared account-level notification store with this slice's own `delivery.` event namespace reserved.
- Boundary confirmed: Each consumer contract this slice recorded is satisfied by the delivered interface. No provider contract needed to change, and this slice redefines none of them.
- Remaining: Task 14 (the current-participant authorization guard) is the next executable task. `capability:project-participation-governance` from `specs/08-project-participation#Task 5` is still unavailable, which blocks Task 40 only; `capability:project-storage-governance` is available for Task 39.
- Failed checks: None. The individual specification validator and the global cross-specification graph pass, and the merged branch's `mix test` passes with 988 tests.
- Spec updates: Marked Task 1 complete, removed its capability-prerequisite blocker, and moved the slice status to `In Progress`; requirements, design, ownership, acceptance criteria, and capability edges are unchanged.

### 2026-07-29 - Task 7 complete: worker protocol and execution-manifest codec

- Completed: Added the provider-independent protocol foundation under `lib/sdd_orchestrator/delivery/`: protocol version 1 with capability negotiation that ignores unknown names and fails closed on a missing required capability, the stable URL-safe identifier format, configured payload limits, deterministic canonical JSON with duplicate-key rejection, the immutable execution manifest and its stable digest, the raw-credential boundary, and strict encoding and decoding for the command, normalized event, acknowledgement, heartbeat, and reconciliation-snapshot envelopes with exact field sets, ordering fields, fence tokens, sequences, expected state version, manifest-digest binding, and byte-stable fixtures under `test/fixtures/delivery/`.
- Boundary held: The codec validates envelope identity, ordering, structure, references, and limits only. Event payload semantics, dispatch, and persistence stay with their owning tasks; a repository, schema, and migration absence check proves the modules carry no project persistence.
- Remaining: Task 1 is blocked until `capability:project-participation-boundary` is delivered by `specs/08-project-participation#Task 4`. Every other Slice 07 task depends transitively on Task 1, so no further Slice 07 task is executable until that provider capability is ready.
- Failed checks: None. Focused proof passes with real exit status: 46 delivery protocol tests, then `mix test` (793 passing), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix sobelow --config`, and `mix deps.audit`.
- Spec updates: Marked Task 7 complete and moved the slice status to `In Progress`; requirements, design, ownership, acceptance criteria, and capability edges are unchanged.

### 2026-07-28 - Specification-store provider task refined

- Completed: Updated the `capability:project-specification-store` edge to its refined provider `specs/09-project-specification-storage#Task 8`; the capability contract and Slice 07 consumer boundary are unchanged.
- Remaining: Implement ready Task 7; complete the three operational provider capabilities before Task 1 and the three governance providers before their named consumer tasks; finish the remaining dependency-ordered tasks and verification gate.
- Failed checks: None in this specification; its individual validator and the global capability graph pass.
- Spec updates: Changed only the provider task reference; task sizing, ownership, acceptance criteria, design, and approved behavior remain unchanged.

### 2026-07-28 - Task-size and execution sequence refined

- Completed: Applied the Task Size Gate, preserved every existing task label, split the five broad implementation tasks into fifty standard implementation tasks with focused proof and no task-size exception, and moved the provider-independent worker protocol and manifest codec ahead of unavailable capabilities.
- Remaining: Implement ready Task 7; complete the three operational provider tasks before Task 1; complete storage governance before Task 39 and participation plus specification governance before Task 40; finish the remaining dependency-ordered tasks and verification gate.
- Failed checks: None; implementation has not started.
- Spec updates: Changed task status from `Blocked` to `Not Started`; split board, assignment, readiness adapter, guidance, comments, disclosure, hosted and device storage, dispatcher, worker gateway, workspace, agent adapter, start, progress, questions, write-back, retry, cancellation, revocation, reconciliation, evidence, artifacts, screenshots, preview, review, notification, retention, relay, cache, logs, backups, project deletion, rights, processor, transfer, and final review ownership; added AC-40 through AC-47 without changing approved behavior.

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
