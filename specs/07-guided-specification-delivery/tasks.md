# Guided Specification And Delivery Tasks

## Status

Verified

The approved feature-delivery foundation through Task 54 was locally verified, and Task 55 corrected the worker artifact-upload transport, which had required a caller-declared `RunAttempt` identity no worker envelope ever transmits, to prove attempt currency by run and fence alone, exactly like the already-proven event-ingestion path, with no consumer-observable behavior change. `capability:worker-artifact-upload-transport` is ready and was consumed successfully by `specs/33-local-worker-run-execution` Task 10. The slice's full broad verification gate (`mix check`, `mix format`/`compile`/`credo`/`dialyzer`/`deps.audit`/`sobelow`, the full browser matrix, and the production build) has now passed again on this exact codebase: `slice/07-guided-specification-delivery` was merged into `slice/33-local-worker-run-execution` to unblock its Task 10, and that slice's own full verification gate — which necessarily re-exercises everything Task 55 touched — passed clean (see that slice's `progress.md` for the complete receipt list; re-running the identical broad gate a second time on the same merged commits here would be pure duplication). Every other completed task and published capability, including the Slice 08 recipient-routing contract, is unaffected. Live configured worker and coding-agent smoke proof remains environment-blocked because this checkout has only unavailable production adapters and no configured execution transport. Deployment-specific evidence and accountable privacy or legal review remain in the release gate.

## Active Slice

Verify the completed guided-delivery foundation through minimized notification projection and publish its stable child-consumer contracts. Preserve the approved end-to-end product contract and completed implementation history while focused child specifications own notification access, data-protection controls, operational retention, device retention, deletion and recovery, verified rights, and final release governance.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 1`.
- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:project-owner-display-profile` — provider `specs/08-project-participation#Task 34` — required before `Task 53`.
- `capability:project-participation-recipient-routing` — provider `specs/08-project-participation#Task 36` — required before `Task 54`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 1`.

Provides:

- `capability:guided-delivery-data-surfaces` — ready after `Task 54`.
- `capability:guided-delivery-notification-projection` — ready after `Task 54`.
- `capability:guided-delivery-artifact-preview-boundary` — ready after `Task 54`.
- `capability:guided-delivery-revocation-consumer` — ready after `Task 54`.
- `capability:guided-delivery-start-disclosure` — ready after `Task 54`.
- `capability:worker-artifact-upload-transport` — ready after `Task 55`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Existing task labels are preserved; newly split tasks use the next unused labels and are listed by dependency order rather than numeric order.

## Proof Scope Gate

- Applies to: Task 54, Task 55.

## Implementation Boundary

Included:

- The completed project board, guided readiness, explicit start, isolated run, worker, blocking-question resume, retry, cancellation, evidence, preview, review, same-run rejection continuation, and notification-projection foundation recorded by Tasks 1–36 and 43–53.
- Verification of that completed foundation under the current slice-scoped proof runner.
- Focused readiness write-back for the completed data, notification-projection, artifact and preview, revocation-consumer, and start-disclosure capabilities consumed by the child specifications.
- Shared product rules, child boundaries, and release coordination without duplicate child implementation.

Excluded:

- Multiple concurrent agents on one feature.
- Worker installation, provisioning, or provider setup UX.
- External notification channels.
- Automatic merge, default-branch writes, production deployment, or release management.
- General-purpose issue tracking and broad collaboration administration.
- Project-participant provisioning, invitations, membership changes, roles, access removal, and their management UI.
- Durable notification access and notification retention, owned by `specs/17-guided-delivery-notification-access/`.
- Processing inventory, support access, redaction, audit minimization, and no-secondary-use controls, owned by `specs/18-guided-delivery-data-protection-controls/`.
- Temporary execution-data and security-log retention, owned by `specs/19-guided-delivery-operational-retention/`.
- Device relay and cache retention, owned by `specs/20-guided-delivery-device-data-retention/`.
- Backup expiry, authoritative deletion, external cleanup, and reconciliation, owned by `specs/21-guided-delivery-deletion-and-recovery/`.
- Verified rights and historical anonymization, owned by `specs/22-guided-delivery-rights-and-anonymization/`.
- Deployment profile and deployment-specific privacy and security evidence validation, owned by `specs/23-guided-delivery-deployment-governance/`.
- Final capability coordination and `capability:guided-specification-delivery` readiness, owned by `specs/24-guided-delivery-completion/`.

Deferred after this slice:

- Multiple agent and model providers.
- Worker pools, scheduling policies, and cross-worker migration.
- Custom board workflows and organization-wide views.
- Email, chat, mobile, or webhook notifications.
- Merge, release, production deployment, rollback, and preview cleanup policies beyond the first configured path.
- `specs/17-guided-delivery-notification-access/` owns parent AC-41 and AC-43.
- `specs/18-guided-delivery-data-protection-controls/` owns parent AC-28 and AC-39 plus `entity:DataProcessingRecord`.
- `specs/19-guided-delivery-operational-retention/` owns parent AC-37 and AC-45.
- `specs/20-guided-delivery-device-data-retention/` owns parent AC-44.
- `specs/21-guided-delivery-deletion-and-recovery/` owns parent AC-46 and AC-47.
- `specs/22-guided-delivery-rights-and-anonymization/` owns parent AC-38.
- `specs/23-guided-delivery-deployment-governance/` owns `entity:DeploymentPrivacyProfile`, and `specs/24-guided-delivery-completion/` owns final capability coordination.
- Deferred criteria: AC-28, AC-37, AC-38, AC-39, AC-41, AC-43, AC-44, AC-45, AC-46, AC-47
- Deferred entities: entity:DataProcessingRecord, entity:DeploymentPrivacyProfile

Prerequisite:

- The shared project-storage, project-participation, and project-specification provider capabilities named above were delivered before their completed consumers.
- The focused continuations consume only the narrow foundation capabilities they need and declare their own storage-governance, participation-governance, and specification-governance dependencies rather than retaining unavailable future edges in this legacy plan.

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

- [x] Task 4 - Collect normalized required-check evidence.
  - Size: Standard
  - Purpose: Accept only worker-derived typed proof and preserve each evidence item immutably.
  - Owned surfaces: `Evidence`, hosted schema and migration, device-adapter value shape, versioned evidence event payload, schema and limit validation, worker command and exit provenance, run, attempt, command, branch, commit, source, time, duration, digest, applicability and redaction provenance, immutable supersession link, raw-provider-event and agent-prose denial, fixtures, and ingestion transaction.
  - Owns: entity:Evidence
  - Depends on: Task 21, Task 28
  - Proof: Focused migration, event schema, valid, invalid, stale, duplicate, out-of-order, oversized, unauthorized, worker-derived, agent-prose denial, immutability, supersession, hosted, and device tests pass.

- [x] Task 29 - Implement private evidence-artifact storage.
  - Size: Standard
  - Purpose: Store screenshots and larger approved proof privately through the authoritative project-storage boundary.
  - Owned surfaces: Private artifact-store behaviour, hosted and device adapters, project and evidence authorization, content type, byte-size and digest limits, encrypted or protected storage reference, redaction state, no public URL, no embedded credential, retrieval and deletion seam, fixtures, and deterministic adapter double.
  - Owns: none (artifact adapter)
  - Depends on: Task 4
  - Proof: Focused adapter-contract, authorization, content type, size, digest, storage, retrieval, deletion, public-link denial, credential scan, hosted, and device tests pass.

- [x] Task 52 - Deliver the authenticated worker artifact-upload transport.
  - Size: Standard
  - Purpose: Move captured artifact bytes from a worker into a hosted project's authoritative artifact store without putting them inside a normalized event.
  - Owned surfaces: Worker-initiated authenticated upload endpoint, run, attempt and current-fence scoping, declared content-type, size and digest verification before storage, artifact-store handoff, idempotent duplicate upload, unauthorized, cross-project, stale-attempt and device-authoritative denial, upload failure result, worker-side upload client, and fixtures.
  - Owns: none (upload transport)
  - Depends on: Task 19, Task 29
  - Proof: Focused authentication, attempt and fence scoping, digest verification, content-type, size-limit, duplicate-upload, cross-project denial, stale-attempt denial, device no-upload, artifact handoff, and failure-result tests pass.

- [x] Task 44 - Deliver conditional screenshot evidence.
  - Size: Standard
  - Purpose: Capture meaningful visual proof when supported and report inapplicability without fabricating evidence.
  - Owned surfaces: Visual-result applicability decision, configured capture capability, worker screenshot command result, exact attempt, branch and commit binding, uploaded-artifact reference binding, redaction state, unsupported and inapplicable result, capture failure, fixtures, and presentation metadata.
  - Owns: AC-20
  - Depends on: Task 29, Task 43, Task 52
  - Proof: Focused visual and non-visual work, supported, unsupported, inapplicable, failed capture, same-commit, artifact, redaction, and no-invented-evidence tests pass.

- [x] Task 30 - Enforce same-commit verification completion.
  - Size: Standard
  - Purpose: Permit a successful claim only when every configured required check proves the exact commit offered for review.
  - Owned surfaces: Required-check contract snapshot, complete result set, exact branch, revision and commit binding, passed, failed, missing and superseded evaluation, commit-change invalidation, screenshot applicability integration, success-claim gate, verified completion event, fixtures, and failure reason.
  - Owns: AC-19
  - Depends on: Task 4, Task 44
  - Proof: Focused complete, failed, missing, wrong-branch, wrong-revision, wrong-commit, later-commit, superseded, conditional screenshot, duplicate, and false-success tests pass.

- [x] Task 31 - Present verification evidence in feature activity.
  - Size: Standard
  - Purpose: Let authorized participants inspect required checks, screenshots, provenance, failures, and superseded proof.
  - Owned surfaces: Evidence activity entries, typed check and screenshot presentation, attempt, branch, commit, source, time, duration, digest and redaction metadata, passed, failed, missing, unsupported and superseded states, private artifact authorization, fixtures, and responsive accessible evidence UI.
  - Owns: AC-40
  - Depends on: Task 17, Task 30
  - Proof: Focused query, authorization, typed state, provenance, failure, missing, unsupported, supersession, private artifact, desktop, mobile, keyboard, and focus tests pass.

- [x] Task 5 - Deliver the ready-for-review handoff.
  - Size: Standard
  - Purpose: Move verified work to human review without allowing the agent to complete the feature.
  - Owned surfaces: Verified-completion consumption, `Ready for review` transition, agent-to-`Done` denial, current responsible participant and owner review responsibility, review-ready activity, preview-independent readiness, fixtures, and feature-detail state.
  - Owns: AC-23
  - Depends on: Task 30, Task 31
  - Proof: Focused verified, unverified, agent-denial, preview absent, preview failed, responsibility, transition, activity, and LiveView tests pass.

- [x] Task 32 - Implement the configured preview adapter and deployment lifecycle.
  - Size: Standard
  - Purpose: Start one authorized non-production preview for the exact verified commit without making it verification truth.
  - Owned surfaces: `PreviewDeployment`, hosted schema and migration, device-adapter value shape, configured preview-adapter behaviour, path and provider-reference authorization, external credential isolation, idempotent request, run, attempt, branch and verified-commit binding, status, timeout, expiry, supersession, cleanup command seam, safe link, fixtures, and adapter double.
  - Owns: AC-21, entity:PreviewDeployment
  - Depends on: Task 30
  - Proof: Focused migration, adapter, authorization, idempotency, exact commit, success, timeout, expiry, supersession, cleanup command, credential absence, safe link, hosted, and device tests pass.

- [x] Task 33 - Present preview availability and failure.
  - Size: Standard
  - Purpose: Show non-production preview status without blocking review readiness or inventing a link.
  - Owned surfaces: Preview unavailable, pending, ready, failed, timed-out, expired and superseded presentation, non-production label, safe-link authorization, failure reason, configured expiry and cleanup state, feature activity, fixtures, and responsive accessible UI.
  - Owns: AC-22
  - Depends on: Task 32
  - Proof: Focused no-path, pending, success, provider failure, timeout, expiry, supersession, safe-link, unauthorized-link, review-readiness independence, desktop, and mobile tests pass.

- [x] Task 34 - Deliver authorized review approval and rejection.
  - Size: Standard
  - Purpose: Reserve the final product decision for the current responsible participant or project owner.
  - Owned surfaces: `ReviewDecision`, hosted schema and migration, device-adapter value shape, review surface, current responsible participant and owner authorization, other-participant and agent denial, approval record and `Done` transition, rejection record and required feedback, reviewer identity, evidence and preview references, fixtures, and responsive accessible UI.
  - Owns: AC-24, AC-25, entity:ReviewDecision
  - Depends on: Task 5, Task 31
  - Proof: Focused migration, responsible, owner, other, agent, stale participant, approval, `Done`, rejection feedback requirement, evidence presentation, hosted, device, and browser tests pass.

- [x] Task 35 - Continue rejected work on the same run and branch.
  - Size: Standard
  - Purpose: Preserve review feedback and prior proof while starting one new attempt in `In development`.
  - Owned surfaces: Rejection-feedback activity, `In development` transition, same run, branch and workspace, next ordered attempt, continuation manifest and command, prior evidence and review preservation, contradictory-product-feedback block for specification write-back, idempotency, fixtures, and resumed-development status.
  - Owns: AC-26, AC-35
  - Depends on: Task 24, Task 34
  - Proof: Focused same-run, branch, workspace, ordered attempt, feedback, prior evidence, prior review, contradictory agreement, duplicate, rollback, command, activity, and status tests pass.

- [x] Task 36 - Project run events into minimized notifications.
  - Size: Standard
  - Purpose: Deliver blocked, review-ready, and terminal-failed events to the smallest current authorized recipient set.
  - Owned surfaces: Slice 07 `Notification` event types extending `AccountNotification`, at-least-once lifecycle-event consumption, blocked, review-ready and failed recipient matrices, delivery-time current-participation checks, role deduplication, unique event-type, run-state-version and recipient key, minimized body, event time, one safe feature link, replay and restart behavior, fixtures, and no external channel.
  - Owns: AC-27, entity:Notification
  - Depends on: Task 5, Task 22, Task 25, Task 35
  - Proof: Focused projector, blocked, review-ready, failed, stale recipient, duplicate role, replay, restart, minimized body, safe link, and negative external-channel tests pass.

- [x] Task 53 - Deliver project-scoped board navigation.
  - Size: Standard
  - Purpose: Let a participant reach the feature board from any project screen without knowing its address.
  - Owned surfaces: Project-scoped navigation across project screens, overview and features destinations, current-destination indication, repository-and-storage configuration test, configured-project default landing on the board, unconfigured-project fallback to the overview, label-independent landing, per-destination project authorization revalidation, cross-project isolation, keyboard and focus behaviour, fixtures, and responsive accessible navigation UI.
  - Owns: AC-48
  - Depends on: Task 2
  - Proof: Focused navigation, configuration test, default-landing, unconfigured-fallback, missing-label landing, authorization, cross-project isolation, current-destination, keyboard, focus, desktop, and mobile tests pass, including one proof that an owner reaching their configured board is not refused there.

- [x] Task 54 - Verify and publish the completed guided-delivery foundation contracts.
  - Size: Standard
  - Proof scope: Focused
  - Purpose: Reconcile the completed foundation under the current proof runner and publish its smallest stable child-consumer contracts without implementing any child-owned behavior.
  - Owned surfaces: `capability:guided-delivery-data-surfaces`, `capability:guided-delivery-notification-projection`, `capability:guided-delivery-artifact-preview-boundary`, `capability:guided-delivery-revocation-consumer`, and `capability:guided-delivery-start-disclosure` providers and readiness write-back; completed-task proof reconciliation; provider-contract compatibility; and child handoff fixtures.
  - Owns: none (foundation verification gate)
  - Depends on: Task 33, Task 36, Task 46, Task 53
  - Proof: Focused specification, capability-contract, completed-surface compatibility, notification-projection, artifact and preview, revocation-consumer, and start-disclosure handoff checks pass through task scope before readiness is recorded. Full repository, browser, security, production, and live-smoke checks remain in the slice verification gate.

- [x] Task 55 - Correct worker artifact-upload attempt scoping to match the wire protocol.
  - Size: Standard
  - Proof scope: Focused
  - Purpose: Prove upload attempt-currency the same way the worker protocol actually lets a worker prove anything — by run and fence — since no envelope a worker ever receives carries a `RunAttempt`'s real database identity for it to declare.
  - Owned surfaces: `capability:worker-artifact-upload-transport`; `Delivery.ArtifactUpload.accept/3`'s request parsing and current-attempt proof (drop the caller-declared `attempt_id` field and its exact-match check, keep and rely on the existing current-fence proof); `Delivery.Worker.ArtifactUpload`'s `capture()` contract and upload declaration (drop `attempt_id`); `WorkerArtifactController`'s moduledoc and param handling; and the existing Task 52/Task 29 fixtures and tests that assert the old `attempt_id` shape.
  - Owns: none (upload transport correction)
  - Depends on: Task 52
  - Proof: Focused tests prove an upload naming the run's current attempt only by run and current fence is accepted and stored identically to before, that a stale or superseded fence is refused exactly as `:stale_fence` already was, that every other existing denial (unauthorized worker, cross-project, device-authoritative, digest mismatch, oversized, unsupported type) is unchanged, and that the worker-side `capture()`/request contract no longer requires or sends an `attempt_id`.

## Verification Gate

- [x] Completed board, readiness, orchestration, worker, recovery, evidence, preview, review, navigation, and notification-projection acceptance criteria pass without child-owned lifecycle or rights proof being implied.
- [x] Hosted PostgreSQL and worker-owned device delivery-store, protocol, command, lease, fence, reconciliation, and no-hosted-device-copy contracts pass.
- [x] Exact-revision, same-commit evidence, conditional screenshot, private artifact, preview, and human-review contracts pass.
- [x] Blocked, ready-for-review, and terminal-failed notification projection passes recipient, current-participation, deduplication, minimization, replay, restart, safe-link-reference, and no-external-channel proof.
- [x] Desktop and mobile board, feature, activity, blocked, review, and completion scenarios pass.
- [x] `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass through slice scope.
- [x] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass through slice scope.
- [x] Live configured worker and coding-agent smoke proofs pass, or remain explicitly environment-blocked without weakening deterministic adapter proof.
- [x] The individual specification validator and global capability graph pass, and every published foundation capability has a Task 54 readiness write-back.
- [x] Child-owned criteria and entities remain classified without duplicate ownership.

## Blocked Decisions

- None.

## Release Gate

- Deployment-specific controller details, worker, model, preview, and infrastructure processors, regions, transfer safeguards, notices, incident handling, and enforced retention evidence.
- Deployment-specific provider retention and model-training-use settings, processor agreements, support-access procedure, deletion propagation, and any required DPIA evidence.
- Live configured preview-provider request, access, status, expiry, and cleanup smoke proof when previews are enabled for the deployment.
- Final accountable privacy or legal review for the configured deployment and its subprocessors.

## Progress Log

See [progress.md](progress.md).
