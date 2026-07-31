# Guided Specification And Delivery

## Status

Approved

## Outcome

A developer or non-developer can turn a feature idea into development-ready requirements on a specification-focused board, explicitly start an AI coding agent, answer blocking questions, and receive a verified implementation with evidence and a preview link when the project supports one.

## Users

- Business analysts, product owners, and product managers defining features without needing strong software-engineering skills.
- Developers defining or reviewing requirements and implementation evidence.
- Feature creators and assigned participants receiving questions about stories they own or are responsible for.
- Authorized project participants answering product questions raised during an agent run.
- Project reviewers deciding whether completed work is acceptable.

## Primary Workflow

1. The user opens a project and creates a feature on its specification-focused Kanban board.
2. The product explains the information and format needed for that feature and helps the user structure the requirements.
3. The AI identifies missing, ambiguous, or conflicting product information, distinguishes blocking findings from non-blocking suggestions, and explains what prevents development readiness.
4. The user resolves every blocking finding and may resolve or dismiss non-blocking suggestions.
5. When no blocking finding remains, the feature is visibly marked development-ready and an explicit `Start development` action becomes available with the configured execution location, agent or model provider, preview provider when configured, and whether project content leaves its authoritative device or hosted store.
6. A current participant confirms the configured processing boundary when it is new or changed and starts development, and an authorized coding agent runs on the configured local or remote worker against an isolated feature branch.
7. The agent implements the approved scope, runs the required checks, captures screenshots when supported, and posts progress and evidence to the feature activity.
8. If a product decision blocks progress, the run pauses, the feature is marked blocked, and the focused question tags the assigned participant when one exists or the feature creator otherwise.
9. An accepted answer is written back to the specification, and the same run resumes from its preserved state.
10. A transient execution failure retries the same run with bounded backoff while preserving its branch, workspace, and accepted progress; an exhausted or non-retryable failure leaves the feature in `In development` with a visible `Failed` status.
11. When implementation and verification finish, the agent posts the result, test evidence, and available screenshots to the feature.
12. After verification succeeds, the product automatically starts a branch preview when the project has a preconfigured and authorized preview path, then attaches the test link when deployment succeeds.
13. The feature moves to `Ready for review`, and the product sends an in-product notification that the run finished and exposes its evidence, branch, preview link when available, or visible preview failure.
14. An authorized user reviews the result and explicitly approves it before the feature moves to `Done`.
15. If the authorized reviewer rejects the result, the review feedback is attached to the feature, which returns to `In development` and continues the same run and branch as a new attempt.

## In Scope

- A project-level Kanban board organized around specification and delivery state.
- Consumption of the shared project-specification identity, immutable revision, current-snapshot, and append interfaces.
- Five first-release board columns: `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`.
- Visible `Blocked` and `Failed` statuses that do not create separate board columns.
- Guided feature requirement structure for technical and non-technical users.
- AI identification of missing, ambiguous, or conflicting product information.
- Visible development-readiness status and reasons.
- Explicit user-controlled development start.
- Coding-agent execution through a configured local or remote worker.
- Branch-isolated implementation.
- Automated checks and test execution required by the project.
- Screenshot evidence when the application type and execution environment support it.
- Progress, questions, answers, results, and evidence in feature activity and comments.
- Required `Creator` and optional `Assigned` fields for each feature, with participant assignment controls and an `Assign to me` action.
- Durable blocked state, user tagging, accepted-answer write-back, and run resumption.
- Bounded automatic retry, terminal failure presentation, authorized manual retry, cancellation recovery, and same-run review-rejection continuation.
- Branch preview deployment and test-link attachment when supported.
- In-product action-required and completion notifications.
- Human review, explicit approval before a feature is considered done, and feedback-based rejection to resumed development.
- Pre-start processing-boundary disclosure and change-triggered confirmation.
- GDPR data protection and lifecycle rules for specifications, comments, runs, evidence, notifications, credentials, and deployment metadata.

## Out of Scope

- General-purpose issue tracking unrelated to specification and delivery.
- Repository, identity, storage, and portability onboarding already owned by `specs/01-` through `specs/06-`.
- Automatic merge to the default branch.
- Production deployment.
- Project-participant provisioning, invitations, membership changes, roles, and removal, which require a separate focused project-participation specification.
- Defining a second project-specification identity, revision schema, or authoritative document store outside the shared project-specification capability.
- Worker installation, provisioning, provider authentication, and model-selection experiences.
- Self-service privacy-rights screens; the first release may use the existing verified operator workflow.
- Billing, subscriptions, or usage purchasing.
- Support for every application-specific screenshot or preview environment in the first executable slice.

## Business Rules

- The board represents feature specification and delivery state, not a generic task list.
- The first-release board has exactly five lifecycle columns: `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`.
- `Blocked` and `Failed` are visible statuses, not lifecycle columns. A blocked or terminally failed development run remains in `In development` while showing why it cannot continue.
- Cards cannot be freely dragged between lifecycle columns. A feature changes columns only through the workflow's gated actions and validated outcomes.
- A participant reaches the feature board through project-scoped navigation present on every project screen, without needing to know or type its address. A project whose repository connection and storage are established opens on its board; one still missing them opens on its overview, because setup must be completed before delivery work can begin. A participant's project display label is presentation, not configuration: its absence must never be read as missing authorization or divert this landing.
- A user interaction must not bypass specification readiness, explicit development start, successful verification, or authorized review.
- Every feature has a required `Creator` field and an optional `Assigned` field; the two fields may identify different authorized participants.
- The current responsible participant is the current participant in `Assigned` when present, otherwise the current participant in `Creator`, with the project owner as the fail-closed fallback when neither remains authorized or a participation-removal handoff routes pending responsibility to the owner.
- Creator, assignment, notification, run-control, and review authorization consume the current authorized participants supplied by the separate project-participation boundary; this workflow cannot create, invite, grant, revoke, or otherwise change project participation.
- Current participant selectors, responsibility labels, and notifications use the project-specific display name from the participation boundary and must not expose another participant's email.
- A stale or unauthorized participant must fail closed at action and notification-delivery time without exposing project content.
- When an assigned or otherwise responsible participant leaves or is removed, the participation handoff clears current assignment, routes pending blocking-question and review responsibility to the immutable project owner, preserves prior contributions under the last accepted project display name as non-interactive historical attribution, and leaves any active agent run under owner control rather than canceling it automatically.
- Any authorized project participant may set or change `Assigned` to any authorized participant in the same project.
- `Assign to me` must set `Assigned` to the authorized participant performing the action.
- A blocking question must tag the participant in `Assigned` when that field has a value; when it does not, the question must tag the feature creator.
- If the assigned participant or feature creator is no longer authorized, pending action must route to the current project owner rather than to the former participant.
- AI guidance must explain what information is expected and why a missing or conflicting item blocks readiness.
- Readiness must be based on the current recorded requirements and must expose unresolved items; it cannot be a hidden score.
- Every readiness finding must be visibly classified as blocking or non-blocking.
- A blocking finding cannot be dismissed or overridden, and `Start development` must remain unavailable until every blocking finding is resolved.
- An authorized user may dismiss a non-blocking suggestion without preventing the feature from becoming development-ready.
- Before `Start development`, the feature must identify whether execution is local or remote, the configured agent or model provider, the configured preview provider when present, and whether specifications, source context, prompts, outputs, evidence, or other project content leave the authoritative device or hosted store.
- The participant must confirm that processing boundary before the first run and again only when the disclosed execution, provider, or data-transfer boundary changes.
- Development must never start automatically when a feature becomes ready; any current authorized project participant may explicitly start it.
- Only the current run initiator or the project owner may cancel an active run. A former initiator loses cancellation authority when participation ends, and the owner retains control.
- Cancellation preserves the canceled run, branch identity, activity, and evidence as governed history. It returns the feature to `Ready for development` when its current revision still satisfies readiness and to `Draft` otherwise.
- Starting after cancellation creates a new run against the then-current approved revision and a new isolated branch; it does not resume the canceled run.
- The run must use the approved specification and active implementation slice as its scope.
- Feature guidance, accepted-answer write-back, readiness, and run binding must consume `capability:project-specification-store`; this slice may append revisions through that interface but cannot create a second authoritative specification store.
- An agent must not silently invent or change a product requirement during implementation.
- When a product decision is required, the run pauses and asks one focused question with enough context for the tagged users to answer.
- An accepted blocking answer must be written back to the specification before the run resumes.
- A paused run must preserve its branch, workspace, progress, evidence, and pending question so accepted work is not repeated unnecessarily.
- A retryable worker, transport, provider, or execution failure retries the same run with bounded backoff and preserves its branch, workspace, checkpoint, progress, and evidence.
- A non-retryable failure or exhausted automatic retry budget leaves the feature in `In development` with a visible `Failed` status and reason. It sends the failed-run notification only after that terminal state is recorded.
- Any current authorized project participant may manually retry a failed run. Manual retry continues the same run and branch as a new attempt; cancellation followed by `Start development` is the path to a new run.
- Implementation runs occur on isolated branches and must not write directly to the default branch.
- The feature activity must distinguish agent progress, user comments, blocking questions, accepted answers, verification evidence, preview deployments, and final outcomes.
- A successful claim requires the project’s required verification to pass. Missing or failed proof must remain visible and must not be represented as successful completion.
- Successful agent execution and verification move the feature to `Ready for review`; an agent cannot move a feature directly to `Done`.
- Only the current responsible participant or the project owner may approve a feature in `Ready for review` and move it to `Done`.
- Until authorized approval occurs, the feature must remain outside `Done` even when all agent work and verification have finished.
- Only the current responsible participant or the project owner may reject a feature in `Ready for review`; the rejection must record review feedback, return the feature to `In development`, and continue the same run and branch as a new attempt with prior evidence and feedback preserved.
- A preview deployment starts automatically after successful verification only when the project has a preconfigured and authorized branch-preview path.
- Preview deployments are non-production and must identify the branch and run that produced them.
- Preview failure must remain visible with its reason but must not prevent an otherwise successfully verified feature from reaching `Ready for review`.
- In-product notifications are the only notification channel in the first release. Email, chat, mobile, and webhook delivery are deferred.
- Every run must present the configured required-check results and the identity of the isolated branch and exact verified revision. Missing or failed required checks, or missing branch and revision identity, prevent a successful completion claim.
- Screenshots are mandatory evidence only when the feature has a visual result and the configured environment can capture a meaningful view. The configured worker capture step reports which case applies as one typed result — captured, inapplicable, unsupported, or failed — and neither an agent narrative nor a stored feature flag decides it. A preview link is evidence only when the project has the authorized preview path.
- Evidence artifacts a worker captures reach a hosted project's authoritative store through a worker-initiated authenticated upload bound to that run attempt, after which the worker's normalized event carries only the digest and metadata. A device-authoritative project's artifacts stay in the worker-owned store and are never uploaded.
- A blocked notification goes to the current responsible participant.
- A ready-for-review notification goes to the current responsible participant and project owner.
- A failed-run notification goes to the current run initiator, current responsible participant, and project owner.
- Notification recipients must be current authorized participants at delivery time, and a person who matches more than one recipient role receives one notification for the event.
- A run notification must state whether the run is ready for review, failed, or remains blocked and link back to its available evidence.
- Secrets used by repositories, agents, workers, model providers, notifications, or deployments must not appear in requirements, comments, evidence, screenshots, logs exposed to users, or analytics.
- Core project, identity, source-context, prompt, output, evidence, review, and notification processing is limited to providing the participant-requested specification and delivery workflow under the approved contract-necessity basis. Minimum security processing is limited to the documented service-security purpose and approved legitimate-interest assessment.
- Slice 07 data must not be reused for advertising, model training, unrelated product improvement, or another secondary purpose. Slice 07 collects no product analytics; operational metrics and logs remain governed personal data and cannot become analytics.
- Active feature, specification, normalized activity, minimal run and attempt metadata, accepted evidence, review decisions, and historical attribution are retained only while the active project requires them.
- Raw provider events are not persisted. Temporary command payloads, checkpoints, provider-thread references, transient logs, and superseded artifacts are deleted within 30 days after they are no longer active; notifications are deleted within 90 days; hosted relay and cache data for device-authoritative projects is deleted within 24 hours; operational-security logs are deleted within 30 days; and encrypted rolling backups expire within 35 days.
- Project deletion ends access immediately, removes authoritative active copies through the selected storage boundary, requests configured preview and external-artifact cleanup, and leaves only backup copies until their approved expiry. A failed external cleanup remains visible for reconciliation and cannot restore project access.
- Current project participants receive only their approved project-scoped access. Support or operations access is verified, least-privilege, time-bounded, purpose-limited, and audited, with project content excluded by default.
- The verified rights workflow must support applicable access, correction, export or portability, erasure, restriction, and objection across authoritative records, artifacts, notifications, caches, logs, and configured processors. Historical attribution retains the last project display name only while necessary for project accountability and is anonymized when continued identification is no longer necessary.
- Local device-authoritative data stays under the operating-system boundary unless the disclosed configured worker, model provider, or preview path requires an approved transfer. Hosted relays must not create a durable device-project copy.
- Workers, model providers, preview providers, artifact stores, hosting, backups, and support services are processors or other recipients only as classified by the actual deployment contract. Raw credentials remain outside project records and provider-side retention or training must match the approved deployment configuration.

## Acceptance Criteria

- [AC-01] Given a user opens the first-release project board, when its lifecycle columns are shown, then they are `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`.
- [AC-02] Given an active development run needs a product decision, when the run becomes blocked, then the feature remains in `In development`, displays a visible `Blocked` status and reason, and does not move to a separate blocked column.
- [AC-03] Given a user attempts to drag a card to another lifecycle column, when the board handles the interaction, then the feature state does not change and no workflow gate is bypassed.
- [AC-04] Given a draft feature has no remaining blocking finding, when the authorized readiness outcome commits, then the board moves the feature to `Ready for development`; direct or stale state changes remain rejected.
- [AC-05] Given a feature's `Assigned` field identifies a participant, when the agent posts a blocking question, then that participant is tagged even when `Creator` identifies someone else.
- [AC-06] Given a feature's `Assigned` field is empty, when the agent posts a blocking question, then the participant in `Creator` is tagged.
- [AC-07] Given an authorized project participant chooses another authorized participant for `Assigned`, when the assignment is saved, then the story is assigned to that selected participant.
- [AC-08] Given an authorized project participant selects `Assign to me`, when the action succeeds, then `Assigned` identifies that participant.
- [AC-09] Given a user creates a feature, when guided specification begins, then the product shows the expected requirement structure and identifies missing or unclear product information in understandable language.
- [AC-10] Given one or more blocking findings remain, when readiness is evaluated, then the feature is not marked development-ready, each blocker remains visible, and `Start development` is unavailable.
- [AC-11] Given an authorized user tries to dismiss a blocking finding, when the action is evaluated, then the blocker remains active and development cannot start.
- [AC-12] Given a readiness finding is non-blocking, when an authorized user dismisses it, then the suggestion no longer prevents readiness.
- [AC-13] Given every blocking finding is resolved, when readiness is evaluated, then the feature is marked development-ready and `Start development` becomes available to every current authorized project participant.
- [AC-14] Given development has not been explicitly started, when a feature becomes ready, then no coding agent or deployment begins automatically.
- [AC-15] Given any current authorized project participant starts a ready feature, when the run begins, then the agent works from the approved scope on an isolated branch through the configured worker.
- [AC-16] Given the agent can continue without product input, when it implements the feature, then normalized progress appears in the feature activity without exposing raw provider events or secrets.
- [AC-17] Given the agent reaches a product decision it cannot safely make, when it becomes blocked, then the run pauses, preserves its state, tags the relevant users, and posts one focused question.
- [AC-18] Given a tagged user provides an accepted answer, when the answer is written back to the specification, then the same run can resume without silently discarding completed work.
- [AC-19] Given configured required verification fails, branch or exact verified-revision identity is missing, or required evidence is unavailable, when the run reports its result, then the feature does not claim successful completion and the missing or failed evidence remains visible.
- [AC-20] Given a feature has a visual result and the configured environment supports meaningful capture, when verification finishes, then screenshots are attached to the feature evidence; otherwise screenshot absence is reported without inventing evidence.
- [AC-21] Given a preconfigured and authorized web-preview path and successful verification, when delivery finishes, then the branch preview starts automatically and its test link is attached when deployment succeeds.
- [AC-22] Given no authorized preview path exists or preview deployment fails, when delivery finishes, then the absence or failure remains visible and an otherwise successfully verified feature can still reach `Ready for review` without presenting a nonexistent link.
- [AC-23] Given implementation and required verification succeed, when the agent run finishes, then the feature moves to `Ready for review` rather than `Done`.
- [AC-24] Given a feature is `Ready for review`, when a participant other than the current responsible participant or project owner, or an agent, attempts to approve or reject it, then the transition is rejected.
- [AC-25] Given the current responsible participant or project owner approves a feature in `Ready for review`, when approval is recorded, then the feature moves to `Done`.
- [AC-26] Given the current responsible participant or project owner rejects a feature in `Ready for review`, when the rejection and feedback are recorded, then the feedback appears in the feature activity, the feature returns to `In development`, and the same run and branch continue as a new attempt with prior evidence preserved.
- [AC-27] Given a run becomes blocked, ready for review, or terminally failed, when in-product notifications are projected, then blocked reaches the current responsible participant, ready for review reaches the current responsible participant and project owner, failed reaches the current run initiator, current responsible participant, and project owner, duplicate roles produce one notification per person, stale recipients receive none, and each minimized notification carries one safe feature link.
- [AC-28] Given specifications, comments, runs, questions, evidence, previews, notifications, credentials, or deployment metadata are processed, when access, retention, deletion, logging, or analytics behavior runs, then the approved data contract is enforced, secrets and unauthorized project content are not exposed, and analytics remain aggregate and genuinely anonymous.
- [AC-29] Given an identity is not a current authorized project participant, when assignment, notification delivery, run control, review, or project-content access is evaluated, then the action fails closed, no participation state changes, and no project content is exposed.
- [AC-30] Given a participant with current assignment, pending blocking-question or review responsibility, historical contributions, or an active run leaves or is removed, when Slice 07 idempotently consumes the versioned `ParticipationRevocation` handoff, then current assignment clears, pending responsibility routes to the project owner, prior contributions retain the last accepted project display name as non-interactive attribution, the run remains active under owner control, the handoff is acknowledged, and the former participant receives no further access.
- [AC-31] Given a current participant appears in assignment, responsibility, notification, activity, or review presentation, when Slice 07 renders their identity, then it uses the project-specific display name and exposes no other participant email.
- [AC-32] Given an active run, when its current initiator or the project owner cancels it, then cancellation is accepted; when any other participant or a former initiator attempts cancellation, then the action is rejected and the run remains under its current control.
- [AC-33] Given an active run is canceled, when cancellation commits, then its history and evidence remain governed records and the feature returns to `Ready for development` if the current revision remains ready or to `Draft` otherwise; a later start creates a new run and isolated branch.
- [AC-34] Given a retryable execution failure, when recovery is evaluated, then the same run retries with bounded backoff and preserves its branch, workspace, checkpoint, progress, and evidence; given the failure is non-retryable or the automatic budget is exhausted, then the feature remains in `In development` with visible `Failed` status until any current participant retries the same run or an authorized cancellation ends it.
- [AC-35] Given a feature is rejected from `Ready for review`, when development resumes, then the same run and branch begin a new attempt with the rejection feedback and prior evidence available.
- [AC-36] Given a feature is ready for development, when a participant opens the start action, then the product shows the configured execution location, agent or model provider, preview provider when configured, and whether project content leaves its authoritative store; the participant confirms before the first run and again only after that boundary changes.
- [AC-37] Given temporary command payloads, checkpoints, provider-thread references, transient logs, or superseded artifacts are no longer active, when retention enforcement runs, then those records are deleted within 30 days without removing accepted evidence or active execution state.
- [AC-38] Given a verified person exercises an applicable data right, when the operator workflow runs, then authorized project, identity, contribution, run, evidence, notification, artifact, cache, log, backup, and processor records are exported, corrected, restricted, objected to, erased, or anonymized as required without exposing another participant's data or erasing necessary project accountability.
- [AC-39] Given Slice 07 processing, browser traffic, worker exchange, provider configuration, stored records, logs, or metrics are inspected, when purpose limitation is verified, then no product analytics, advertising, model-training reuse, unrelated secondary use, raw credential, or unauthorized durable device-project copy exists.
- [AC-40] Given required checks or supported screenshots are collected, when the feature activity presents verification evidence, then each item is typed, immutable, authorized, bound to its run, attempt, branch, commit, source, and redaction state, and superseded or missing proof remains visible.
- [AC-41] Given an authorized recipient is offline, reconnects, marks a notification read, or later loses project participation, when notification state is evaluated, then unread delivery survives restart without PubSub, mark-read is idempotent, and list, read, and safe-link access fail closed for a removed recipient.
- [AC-42] Given a current authorized participant posts a feature comment, when the activity transaction commits, then the comment appears once in project order under that participant's project display name; stale or unauthorized input is rejected without exposing another participant email or project content.
- [AC-43] Given a Slice 07 in-product notification reaches its approved lifecycle boundary, when retention enforcement runs, then the notification is deleted within 90 days without changing feature, run, or participant authorization state.
- [AC-44] Given hosted relay or cache data exists for a device-authoritative project, when retention enforcement runs, then the data is deleted within 24 hours and no durable hosted device-project copy remains.
- [AC-45] Given Slice 07 operational-security logs reach their approved lifecycle boundary, when retention enforcement runs, then logs contain only approved minimum fields, expose no raw credential or unauthorized project content, and are deleted within 30 days.
- [AC-46] Given Slice 07 data enters encrypted rolling backups, when lifecycle enforcement runs, then those copies expire within 35 days and cannot restore deleted access outside the approved recovery process.
- [AC-48] Given an authorized participant opens a project whose repository connection and storage are established, when the project screen renders, then the feature board is the default view and project-scoped navigation moves them between the project overview and the board without typing an address; a project still missing that configuration opens on its overview instead, and a member's missing presentation label never causes either outcome.
- [AC-47] Given a project is deleted, when authoritative and external cleanup runs, then access ends immediately, hosted or device active copies are removed, configured preview, artifact, cache, index, and processor cleanup is requested, and any failed external cleanup remains restricted and visibly queued for reconciliation without restoring access.

## Open Questions

None.
