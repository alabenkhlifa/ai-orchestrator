# Feature Delivery From The Product UI Tasks

## Status

Verified

## Active Slice

Let a person take a feature of a hosted project from creation to a started run by clicking in the product: create the feature with its own specification, write its four guided requirement parts, see and clear readiness findings, make it ready, see every start precondition with a way to resolve it, press `Start development`, and watch the worker on this Mac acknowledge the run.

## Cross-Specification Dependencies

Requires:

- `capability:guided-delivery-feature-specification-link` — provider `specs/35-guided-delivery-feature-specification-link#Task 1` — required before `Task 1`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 1`.
- `capability:repository-execution-profile` — provider `specs/30-repository-execution-profile-completion#Task 2` — required before `Task 5`.
- `capability:hosted-local-repository-connection` — provider `specs/37-hosted-local-repository-connection#Task 6` — required before `Task 6`.
- `capability:worker-repository-selection` — provider `specs/40-worker-repository-selection#Task 9` — required before `Task 6`.
- `capability:mac-scoped-worker-connection` — provider `specs/39-mac-scoped-worker-connection#Task 8` — required before `Task 7`.
- `capability:local-worker-run-execution` — provider `specs/33-local-worker-run-execution#Task 12` — required before `Task 8`.

Provides:

- `capability:feature-delivery-from-the-ui` — ready after `Task 12`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Creating a feature's own specification with the feature and linking it from creation.
- The four-part guided requirements document, its form on the feature page, and revision saves with the expected head.
- Readiness read from the feature's linked specification, structural findings, the not-configured guidance flag, and the readiness section with check, dismiss, `Make ready`, and `Back to draft`.
- The start preconditions readout, the profile-derived manifest with its three new `ExecutionManifest` fields, the move of the four other manifest builders onto the profile, removal of `:delivery_execution`, the `Start development` action, and the run-begun state on the page.
- `project_bound` and `project_unbound` over the Mac-scoped attachment, the worker's on-demand project-scoped connection, and the cross-scope join refused rather than crashed.
- Browser-suite bootstrap changes that seed an approved profile and a feature-owned specification.

Excluded:

- A feature board for accountless device projects.
- A specifications page or hand-editing of design and tasks documents.
- Any model adapter for readiness guidance; the adapter contract is consumed, not delivered.
- Run behavior after the first progress event, owned by `specs/07-guided-specification-delivery/` and `specs/33-local-worker-run-execution/`.
- Pilot selection and the assessment and profile approval flows, owned by `specs/14-repository-execution-profile/` and `specs/30-repository-execution-profile-completion/`.
- The Mac-scoped attachment's topic, registry, and authorization, and the selection messages, owned by `specs/39-mac-scoped-worker-connection/` and `specs/40-worker-repository-selection/`.

Deferred after this slice:

- The accountless device-project feature board and its start path through the device delivery store.
- A working readiness guidance model adapter, after which the not-configured statement disappears on its own.
- Adopting a specification for a feature created before this slice through the existing link control, which stays available but is not part of the proof.

Release gates:

- None.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Create a feature with its own linked specification.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Give every feature somewhere to hold what it should do, from the moment it exists.
  - Owned surfaces: `Features.create/3` creating the specification under the owner's authority in the same transaction as the feature, the empty four-heading requirements document and the agent-owned design and tasks placeholders, the link set at creation, and the participant path resolving the owner's authority.
  - Owns: AC-01
  - Proof: Focused tests cover a created feature answering a linked specification with the four empty headings, a participant creating one under the owner's authority with the participant recorded as actor, a failed specification creation leaving no feature, and the board still listing the feature as before.
  - Delivered: `Features.create/3` now creates the feature and its own specification in one transaction under the owner's authority, with the acting person recorded as the revision's actor. A refused specification leaves no feature.

- [x] Task 2 — Edit the four guided parts and save a revision.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Let a person write what the feature should do in the product.
  - Owned surfaces: `Delivery.GuidedRequirements` parse and render, the requirements form on `FeatureDetailLive` with its four parts, the save through `SpecificationStore.append_revision/5` with the expected head, the refusal on a concurrent revision, and the design and tasks documents carried forward unchanged.
  - Owns: AC-02, entity:GuidedRequirementsDocument
  - Proof: Focused LiveView tests cover a save producing one new revision holding the four parts, the form showing them back after reload, a concurrent revision being refused with a reload notice, and the design and tasks documents unchanged across saves.
  - Delivered: `Delivery.GuidedRequirements` owns the four-part document shape, derived from `Readiness.guided_structure/0` so the headings cannot drift. The feature page's form saves one revision against the head it loaded and carries the design and tasks documents forward.

- [x] Task 3 — Judge readiness from the feature's specification with structural findings.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Make readiness answer for this feature, and answer at all when no model is configured.
  - Owned surfaces: `Readiness.assess/3` and `start_available?/4` reading the linked specification, the structural `missing` finding per empty part, the merge with adapter findings, the `guidance` flag and `ReadinessGuidance.Unconfigured` answering `:not_configured`, and the readiness section with `Check readiness`, blockers, suggestions, dismiss, and the not-configured statement.
  - Owns: AC-03
  - Proof: Focused tests cover an empty part producing one blocking finding, a full document producing none, a fake configured adapter's blocking and suggestion findings merged and the suggestion dismissible, the unconfigured adapter recorded as not configured and shown as such, and a feature without a linked specification refused.
  - Delivered: `Readiness` reads the feature's own linked specification, adds one blocking `missing` finding per empty guided part, and records a `guidance` flag so the page can say no model is configured. `DeliveryFixtures.feature_fixture/3` now creates features through `Features.create/3`, so a test feature holds the specification production gives it.

- [x] Task 4 — Make a feature ready or return it to draft from its page.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Give the person the two lifecycle moves the board deliberately withholds.
  - Owned surfaces: `Make ready` through `Suggestions.promote/4`, `Back to draft` through `Features.transition/5`, the stale-verdict rendering when a newer revision exists, and hiding `Make ready` until readiness is checked again.
  - Owns: AC-04, AC-05
  - Proof: Focused LiveView tests cover `Make ready` moving a blocker-free feature to `Ready for development`, a blocker refusing it with the blocker named, a save after ready rendering the verdict stale and hiding both `Make ready` and the start action, and `Back to draft` returning the column.
  - Delivered: `Make ready` and `Back to draft` are on the feature page, and a save after ready renders the verdict stale and withholds `Make ready` until readiness is checked again. One function answers both the control and the event, so a press from a stale page is refused rather than only hidden.

- [x] Task 5 — Build the started run's manifest from the approved execution profile.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Run the repository's real checks and commands instead of values only a test ever set.
  - Owned surfaces: `RepositoryAssessments.approved_profile/2`, the `ExecutionManifest` fields `repository_root`, `commands`, and `allowed_scope` with their validation, the move to `manifest_version` 2 with its golden fixtures, `ProtocolLimits.max_required_checks` raised to the profile's own 64, and `Start.start/4` building the manifest from the approved profile with the `:no_execution_profile` refusal. `Start.execution_config/0` stays until `Task 10`.
  - Owns: AC-09
  - Proof: Focused tests cover a started run's manifest carrying the profile's base revision, required checks, root, commands, and allowed scope, a project without an approved profile refused with `:no_execution_profile` and creating nothing, a profile whose commands and scope exceed a reference value's byte cap still producing a valid manifest, a version 1 map refused as an unsupported version, and a profile holding 64 required checks starting.
  - Delivered: `Start` builds the manifest from `RepositoryAssessments.approved_profile/2` and refuses `:no_execution_profile` without one. `ExecutionManifest` carries the profile's root, commands, and allowed scope in fields of its own at version 2, and the required-check cap now matches the profile's 64.

- [x] Task 6 — Show every start precondition with a way to resolve it.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4, Task 5
  - Purpose: Tell the person why they cannot start yet, and where to go.
  - Owned surfaces: `Start.preconditions/3` with ready, boundary, approved profile, attached bound worker, and AI connection choice, `Start.available?/3` derived from it, `Start.current_revision/2` reading the feature's own linked specification rather than the project's first, and the start section rendering each item with its resolving route while keeping the existing disclosure and `confirm_boundary` control.
  - Owns: AC-06, entity:StartReadout
  - Proof: Focused tests cover each unmet item rendered with its route and the button absent, all items met rendering the button, the worker item unmet for a bound worker that is not attached now, the readout and `available?/3` agreeing on every combination tested, and a project holding two specifications starting against the feature's own.
  - Delivered: `Start.preconditions/3` answers the five ordered items and `available?/3` is that list fully met, so the readout and the check cannot disagree. `current_revision` now reads the feature's own linked specification. An item whose resolving page needs the owner's account session renders who resolves it instead of a link a participant cannot follow.

- [x] Task 7 — Join a bound project's run topic when the control plane says so.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let a run reach a worker that was paired for its Mac and only later connected to the project.
  - Owned surfaces: `project_bound` and `project_unbound` pushes over the Mac-scoped attachment on connect, disconnect, and attach with existing bindings, the `DynamicSupervisor` under `Worker.Supervisor` starting and stopping one project-scoped `Worker.GatewayConnection` per bound project, idempotent handling for a project already connected from configuration, and `WorkerChannel.confirm_execution_target/2` refusing a cross-scope join instead of crashing.
  - Owns: none
  - Proof: Focused tests cover a bound project pushed on attach and on connect, the worker's project connection joining the topic and appearing in the project-keyed registry, `deliver/1` reaching it, an unbind stopping the connection, a duplicate `project_bound` opening no second connection, and a Mac-scoped socket refused on a project topic with the channel still alive.
  - Delivered: `BoundProjectNotice` pushes `project_bound` and `project_unbound` over the Mac attachment, and `Worker.ProjectConnections` opens one project-scoped gateway connection per bound project. A Mac-scoped socket aimed at a project topic is now refused instead of crashing the channel.

- [x] Task 8 — Start development from the feature page and show the run begin.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 6, Task 7
  - Purpose: Close the loop the README promises.
  - Owned surfaces: The `Start development` action calling `Start.start/4` with the expected state version, one sentence per refusal reason in the start section, the page re-reading the feature and subscribing to its activity on success, and the run-begun state showing the worker's acknowledgement and first progress through the existing runtime projection and activity sections.
  - Owns: AC-07, AC-08
  - Proof: Focused LiveView tests with a test transport cover a press creating one run and moving the feature to `In development`, an acknowledgement and a progress event rendering, a refusal for a worker detached between readout and press changing nothing and naming the reason, and a second press while the run is live refused.
  - Delivered: `Start development` renders only when every precondition is met, and the press re-asks `Start.preconditions/3` before calling `Start.start/4`, so a worker that detached since the render is refused. Every refusal reason maps to one sentence, and the five precondition reasons reuse the readout's own wording.

- [x] Task 11 — Persist a worker's event so the run's progress is durable.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8
  - Purpose: Make the first progress event survive being announced, so the page has something to re-read.
  - Owned surfaces: `WorkerChannel`'s `event` intake calling `EventIngestion.ingest/3` for the event types it handles, before it publishes, the project authority resolved inside the channel, and the refusal answered to the worker when an event cannot be stored.
  - Owns: none
  - Proof: Focused tests cover a progress event from a joined worker persisted as activity and readable afterwards, the worker told accepted only when it was stored, a refused event answered as a refusal with nothing persisted, and the page re-reading it on the existing broadcast.
  - Delivered: `WorkerChannel` stores an event `EventIngestion` owns before it publishes and before it answers the worker. Event types other slices own pass through to the broadcast exactly as before.

- [x] Task 9 — Prove participant parity, fail-closed access, and the round trip.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8, Task 11
  - Purpose: Show the loop works for the people `specs/07` allows and for no one else, and establish `capability:feature-delivery-from-the-ui`.
  - Owned surfaces: The integration scenario from feature creation through requirements, readiness, ready, preconditions, and start to a delivered run command for owner and participant, the non-member fail-closed check on every new event, and the log review for document content.
  - Owns: AC-10
  - Proof: An integration scenario drives the full path as owner and again as participant to a delivered `RunCommand`, a non-member is refused on every new event and page, and a log review finds no requirements text.
  - Delivered: One scenario drives creation, the four parts, readiness, ready, preconditions, and the press to a delivered `RunCommand` as owner and again as participant. All seven events this slice added refuse a non-member, and the log review is split so the framework's two debug renderings are named and every other entry is refuted.

- [x] Task 10 — Move the four continuation manifests onto the profile and delete the configuration key.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Leave one source for every manifest, so no run path can still take its checks from configuration.
  - Owned surfaces: The manifest builders in `Delivery.Answers`, `Delivery.Retry`, `Delivery.Reconciliation`, and `Delivery.ReviewContinuation` reading the approved profile through the authority they already hold, removal of `Start.execution_config/0` and the `:delivery_execution` application key, the delivery test fixtures seeding a connected repository and an approved profile, and the browser-suite bootstrap seeding an approved profile for its delivery scenarios instead of setting the key.
  - Owns: none
  - Proof: Focused tests cover a continuation manifest from each of the four paths carrying the profile's values, a repository-wide search finding no `:delivery_execution` and no `execution_config`, and the bootstrap's delivery scenarios still seeding a startable feature.
  - Delivered: `Delivery.ExecutionProfile` maps an authority to the profile viewer and answers the five manifest values, and the four continuation builders read it. `Start.execution_config/0` and the `:delivery_execution` key are gone.

- [x] Task 12 — Carry a started run's command to the worker in the real product.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8
  - Purpose: Close the last hop, so a press reaches the worker outside a test.
  - Owned surfaces: A production `CommandTransport.Channel` envelope source building one `start` envelope from a stored `RunCommand`, the `:command_envelope_source` and `:command_transport` configuration for development and production, and the refusal when a command cannot be turned into an envelope, which together establish `capability:feature-delivery-from-the-ui`.
  - Owns: none
  - Proof: Focused tests cover a stored start command becoming a valid protocol envelope, the configured transport delivering it to a worker joined on the project topic, a command that cannot build an envelope staying queued rather than lost, and no test-only module supplying either configuration key.
  - Delivered: `CommandTransport.StartEnvelopeSource` rebuilds a start envelope from the durable command, its run, and the approved profile, and accepts it only when the manifest digest matches the stored row. Development and production now use the real channel transport. `capability:feature-delivery-from-the-ui` is established.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Feature lifecycle, review, evidence, comment, and assignment tests pass unchanged.
- [x] Run transitions, outbox, delivery, and run-execution tests pass unchanged.
- [x] Readiness, promotion, precondition, and start-refusal transitions pass.
- [x] The log, diagnostic, and no-analytics review finds no requirements text, feature, or person.
- [x] Build, formatting, lint, static checks, and logs review pass.
- [x] Required browser scenarios pass, with the bootstrap seeding an approved profile.
- [x] Product proof, AC-01 through AC-06: one click path from `/` in a real browser, worker stand-in off, no `/_e2e` seeding: sign in, create a hosted project, create a feature, write its four parts, check readiness, make it ready, confirm the boundary, and see every unmet start precondition named with its resolving route and no start control offered. Recorded in `progress.md`.

## Blocked Decisions

- None.

## Release Gate

- Product proof for AC-07 and AC-08: the click path continued to a press of `Start development` and the worker's acknowledgement, against the paired worker app. Both criteria pass their domain and integration proofs; only the real-worker click path is blocked, by the gap below.
- That blocker is closed as of 2026-09-03. `specs/44-hosted-local-repository-projects/` delivers creating a hosted local-repository project from the storage step, and `specs/45-hosted-session-project-access/` lets the person who signs in through the email link reach it. Both are `Verified` by one click path from `/` in a real browser against the paired worker app, and that project's feature board was confirmed reachable on the same session. That click path was then driven as far as it goes on 2026-09-03. Four of the five start preconditions are met by clicking, and the fifth cannot be: an approved execution profile needs a completed assessment, and `RepositoryAssessmentLive`'s `active_hosted_project?/1` requires a connected `repository_connection`, which a repository on a Mac never has. That screen belongs to `specs/14-repository-execution-profile/` and refuses a GitHub owner of such a project too. Until it accepts a repository that lives on a Mac, AC-07 and AC-08 stay proven only by their domain and integration tests and this slice is not releasable.

## Progress Log

See [progress.md](progress.md).
