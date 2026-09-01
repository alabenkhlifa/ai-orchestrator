# Feature Delivery From The Product UI Design

## Context

The domain for the core loop exists and the product cannot reach it. `Delivery.Start.start/4` and `Start.available?/3` have no caller under `lib/`. `Features.transition/5` is called only by the browser-suite bootstrap. `FeatureBoardLive` has one event, `create_feature`, and its cards are links; `FeatureDetailLive` handles answers, retries, cancellation, review, comments, evidence, assignment, the specification link, and the processing-boundary confirmation, then renders the sentence `Start development when you're ready.` with no control. `Readiness` is not called from the web layer at all. No LiveView creates or revises a specification.

A feature holds no text. `Feature` has `title`, `lifecycle_column`, `status`, `state_version`, and a plain `specification_id` string. Requirements live in `specification_revisions`, whose every revision carries `requirements_document`, `design_document`, and `tasks_document` and is immutable; `ProjectSpecification.current_revision_id` points at the head. `Readiness.assess/3` takes the head of `SpecificationStore.current_snapshot/2`, the project's first specification by id, and never reads `feature.specification_id`. `Readiness.guided_structure/0` already defines four parts (outcome, who it is for, rules that must hold, how you will know it works) that nothing renders.

`Readiness.assess/3` sends the feature title and the requirements document to `ReadinessGuidance.adapter/0`, which defaults to `ReadinessGuidance.Unconfigured`. No configured model adapter exists in development or production. `Suggestions.promote/4` moves a feature to `ready_for_development` only with a stored assessment that has no blockers, under the `:assign` guard. `Readiness.start_available?/4` requires an assessment current for the head revision's id and digest.

`Start.start/4` checks, in order, the `:start_run` guard (owner or participant), the boundary confirmation, readiness, a head revision, no live run, then builds an `ExecutionManifest` from `Application.get_env(:sdd_orchestrator, :delivery_execution)`, which only the browser-suite bootstrap sets, so a plain server raises on `repository_base_revision`. It resolves an AI connection through the project's `HostedLocalRepositoryBinding` and proceeds ungoverned when none applies, then commits the transition, the `AgentRun`, the first `RunAttempt`, the activity, and the `RunCommand` in one transaction. `RepositoryExecutionProfile` already holds `root`, `base_revision`, `commands`, `required_checks`, and `allowed_scope` for an approved profile, and neither `Readiness` nor `Start` reads it.

Delivery to the worker goes through the project-keyed registry: `CommandTransport.Channel.deliver/1` finds a worker that joined the project's `worker:` topic. A worker paired from the menu bar, as `specs/39-mac-scoped-worker-connection/` connects it, attaches only for its Mac and joins no project topic, so a run started for a project it was just connected to would find no worker.

The project topic authorizes from the socket, not from the join. `WorkerSocket.connect/3` reads the connect token and assigns `project_id` only for a project-scoped credential; a workspace-scoped one assigns `device_workspace_id` alone. `WorkerChannel.confirm_execution_target/2` then compares the topic against `socket.assigns.project_id`, which a Mac-scoped socket does not have, so the join raises `KeyError` and crashes the channel rather than refusing. A join param is negotiated as a protocol contract and is never read as a credential, so no exchange performed after connect can reach that check.

## Proposed Approach

Give every feature its own specification, render the four guided parts as a form, read readiness from that specification, offer the two lifecycle actions and the start action on the feature page, derive the manifest from the approved profile, and make the worker join the project's run topic once the project is bound to it.

- `Features.create/3` creates the feature and its specification in one transaction: `SpecificationStore.create/4` under the project owner's authority (the mapping `Features.available_specifications/4` already performs for a participant) with the feature's title, a requirements document holding the four guided headings with empty bodies, and design and tasks placeholders that state they belong to the coding agent, then `link_specification`. The feature's `specification_id` is set from creation; the optional link control stays for features created before this slice.
- The requirements document is Markdown with four fixed second-level headings from `Readiness.guided_structure/0`. `GuidedRequirements` parses and renders that shape; the form edits the four bodies and saves through `SpecificationStore.append_revision/5` with the expected head revision, so a concurrent edit is refused rather than overwritten. Design and tasks documents are carried forward unchanged on every revision the form makes.
- `Readiness.assess/3` reads the feature's linked specification and refuses a feature without one. It produces structural findings itself, one blocking `missing` finding per empty guided part, and merges them with the adapter's findings. `ReadinessGuidance.Unconfigured` answers a distinct `:not_configured`, which the assessment records as a flag rather than an error, so the page can say no guidance model is configured. A configured adapter that fails still answers an error, and readiness cannot be judged until it answers.
- The readiness section renders findings grouped as blockers and suggestions, with dismiss on suggestions through `Readiness.dismiss`, a `Check readiness` action, and `Make ready` through `Suggestions.promote/4` when the current verdict has no blocker. `Back to draft` uses `Features.transition/5` to `draft`. A revision newer than the verdict's renders the verdict as stale and hides `Make ready` until readiness is checked again.
- `Start.preconditions/3` answers an ordered list of items, each met or unmet with the route that resolves it: ready with a current verdict, boundary confirmed for the current disclosure digest, an approved execution profile, a project binding to a worker that is attached now, and an AI connection choice when more than one is eligible. `Start.available?/3` becomes `preconditions/3` with every item met. The start section renders the list, keeps the existing disclosure and `confirm_boundary` control, and renders `Start development` only when every item is met.
- `Start.start/4` builds the manifest from the project's approved `RepositoryExecutionProfile`, read through a new `RepositoryAssessments.approved_profile/2`: `repository_base_revision` from `base_revision`, `required_checks` from `required_checks`, and three new typed `ExecutionManifest` fields, `repository_root`, `commands`, and `allowed_scope`, from the profile fields of the same name. It refuses with `:no_execution_profile` when none is approved. The worker binding check is a precondition, so a run is never started for a project whose worker is not attached now.
- `Start.execution_config/0` and the `:delivery_execution` application key are removed only after the four other manifest builders that read them, in `Answers`, `Retry`, `Reconciliation`, and `ReviewContinuation`, take the same profile source. Those four hold an authority and no actor, so they derive the profile viewer from the authority. The browser-suite bootstrap and the delivery test fixtures seed an approved profile instead of setting the key.
- When a hosted project becomes bound to a worker, and again whenever that worker attaches for its Mac while bindings exist, the control plane pushes `project_bound` with the project id over the Mac-scoped attachment. The worker starts a second `Worker.GatewayConnection` for that project, under a `DynamicSupervisor`, with a configuration whose `project_id` is set. That connection exchanges the worker credential for a project-scoped gateway credential through the existing exchange `specs/33-local-worker-run-execution/` defines, dials the gateway with it, and joins the project's `worker:` topic exactly as a configured project worker already does, so that project's run commands arrive through the unchanged `deliver/1`. Disconnecting the project pushes `project_unbound` and the worker stops that connection.
- `WorkerChannel.confirm_execution_target/2` reads the socket's project with `Map.get`, so a Mac-scoped socket aimed at a project topic is refused instead of crashing the channel process. That is a fail-closed correction to a surface this slice depends on, not a new capability.
- Pressing `Start development` calls `Start.start/4` with the feature's expected state version. On success the page re-reads the feature and subscribes to its activity, so the worker's acknowledgement and first progress event appear through the runtime projection and activity sections that already exist. Every refusal reason maps to one sentence in the start section and changes nothing.

## Components Affected

- `Delivery.Features` (`create/3`) and `Delivery.Feature`: specification creation with the feature, linked from creation.
- `Delivery.GuidedRequirements` (new): the four-part document shape, parse and render.
- `Delivery.Readiness`, `ReadinessAssessment`, `ReadinessGuidance`, and `ReadinessGuidance.Unconfigured`: feature-linked revision, structural findings, the not-configured flag.
- `Delivery.Suggestions.promote/4`: unchanged contract, first product caller.
- `Delivery.Start` (`preconditions/3`, `available?/3`, `start/4`) and `ExecutionManifest`: profile-derived manifest, the new `repository_root`, `commands`, and `allowed_scope` fields, `:no_execution_profile`, worker-attached precondition.
- `Delivery.Answers`, `Delivery.Retry`, `Delivery.Reconciliation`, and `Delivery.ReviewContinuation`: the four other manifest builders, moved off `:delivery_execution` onto the same profile source.
- `RepositoryAssessments.approved_profile/2`: the approved-profile lookup for a project.
- Mac-scoped attachment channel from `specs/39` and `specs/40`: `project_bound` and `project_unbound` messages; `Worker.Supervisor` and `Worker.GatewayConnection`: a project-scoped connection started and stopped on demand.
- `SddOrchestratorWeb.WorkerChannel`: a cross-scope join refused rather than crashed, and a worker's event persisted through `EventIngestion.ingest/3` before it is published.
- `test/support` delivery fixtures: a connected repository and an approved profile, so a delivery test project can hold one.
- `Portability.HostedLocalRepositoryConnection` connect and disconnect: emit the bound and unbound notifications.
- `FeatureBoardLive`: unchanged apart from creation now producing a specification.
- `FeatureDetailLive`: requirements form, readiness section, `Make ready`, `Back to draft`, start preconditions, `Start development`, and the run-begun state.
- `SddOrchestratorWeb.E2EBootstrapController`: seeds an approved profile and a feature-owned specification instead of `:delivery_execution`.

## Data and Access Boundaries

- `GuidedRequirementsDocument`: the requirements document of a feature's specification, held as one immutable revision per save, with four fixed sections. Owned by the project under the owner's authority, readable and revisable by owner and participants through `Features`, and following the project specification lifecycle `specs/09-project-specification-storage/` defines. Its content is the person's own words about the feature and is sent to a guidance model only when one is configured, which the start section discloses.
- `StartReadout`: the in-memory list of start preconditions with met or unmet state and a resolving route, computed on each render and never stored.

Required boundaries:

- Creating, revising, and reading a feature's specification requires membership in the project; the feature's creation and revisions run under the project owner's authority even when a participant acts, and the acting person is recorded as the revision's actor. A non-member reaches none of it.
- Readiness and start read only the feature's linked specification. No other project specification is consulted or disclosed.
- The manifest carries only what the approved profile already holds and the identifiers the run needs. No path, credential, or source enters it.
- `project_bound` carries the project id only. The project-scoped credential exchange and topic authorization stay exactly as `specs/33` and `specs/37` verified them.
- Nothing this slice adds is logged with document content, and no analytics event names a feature, specification, or person.

## Interfaces

- `Features.create/3` now answers a feature whose `specification_id` is set.
- `GuidedRequirements.parse/1` and `render/1` between the four-part form and the Markdown document.
- `Readiness.assess/3` and `ReadinessAssessment` gain structural findings and a `guidance` flag with values `configured` or `not_configured`; `ReadinessGuidance` adapters may answer `{:error, :not_configured}`.
- `Start.preconditions/3` answering the ordered item list; `Start.start/4` adding `:no_execution_profile` to its error type and dropping `:delivery_execution`. The worker check stays in `preconditions/3`, which the page re-asks before every press, so `start/4` gains no `:worker_unavailable`.
- `RepositoryAssessments.approved_profile/2` answering the project's highest approved `RepositoryExecutionProfile`, or nothing.
- `ExecutionManifest` gaining `repository_root`, `commands`, and `allowed_scope`, validated as the profile already validates them, at `manifest_version` 2.
- Mac-scoped attachment messages `project_bound` and `project_unbound` with `project_id`.
- Compatibility that must hold: `Feature` transitions and `state_version` locking, the `:start_run` and `:assign` guards, `Suggestions.promote/4`, `RunTransitions`, `DeliveryStore.commit`, the `RunCommand` outbox and `deliver/1`, the project-scoped `worker:` topic and its credential exchange, the review, evidence, comment, and assignment behavior of the feature page, and every browser-suite scenario that seeds features and runs.

## Decisions and Tradeoffs

### A feature owns its specification from creation

- Choice: Create the specification with the feature and set the link at creation.
- Reason: The README's loop starts with writing what a feature should do. A feature with no text and a readiness that judges the project's first specification cannot carry that.
- Consequence: `specs/35`'s optional link becomes the normal state. Features created before this slice keep the link control to adopt a specification, and readiness refuses a feature that has none instead of guessing.

### Structural readiness gates, guidance adds

- Choice: An empty guided part is a blocking finding produced without a model. A configured model's findings apply on top. An unconfigured adapter is a recorded fact, not an error.
- Reason: No guidance model works today, and `specs/07` would otherwise leave every feature stuck in draft. The person still cannot start with an empty requirement.
- Consequence: Readiness is weaker than `specs/07` intended until a model adapter ships. The page says so instead of pretending a model judged the feature.

### The manifest comes from the approved profile

- Choice: `Start` reads `RepositoryExecutionProfile` and refuses without one; `:delivery_execution` is removed.
- Reason: The profile is where the repository's real commands and checks already live, approved by the owner. A manifest from configuration would run generic checks against a real repository.
- Consequence: The first path to a run includes the assessment and profile approval. The browser suite must seed a profile, and the `:delivery_execution` key disappears from the bootstrap.

### The manifest carries the profile's values in fields of its own

- Choice: `ExecutionManifest` gains typed `repository_root`, `commands`, and `allowed_scope` fields, and `manifest_version` moves to 2. `agent_ref` and `worker_ref` stay the small identity maps they are.
- Reason: Those two references are flat string maps capped at 512 bytes per value, and a profile holds up to 64 commands and scope entries of up to 1024 bytes each. Joining the lists into a reference value would let a legitimate profile produce a manifest the manifest's own validation refuses.
- Reason for the version: `ExecutionManifest` refuses a field it does not know, so a worker installed before this change would refuse the new manifest either way. At version 2 it refuses with `unsupported_manifest_version`, which is what the version field is for, instead of a field error that reads like a bug. Every manifest decode is a worker reading an in-flight command; nothing decodes a stored manifest, so no run history depends on version 1.
- Consequence: `ExecutionManifest`, its canonical form, and its digest change, and the worker reads three named fields instead of parsing a reference string. A worker older than this change refuses every run command until it is updated. The three fields take empty defaults when absent, so the four continuation builders keep producing valid manifests until `Task 10` moves them onto the profile.

### The manifest and the profile agree on how many checks are allowed

- Choice: `ProtocolLimits.max_required_checks` moves from 50 to 64, matching the profile proposal's own limit.
- Reason: An owner can approve a profile holding up to 64 required checks, and the manifest would then refuse to carry it. A profile the owner approved must be startable, and 64 command strings sit far inside the manifest's 64KB payload cap.
- Consequence: One bound instead of two. A profile that is too large to run is refused at approval, where the person can act on it, rather than at start.

### The worker opens a project-scoped connection when told

- Choice: The control plane pushes `project_bound` over the Mac-scoped attachment, and the worker starts a second `GatewayConnection` for that project, with the project-scoped credential in its connect URI, exactly as a configured project worker connects today.
- Reason: `deliver/1` and the project-keyed registry are verified and untouched by `specs/39` and `specs/40`. Rerouting run delivery over the Mac attachment would reopen that contract; telling the worker which projects it serves does not.
- Reason the earlier shape was replaced: this slice first decided the worker would join the project topic on its existing Mac socket. Implementation found that impossible. The project topic authorizes from the socket's connect token, and a Mac-scoped socket carries no project, so the join crashes rather than joins, and no credential exchanged after connect can reach the check. The only same-socket alternative was to accept a credential as a join param, which widens the topic authorization `specs/33` and `specs/37` verified.
- Consequence: A worker serving several projects holds one connection per project instead of several topic joins on one socket, so `Worker.Supervisor` gains a `DynamicSupervisor`. `WorkerChannel`, `deliver/1`, the registry, and the project topic's authorization stay exactly as they were. The Mac attachment remains the only place the worker learns about bindings.

### Preconditions are a readout, not a hidden gate

- Choice: The page renders every start precondition with its state and a resolving link, and offers the button only when all are met; `Start.start/4` re-checks all of them.
- Reason: A person who cannot start must see why and where to go. The button is the last step, not the only feedback.
- Consequence: The readout and the start check share one function so they cannot disagree.

### A worker's event is stored before anyone is told about it

- Choice: `WorkerChannel` calls `EventIngestion.ingest/3` in its `event` intake, before it publishes and before it answers the worker, exactly as it already treats an acknowledgement through `CommandOutbox.acknowledge/2`. Only the event types `EventIngestion.handled_event_types/0` names go through it; `evidence`, `blocked`, `failed`, `canceled`, and `verification_completed` belong to other modules and publish unchanged.
- Reason: The channel validated the event and broadcast it, and nothing stored it. `EventIngestion.ingest/3` had no caller under `lib/` at all, so a real worker's progress was announced and dropped, and the page had nothing to re-read.
- Consequence: The worker is told `accepted` only for an event that was actually stored, and a refusal reaches the worker instead of silence. A consumer subscribing to the topic instead would leave a gap where an event is announced, the consumer restarts, and the worker has been told a stored event exists when it does not.

## Risks

- `Task 6` and `Task 7` depend on `specs/40`'s capability, which depends on `specs/39`. The requirements form, readiness, and the lifecycle actions are independent and proceed first.
- A revision appended by the form races with an answer write-back from `Delivery.Answers`. The form sends the expected head revision and shows a refusal with a reload rather than overwriting.
- The browser-suite bootstrap sets `:delivery_execution` for its delivery scenarios. Removing it without seeding a profile breaks those scenarios; `Task 5` changes both together.
- A worker that serves a project it was bound to before this slice, through a restore, already holds a project connection from its configuration. `project_bound` for such a project must be idempotent and must not open a second connection.
- `WorkerSocket.id/1` puts the two scopes in disjoint spaces, so a project connection does not evict the Mac one. A change to that identity would break the pair.

## Open Questions

- None.
