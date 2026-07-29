# Guided Specification And Delivery Tasks

## Status

In Progress

The product, orchestration, privacy, and verification agreements remain approved. Task 7 delivered the protocol and execution-manifest foundation, Task 1 confirmed the three delivered provider contracts, and Task 14 delivered the fail-closed participation guard every later action uses. Task 8 established the durable feature and its lifecycle invariants and Task 2 delivered the board and feature detail screens, so Task 9 (project-participant assignment) is the next executable task. The board's desktop and mobile browser matrix now runs for real against a dev/test-only session bootstrap, so no delivery task carries an environment-blocked browser proof; the live worker and coding-agent smoke proofs remain environment-blocked for their own separate reason. `capability:project-participation-governance` remains unavailable, which affects Task 40 only.

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

- [ ] Task 9 - Deliver project-participant assignment and responsibility.
  - Size: Standard
  - Purpose: Keep current story responsibility explicit without exposing participant email.
  - Owned surfaces: Creator and optional `Assigned` presentation, current-participant selector, assignment to another current participant, `Assign to me`, responsible-participant resolution, creator and owner fallback, project display names, stale target rejection, assignment activity, fixtures, and responsive accessible controls.
  - Owns: AC-07, AC-08, AC-31
  - Depends on: Task 2
  - Proof: Focused domain, authorization, participant-selector, stale-target, assignment, self-assignment, fallback, display-name, email non-disclosure, activity, and browser tests pass.

- [ ] Task 45 - Implement the configured readiness-guidance adapter.
  - Size: Standard
  - Purpose: Ask one configured model boundary for structured missing, ambiguous, conflicting, blocking, and non-blocking findings without allowing it to mutate requirements.
  - Owned surfaces: Readiness-guidance behaviour, configured provider and model reference, minimum specification and feature input projection, structured finding schema, blocking classification, explanation field, versioned response, timeout and failure result, prompt and output limits, secret and participant-email exclusion, no automatic write-back, fixtures, and deterministic adapter double.
  - Owns: none (readiness adapter)
  - Depends on: Task 2, Task 14
  - Proof: Focused adapter, schema, blocking and non-blocking classification, missing, ambiguous, conflicting, timeout, malformed, oversized, secret, email, no-write-back, and deterministic-double tests pass.

- [ ] Task 10 - Deliver guided requirements and blocking readiness.
  - Size: Standard
  - Purpose: Explain required product information and keep unresolved blockers visible.
  - Owned surfaces: `ReadinessAssessment`, shared `ProjectSpecification` and `SpecificationRevision` consumer, exact revision binding, guided requirement structure, blocking and non-blocking finding schema, understandable finding explanations, current assessment replacement, visible blocker list, blocker non-dismissal, start-disabled result, fixtures, and feature-detail presentation without duplicate specification persistence.
  - Owns: AC-09, AC-10, AC-11, entity:ReadinessAssessment
  - Depends on: Task 45
  - Proof: Focused specification-store contract, assessment, classification, revision, blocker, non-dismissal, stale-head, authorization, presentation, and no-duplicate-store tests pass.

- [ ] Task 11 - Deliver suggestion dismissal and development readiness.
  - Size: Standard
  - Purpose: Let authorized users dismiss only non-blocking suggestions and expose readiness when every blocker is resolved.
  - Owned surfaces: Non-blocking suggestion dismissal, blocking-classification revalidation, assessment version check, ready-state transition, `Start development` availability, dismissal activity, unauthorized and stale denial, fixtures, and LiveView result.
  - Owns: AC-04, AC-12, AC-13
  - Depends on: Task 10
  - Proof: Focused suggestion, blocker, readiness, concurrency, stale-version, authorization, activity, and LiveView tests pass without automatically starting execution.

- [ ] Task 12 - Deliver start-time processing-boundary disclosure.
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

- [ ] Task 46 - Deliver participant feature comments.
  - Size: Standard
  - Purpose: Let current participants add one authorized project-scoped comment to ordered feature activity.
  - Owned surfaces: Comment action, current-participant revalidation, project and feature scope, display-name attribution, comment content limits and redaction, one transactionally appended `ActivityEntry`, duplicate-submission protection, stale and removed denial, participant-email non-disclosure, fixtures, and responsive accessible comment form.
  - Owns: AC-42
  - Depends on: Task 14, Task 17
  - Proof: Focused authorization, project isolation, display-name, email non-disclosure, content limit, redaction, duplicate, ordering, stale and removed denial, LiveView, desktop, and mobile tests pass.

- [ ] Task 18 - Implement the device-authoritative delivery-store adapter.
  - Size: Standard
  - Purpose: Provide equivalent feature, run, attempt, command, and activity transactions without a hosted device-project copy.
  - Owned surfaces: Shared delivery-store behaviour, hosted adapter conformance, worker-owned device persistence, state transition and activity plus command transaction, serialized command claim, attempt lease and fence, expected-version enforcement, restart behavior, protocol value shapes, fixtures, and negative hosted-copy enforcement.
  - Owns: none (device adapter)
  - Depends on: Task 16, Task 17
  - Proof: Focused shared-contract, device persistence, transaction, claim, restart, concurrency, idempotency, failure, isolation, and no-hosted-copy tests prove parity with the hosted adapter.

- [ ] Task 3 - Implement authoritative run-state transactions.
  - Size: Standard
  - Purpose: Apply one validated run transition, activity append, and resulting command atomically in either authoritative storage adapter.
  - Owned surfaces: Shared run-transition service, expected feature and run state versions, legal run and attempt transitions, atomic feature and run update, ordered `ActivityEntry` append, optional `RunCommand` insertion, hosted `Ecto.Multi` contribution, device transaction contribution, idempotent operation key, rollback, fixtures, and adapter-contract tests.
  - Owns: none (transaction invariant)
  - Depends on: Task 15, Task 16, Task 17, Task 18
  - Proof: Focused hosted and device transition, expected-version, activity ordering, command insertion, idempotency, concurrency, injected failure, rollback, and no-partial-state tests pass.

- [ ] Task 19 - Implement the authenticated worker gateway.
  - Size: Standard
  - Purpose: Deliver versioned commands and receive normalized worker state through a worker-initiated channel.
  - Owned surfaces: Outbound Phoenix Channel topic, workspace or execution-target authentication, capability negotiation, command delivery, acknowledgement, heartbeat, normalized-event and reconciliation-snapshot intake, connection state, incompatible-version denial, cross-workspace denial, reconnect seam, fixtures, and worker double.
  - Owns: none (worker gateway)
  - Depends on: Task 7, Task 16
  - Proof: Focused channel, authentication, capability, delivery, acknowledgement, heartbeat, reconnect, incompatible, stale, cross-workspace, and worker-double tests pass.

- [ ] Task 20 - Implement worker workspace and branch isolation.
  - Size: Standard
  - Purpose: Ensure one run executes only inside its normalized workspace and isolated branch.
  - Owned surfaces: Workspace-root configuration, normalized run path, traversal denial, exact process working directory, isolated branch creation and reuse, base revision validation, target-branch stability, one-current-process lock, cancellation stop seam, repository content boundary, fixtures, and worker-side tests.
  - Owns: none (worker isolation)
  - Depends on: Task 7, Task 19
  - Proof: Focused workspace, traversal, symlink, working-directory, branch, base-revision, process-lock, stale-process, cancellation-seam, and repository fixture tests pass.

- [ ] Task 43 - Implement the configured coding-agent adapter.
  - Size: Standard
  - Purpose: Launch and observe one configured agent without passing worker, repository, or unrelated provider credentials into agent input.
  - Owned surfaces: Agent-adapter behaviour, installed protocol version, configured executable and model reference, manifest input projection, worker-side provider and repository secret resolution, minimized environment, process launch and observation, compatible provider-thread create or resume, normalized progress and terminal events, secret stripping, fixtures, and deterministic agent double.
  - Owns: none (agent adapter)
  - Depends on: Task 20
  - Proof: Focused adapter, version, launch, resume, new-thread fallback, environment allowlist, secret non-propagation, event normalization, process failure, and agent-double tests pass.

- [ ] Task 13 - Deliver explicit development start.
  - Size: Standard
  - Purpose: Create one authorized run, activity entry, and start command for the exact ready revision without duplicate dispatch.
  - Owned surfaces: Current readiness and disclosure confirmation revalidation, any-current-participant start authorization, immutable starting revision and approved slice binding, hosted and device start transaction, new stable run and branch identity, initial attempt, start activity, command outbox insertion, duplicate-start rejection, feature transition to `In development`, fixtures, and start result.
  - Owns: AC-14, AC-15
  - Depends on: Task 3, Task 9, Task 12, Task 43
  - Proof: Focused hosted and device transaction, authorization, revision, disclosure, duplicate, concurrency, branch, command, activity, rollback, and no-automatic-start tests pass.

- [ ] Task 21 - Deliver normalized progress and run-status presentation.
  - Size: Standard
  - Purpose: Convert approved worker progress into durable activity and visible lifecycle status.
  - Owned surfaces: Normalized progress event validation, current fence and sequence check, idempotent activity append, run progress state, visible `In development`, `Blocked`, and `Failed` status seam, raw-provider-event exclusion, redaction, feature-detail activity stream, fixtures, and responsive status UI.
  - Owns: AC-16
  - Depends on: Task 3, Task 13, Task 17, Task 19
  - Proof: Focused valid, duplicate, stale-fence, out-of-order, oversized, unauthorized, redacted, raw-provider-event, activity, status, and LiveView tests pass.

- [ ] Task 22 - Deliver durable blocked-run and question state.
  - Size: Standard
  - Purpose: Pause one current attempt on one focused product question while preserving accepted work.
  - Owned surfaces: `BlockingQuestion`, hosted schema and migration, device-adapter value shape, question text and context limits, run, attempt, branch, workspace, checkpoint and pending state, atomic blocked transition and activity, no blocked column, one-open-question invariant, visible reason, fixtures, and blocked UI.
  - Owns: AC-02, AC-17, entity:BlockingQuestion
  - Depends on: Task 21
  - Proof: Focused migration, blocked transition, checkpoint, one-question, duplicate, stale-event, branch and workspace preservation, status, activity, and browser tests pass.

- [ ] Task 23 - Route blocking-question responsibility.
  - Size: Standard
  - Purpose: Tag the current assigned participant or creator with owner fallback when responsibility is stale.
  - Owned surfaces: Assigned-first and creator fallback resolution, current-participant revalidation, owner fallback, responder set, project display-name presentation, participant-email non-disclosure, stale and former-participant denial, question activity tags, fixtures, and UI presentation.
  - Owns: AC-05, AC-06
  - Depends on: Task 9, Task 22
  - Proof: Focused assigned, unassigned, creator, stale assigned, stale creator, owner fallback, responder authorization, display-name, email non-disclosure, and browser tests pass.

- [ ] Task 24 - Deliver accepted-answer specification write-back and resume.
  - Size: Standard
  - Purpose: Record the accepted product decision in the shared specification before the same run continues.
  - Owned surfaces: Authorized responder action, accepted answer, expected-head `SpecificationStore` append, immutable resulting revision, question-resolution link, effective revision and manifest update, continuation checkpoint, next attempt and resume command transaction, same run, branch and workspace preservation, provider-thread-independent reconstruction, activity, fixtures, and conflict result.
  - Owns: AC-18
  - Depends on: Task 10, Task 22, Task 23
  - Proof: Focused authorization, expected-head, revision, transaction, rollback, same-run, branch, workspace, checkpoint, new-thread reconstruction, duplicate answer, stale question, activity, and resume tests pass.

- [ ] Task 25 - Deliver bounded automatic and manual retry.
  - Size: Standard
  - Purpose: Recover transient failures on the same run and workspace without indefinite cost or duplicate attempts.
  - Owned surfaces: Explicit retry classification, three automatic retries after the initial attempt, jittered exponential backoff from 15 seconds with five-minute cap, same worker, workspace and branch, ordered next attempt, checkpoint and evidence preservation, terminal `Failed` transition and reason, post-terminal notification event, any-current-participant manual retry, duplicate prevention, fixtures, and failed-status UI.
  - Owns: AC-34
  - Depends on: Task 21, Task 24
  - Proof: Focused classification, timing, retry budget, same-worker, same-workspace, attempt ordering, checkpoint, terminal state, manual authorization, duplicate, concurrency, activity, and status UI tests pass.

- [ ] Task 26 - Deliver authorized cancellation and restart readiness.
  - Size: Standard
  - Purpose: Make cancellation terminal while preserving governed history and requiring a new run for later development.
  - Owned surfaces: Current initiator and owner authorization, other and former-participant denial, cancel command, worker stop acknowledgement seam, terminal canceled state, activity and evidence preservation, current-revision readiness reevaluation, `Ready for development` or `Draft` transition, no resume, later new-run and new-branch requirement, fixtures, and cancellation UI.
  - Owns: AC-32, AC-33
  - Depends on: Task 11, Task 13, Task 25
  - Proof: Focused initiator, owner, other, former, cancel command, repeat, worker response, history, readiness outcomes, no-resume, new-run, new-branch, and browser tests pass.

- [ ] Task 27 - Consume participation revocation.
  - Size: Standard
  - Purpose: End former-participant responsibility and access without canceling active work.
  - Owned surfaces: Versioned `ParticipationRevocation` claim, payload validation, idempotent authoritative transaction, current assignment clearing, pending question and review owner fallback, last display-name historical attribution, active-run owner control, former-participant denial, acknowledgement after commit, replay, fixtures, and absence of participation mutation.
  - Owns: AC-30
  - Depends on: Task 9, Task 22, Task 26
  - Proof: Focused removal and leave, assignment, question, review, active run, historical label, owner control, former denial, transaction, replay, acknowledgement, rollback, and negative participation-mutation tests pass.

- [ ] Task 28 - Reconcile authoritative state and worker execution.
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
