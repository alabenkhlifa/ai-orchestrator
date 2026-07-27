# Guided Specification And Delivery

## Status

Draft

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
5. When no blocking finding remains, the feature is visibly marked development-ready and an explicit `Start development` action becomes available.
6. The user starts development, and an authorized coding agent runs on the configured local or remote worker against an isolated feature branch.
7. The agent implements the approved scope, runs the required checks, captures screenshots when supported, and posts progress and evidence to the feature activity.
8. If a product decision blocks progress, the run pauses, the feature is marked blocked, and the focused question tags the assigned participant when one exists or the feature creator otherwise.
9. An accepted answer is written back to the specification, and the same run resumes from its preserved state.
10. When implementation and verification finish, the agent posts the result, test evidence, and available screenshots to the feature.
11. After verification succeeds, the product automatically starts a branch preview when the project has a preconfigured and authorized preview path, then attaches the test link when deployment succeeds.
12. The feature moves to `Ready for review`, and the product sends an in-product notification that the run finished and exposes its evidence, branch, preview link when available, or visible preview failure.
13. An authorized user reviews the result and explicitly approves it before the feature moves to `Done`.
14. If the authorized reviewer rejects the result, the review feedback is attached to the feature, which returns to `In development` so work can resume.

## In Scope

- A project-level Kanban board organized around specification and delivery state.
- Five first-release board columns: `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`.
- A visible `Blocked` status that does not create a separate board column.
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
- Branch preview deployment and test-link attachment when supported.
- In-product action-required and completion notifications.
- Human review, explicit approval before a feature is considered done, and feedback-based rejection to resumed development.
- GDPR data protection and lifecycle rules for specifications, comments, runs, evidence, notifications, credentials, and deployment metadata.

## Out of Scope

- General-purpose issue tracking unrelated to specification and delivery.
- Repository, identity, storage, and portability onboarding already owned by `specs/01-` through `specs/06-`.
- Automatic merge to the default branch.
- Production deployment.
- Project-participant provisioning, invitations, membership changes, roles, and removal, which require a separate focused project-participation specification.
- Worker installation, provisioning, provider authentication, and model-selection experiences.
- Billing, subscriptions, or usage purchasing.
- Support for every application-specific screenshot or preview environment in the first executable slice.

## Business Rules

- The board represents feature specification and delivery state, not a generic task list.
- The first-release board has exactly five lifecycle columns: `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`.
- `Blocked` is a visible status, not a lifecycle column. A blocked development run remains in `In development` while showing why it cannot continue.
- Cards cannot be freely dragged between lifecycle columns. A feature changes columns only through the workflow's gated actions and validated outcomes.
- A user interaction must not bypass specification readiness, explicit development start, successful verification, or authorized review.
- Every feature has a required `Creator` field and an optional `Assigned` field; the two fields may identify different authorized participants.
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
- Development must never start automatically when a feature becomes ready; an authorized user explicitly starts it.
- The run must use the approved specification and active implementation slice as its scope.
- An agent must not silently invent or change a product requirement during implementation.
- When a product decision is required, the run pauses and asks one focused question with enough context for the tagged users to answer.
- An accepted blocking answer must be written back to the specification before the run resumes.
- A paused run must preserve its branch, workspace, progress, evidence, and pending question so accepted work is not repeated unnecessarily.
- Implementation runs occur on isolated branches and must not write directly to the default branch.
- The feature activity must distinguish agent progress, user comments, blocking questions, accepted answers, verification evidence, preview deployments, and final outcomes.
- A successful claim requires the project’s required verification to pass. Missing or failed proof must remain visible and must not be represented as successful completion.
- Successful agent execution and verification move the feature to `Ready for review`; an agent cannot move a feature directly to `Done`.
- Only an authorized user may approve a feature in `Ready for review` and move it to `Done`.
- Until authorized approval occurs, the feature must remain outside `Done` even when all agent work and verification have finished.
- An authorized reviewer may reject a feature in `Ready for review`; the rejection must record review feedback, return the feature to `In development`, and make the feedback available when work resumes.
- A preview deployment starts automatically after successful verification only when the project has a preconfigured and authorized branch-preview path.
- Preview deployments are non-production and must identify the branch and run that produced them.
- Preview failure must remain visible with its reason but must not prevent an otherwise successfully verified feature from reaching `Ready for review`.
- In-product notifications are the only notification channel in the first release. Email, chat, mobile, and webhook delivery are deferred.
- Every run must present the configured required-check results and the identity of the isolated branch and exact verified revision. Missing or failed required checks, or missing branch and revision identity, prevent a successful completion claim.
- Screenshots are mandatory evidence only when the feature has a visual result and the configured environment can capture a meaningful view. A preview link is evidence only when the project has the authorized preview path.
- A completion notification must state whether the run is ready for review, failed, or remains blocked and link back to its available evidence.
- Secrets used by repositories, agents, workers, model providers, notifications, or deployments must not appear in requirements, comments, evidence, screenshots, logs exposed to users, or analytics.
- Personal data and project content must follow approved purpose, access, retention, deletion, rights, processor, transfer, and security rules.
- Analytics must remain aggregate and genuinely anonymous under the project-wide privacy contract.

## Acceptance Criteria

- [AC-01] Given a user opens the first-release project board, when its lifecycle columns are shown, then they are `Draft`, `Ready for development`, `In development`, `Ready for review`, and `Done`.
- [AC-02] Given an active development run needs a product decision, when the run becomes blocked, then the feature remains in `In development`, displays a visible `Blocked` status and reason, and does not move to a separate blocked column.
- [AC-03] Given a user attempts to drag a card to another lifecycle column, when the board handles the interaction, then the feature state does not change and no workflow gate is bypassed.
- [AC-04] Given a feature satisfies the next workflow gate, when the corresponding authorized action or validated outcome occurs, then the board moves the feature to the resulting lifecycle column.
- [AC-05] Given a feature's `Assigned` field identifies a participant, when the agent posts a blocking question, then that participant is tagged even when `Creator` identifies someone else.
- [AC-06] Given a feature's `Assigned` field is empty, when the agent posts a blocking question, then the participant in `Creator` is tagged.
- [AC-07] Given an authorized project participant chooses another authorized participant for `Assigned`, when the assignment is saved, then the story is assigned to that selected participant.
- [AC-08] Given an authorized project participant selects `Assign to me`, when the action succeeds, then `Assigned` identifies that participant.
- [AC-09] Given a user creates a feature, when guided specification begins, then the product shows the expected requirement structure and identifies missing or unclear product information in understandable language.
- [AC-10] Given one or more blocking findings remain, when readiness is evaluated, then the feature is not marked development-ready, each blocker remains visible, and `Start development` is unavailable.
- [AC-11] Given an authorized user tries to dismiss a blocking finding, when the action is evaluated, then the blocker remains active and development cannot start.
- [AC-12] Given a readiness finding is non-blocking, when an authorized user dismisses it, then the suggestion no longer prevents readiness.
- [AC-13] Given every blocking finding is resolved, when readiness is evaluated, then the feature is marked development-ready and an authorized user can explicitly start development.
- [AC-14] Given development has not been explicitly started, when a feature becomes ready, then no coding agent or deployment begins automatically.
- [AC-15] Given an authorized user starts a ready feature, when the run begins, then the agent works from the approved scope on an isolated branch through the configured worker.
- [AC-16] Given the agent can continue without product input, when it implements the feature, then progress and verification evidence appear in the feature activity.
- [AC-17] Given the agent reaches a product decision it cannot safely make, when it becomes blocked, then the run pauses, preserves its state, tags the relevant users, and posts one focused question.
- [AC-18] Given a tagged user provides an accepted answer, when the answer is written back to the specification, then the same run can resume without silently discarding completed work.
- [AC-19] Given configured required verification fails, branch or exact verified-revision identity is missing, or required evidence is unavailable, when the run reports its result, then the feature does not claim successful completion and the missing or failed evidence remains visible.
- [AC-20] Given a feature has a visual result and the configured environment supports meaningful capture, when verification finishes, then screenshots are attached to the feature evidence; otherwise screenshot absence is reported without inventing evidence.
- [AC-21] Given a preconfigured and authorized web-preview path and successful verification, when delivery finishes, then the branch preview starts automatically and its test link is attached when deployment succeeds.
- [AC-22] Given no authorized preview path exists or preview deployment fails, when delivery finishes, then the absence or failure remains visible and an otherwise successfully verified feature can still reach `Ready for review` without presenting a nonexistent link.
- [AC-23] Given implementation and required verification succeed, when the agent run finishes, then the feature moves to `Ready for review` rather than `Done`.
- [AC-24] Given a feature is `Ready for review`, when an unauthorized user or an agent attempts to mark it `Done`, then the transition is rejected.
- [AC-25] Given an authorized user approves a feature in `Ready for review`, when approval is recorded, then the feature moves to `Done`.
- [AC-26] Given an authorized reviewer rejects a feature in `Ready for review`, when the rejection and feedback are recorded, then the feedback appears in the feature activity, the feature returns to `In development`, and work can resume.
- [AC-27] Given a run requires user action or reaches a terminal outcome, when notification is delivered, then an in-product notification states whether the run is blocked, ready for review, or failed and links to its available branch, exact revision, evidence, and preview when available.
- [AC-28] Given specifications, comments, runs, questions, evidence, previews, notifications, credentials, or deployment metadata are processed, when access, retention, deletion, logging, or analytics behavior runs, then the approved data contract is enforced, secrets and unauthorized project content are not exposed, and analytics remain aggregate and genuinely anonymous.
- [AC-29] Given an identity is not a current authorized project participant, when assignment, notification delivery, run control, review, or project-content access is evaluated, then the action fails closed, no participation state changes, and no project content is exposed.
- [AC-30] Given a participant with current assignment, pending blocking-question or review responsibility, historical contributions, or an active run leaves or is removed, when Slice 07 consumes the participation handoff, then current assignment clears, pending responsibility routes to the project owner, prior contributions retain the last accepted project display name as non-interactive attribution, the run remains active under owner control, and the former participant receives no further access.
- [AC-31] Given a current participant appears in assignment, responsibility, notification, activity, or review presentation, when Slice 07 renders their identity, then it uses the project-specific display name and exposes no other participant email.

## Open Questions

- Which authorized project participants receive blocked, ready-for-review, and failed in-product notifications?
- Which authorized project participants may start, cancel, approve, and reject an agent run in the first release?
