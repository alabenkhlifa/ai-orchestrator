# Feature Delivery From The Product UI Progress Log

### 2026-09-01 - Task 12 complete: a press now reaches a real worker

- `CommandTransport.StartEnvelopeSource` rebuilds the start envelope from the durable `RunCommand`, its run, its current attempt, and `ExecutionProfile.manifest_fields/2`, the same reader the continuation builders use. It accepts the result only when `ExecutionManifest.digest/1` equals the digest stored on the row, so a command can never be delivered against a manifest that is not the one it was created with.
- `config/dev.exs` and `config/prod.exs` now set `:command_transport` to `CommandTransport.Channel` and `:command_envelope_source` to the new module. `config/config.exs` and `config/test.exs` are untouched, so every existing double still overrides cleanly.
- Only `start` is built. `resume`, `retry`, and `cancel` need a prior attempt number or a reason that no record holds, so they answer `:unsupported_operation` and stay queued exactly as they do today. That is the same shape as the envelope failure below, not a new behavior.
- A command whose envelope cannot be built stays `claimed` with `delivery_count` 0 and no failure code, and is claimable again once the lease expires. It is neither lost nor failed, which is the outbox contract.
- The proof drives one genuine `Start.start/4`, validates the envelope through `ProtocolCodec` rather than asserting on a hand-built map, delivers it to a worker joined on the project topic through `Dispatcher.dispatch_now/1`, and asserts both configuration keys resolve to modules compiled from `lib/` rather than `test/`.
- Under `E2E_MODE` the browser suite now also configures the real transport. No worker registers on a project topic there, so delivery still answers `:no_worker` and seeded commands stay queued, exactly as before.
- Found and left for a separate look: `DeliveryFixtures.approve_profile!/3` does not append a second version when called again with a different `commit:`, so it does not do what its own documentation says. The envelope-failure case was proved with a superseded attempt instead.
- Proof receipt: `Task 12` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/start_envelope_source_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 7 tests passed. `capability:feature-delivery-from-the-ui` is established.

### 2026-09-01 - Task 9 complete, and the hop that never reached a worker

- One scenario drives creation, the four guided parts, the readiness check, `Make ready`, the preconditions, and the press through the LiveView to a delivered `RunCommand`, first as the owner and again as an invited participant. Every action succeeds for the participant exactly as for the owner, which is AC-10's whole claim.
- The slice added seven events and no route: `validate_requirements`, `save_requirements`, `check_readiness`, `dismiss_suggestion`, `make_ready`, `back_to_draft`, and `start_development`. All seven refuse a non-member, along with the feature page, the board, and `create_feature`. Because a non-member cannot mount the page at all, the event half is driven on a page opened while the person was still a participant and then revoked. Making the revoke a no-op fails 8 of 12 tests, so the refusal is what they hold.
- `validate_requirements` has no authorization check. It is a pure assign that stores nothing, and the test asserts the stored revisions are unchanged rather than pretending a guard exists.
- The log review is split rather than blanket. LiveView renders `save_requirements` parameters and `create_feature`'s title at `:debug`, and Ecto logs the same values as query parameters. Production runs at `:info` and emits neither, which the review asserts. Development sets no level and prints them on the developer's own machine. Decided with the user: recorded as known and reviewed, not silenced, since raising the dev level would hide every other debug line to close a gap only reachable on the developer's own machine.
- Proof receipt: `Task 9` — scope `Focused` — command `mix test test/sdd_orchestrator/feature_delivery_end_to_end_test.exs test/sdd_orchestrator_web/live/feature_delivery_access_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 15 tests passed.

The last hop, found by this task and verified on the main thread.

- `CommandTransport.transport/0` defaults to `CommandTransport.Unavailable`, and `:command_transport` is set only by a test double. `:command_envelope_source` has no producer under `lib/` or `config/` at all; every implementation in the repo is a test module. So a press in the real product enqueues a durable `RunCommand` whose delivery answers `{:error, :no_worker}` forever, and the slice's own product proof cannot pass.
- `specs/33` did not defer this. It was Verified on domain proofs that install the double, the same pattern this slice was written to break.
- Decision: `Task 12` closes it. The slice's outcome is watching a run begin on this Mac's worker, so a loop that stops one hop short does not deliver it. Twelve tasks, at the slice gate limit, with a longest dependency path of 8.
- `Task 9` keeps proving the domain round trip through the transport double. The real path is what the Verification Gate's product proof covers.

### 2026-09-01 - Task 11 complete: the first progress event is now durable

- `WorkerChannel.handle_in("event", ...)` stores the event before it publishes and before it answers the worker, so `accepted` now means stored. `reconcile` still goes through the untouched shared intake.
- The authority is resolved inside the channel from the project id alone: a hosted project answers its owner's `PersonalWorkspace`, and anything else answers nil, which fails closed in `DeliveryStore`'s dispatch. The worker's credential is never used as an authority, because it names an execution target rather than a person.
- Corrected against the brief, and the correction was right: `EventIngestion` handles only `progress` and `workspace_ready`. The other five protocol event types belong to `EvidenceIngestion`, `Blocking`, `Retry`, and `VerificationCompletion`. Sending them through ingestion would have refused them to the worker as `:unsupported_event` and stopped publishing them, breaking four worker suites and reaching into behavior this slice's boundary excludes. The intake gates on `EventIngestion.handled_event_types/0`, and a test pins the pass-through so it cannot be lost later.
- Storing events made attempt `state_version` genuinely move, which broke three call sites that hardcoded `RunAttempt.transition_changeset(attempt, "superseded", 1)`. Each now reads the version the row actually holds. The supersession still has to be a legal transition; nothing was weakened.
- Mutation check: replacing the store with a bare `:ok` fails 5 of the 6 new tests, so the persistence is what they hold.
- Proof receipt: `Task 11` — scope `Focused` — command `mix test test/sdd_orchestrator_web/channels/worker_event_persistence_test.exs test/sdd_orchestrator_web/channels/worker_channel_test.exs test/sdd_orchestrator/privacy/delivery_routing_boundary_test.exs test/sdd_orchestrator_web/live/feature_start_development_test.exs test/sdd_orchestrator/worker/command_lifecycle_test.exs test/sdd_orchestrator/worker/agent_event_delivery_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 74 tests passed, and only `worker_channel.ex` changed under `lib/`.

### 2026-09-01 - Task 8 complete, and the event nobody stored

- `Start development` renders only when `Start.preconditions/3` reports every item met, and carries `data-start-development`, the attribute `Task 4`'s stale-verdict test already asserts is absent.
- The press re-asks `Start.preconditions/3` before calling `Start.start/4`. That is what makes AC-08's detached-worker case real: `start/4` has no worker check, so calling it alone would start a run for a worker that had gone. The page uses `Task 4`'s pattern, where one function answers both the control and the event, so a hidden button and a guarded action stay the same answer.
- `design.md`'s Interfaces line claimed `start/4` would gain `:worker_unavailable`. It did not, and the worker check lives in `preconditions/3` instead. The line is corrected rather than left to mislead.
- Nine refusal reasons map to sentences. The five precondition reasons reuse the readout's own wording, so the list above the button and the answer below it cannot drift; only three sentences are new.
- Both new mechanisms were mutation-checked: removing the subscription fails the progress test, and removing the press-time re-check lets a detached worker start a run.
- Proof receipt: `Task 8` — scope `Focused` — command `mix test test/sdd_orchestrator_web/live/feature_start_development_test.exs test/sdd_orchestrator_web/live/feature_start_preconditions_test.exs test/sdd_orchestrator_web/live/feature_lifecycle_actions_test.exs test/sdd_orchestrator_web/live/feature_detail_live_test.exs test/sdd_orchestrator_web/live/feature_readiness_section_test.exs test/sdd_orchestrator_web/live/feature_requirements_form_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 124 tests passed.

A gap this task exposed, and the decisions taken with the user.

- `WorkerChannel` validates a worker's event, publishes `{:worker_event, envelope}`, and stores nothing. `EventIngestion.ingest/3` had no caller under `lib/` at all; the only one was the browser-suite seed. So on a real Mac the acknowledgement persists through `CommandOutbox.acknowledge/2`, but the first progress event is announced and dropped, and AC-07 cannot hold. Verified on the main thread: the only production subscriber to the worker topic is the page this task just added.
- This is inside the slice. The Implementation Boundary defers run behavior only after the first progress event, and AC-07 names that event.
- Decision: the channel ingests before it publishes, so the worker is told `accepted` only for an event that was stored. A consumer subscribing to the topic would leave a window where an event is announced, the consumer restarts, and the worker has been told a stored event exists when it does not.
- Decision: this becomes `Task 11`, owned and proved on its own, rather than folded into `Task 9`. `Task 9` verifies surfaces owned elsewhere; making it own production code is the implicit-owner shape the coverage gate warns against. The slice is now 11 tasks with a longest path of 8, both inside their gates.

### 2026-09-01 - Task 6 complete: the readout, and the specification the run actually uses

- `Start.preconditions/3` answers five ordered items, each `%{key:, met?:, route:}`, keyed `:ready, :boundary, :execution_profile, :worker, :ai_connection`. `available?/3` is that list fully met. One function answers both the screen and the check, which is the point: they cannot drift apart. `start/4` still revalidates everything, because the answer can change between render and press.
- Every item reuses what `start/4` already calls. The worker item is the only new check, and it uses `Devices.worker_available?/1`, the single existing definition of attached now, which also honours the stand-in the browser suite depends on.
- Fixed the defect recorded in the previous entry. `current_revision` read the project's first specification while readiness read the feature's own, so a project with two specifications could judge one document and run against another. It now reads `feature.specification_id` through `SpecificationStore.get_current/3`. The new test was confirmed to fail against the old behavior before the fix was restored.
- The same first-specification assumption was making an existing `start_test` case flaky by UUID ordering. It now reads the feature's own specification and is deterministic.
- Adding the worker item to `available?/3` correctly broke two existing assertions that expected a start to be available on a project with no worker binding at all. Both now bind a worker, which is what the design requires.
- A participant question the readout exposed, decided with the user: `/projects/:id/overview` and `/ai-connections` are in the `:authenticated` live session, so a participant clicking either lands on the sign-in gate. AC-06 promises a way to resolve each unmet item, so a link that bounces is exactly the dead end it exists to prevent. Those two items now render `The project owner resolves this one.` for a participant and keep the link for the owner. No route moved and the router is unchanged. `/projects/:id/profile` is already in `:participation`, so its link stays for everyone.
- The worker copy states only what the control plane can see, that no worker is connected right now, and offers two branches rather than claiming the app is missing from a Mac it cannot inspect. A test asserts the readout never says not installed and carries no em dash.
- Proof receipt: `Task 6` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/start_preconditions_test.exs test/sdd_orchestrator/delivery/start_test.exs test/sdd_orchestrator/delivery/cancellation_test.exs test/sdd_orchestrator_web/live/feature_start_preconditions_test.exs test/sdd_orchestrator_web/live/feature_lifecycle_actions_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 75 tests passed.

### 2026-08-31 - Task 4 complete: the two lifecycle moves the board withholds

- `Make ready` calls `Suggestions.promote/4` with the operation key `ready:` plus the feature id and its state version. The state version belongs in the key: a bare feature-id key would absorb a second press, but it would also silently replay the first press's result for a feature that had since gone back to draft.
- `Back to draft` calls `Features.transition/5` with the feature's expected state version, and renders only from `ready_for_development`.
- The page now holds the head revision's digest beside its id, so `ReadinessAssessment.current_for?/3` can answer whether the verdict still judges the document in front of the person. A stale verdict renders a notice and withholds `Make ready`.
- `make_ready_state/4` is the single answer both the control and the event read, so a press from a page left open is refused rather than merely hidden. That is the difference between a hidden button and a guarded action.
- The copy is single-sourced in module attributes, and the existing `Check readiness first.` literal now references the attribute rather than holding a second copy that could drift.
- No domain module changed. This task is the first product caller of `Suggestions.promote/4`, which had none under `lib/`.
- The stale test asserts `[data-start-development]` is absent as a forward guard, since `Task 8` has not built that control yet. `Task 8` must use that attribute for the guard to keep meaning anything.
- Proof receipt: `Task 4` — scope `Focused` — command `mix test test/sdd_orchestrator_web/live/feature_lifecycle_actions_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 5 tests passed, and 131 neighbouring page tests pass unchanged.

### 2026-08-31 - Tasks 3 and 10 complete, and a fixture that lied about production

`Task 3`, readiness from the feature's own specification.

- `assess/3` and `start_available?/4` read `SpecificationStore.get_current/3` on `feature.specification_id`. A feature with no link is refused with `:no_specification` rather than falling back to the project's first specification.
- One blocking `missing` finding per empty guided part, id `structural-` plus the part key, merged with the adapter's findings; a structural finding wins an id collision and is never dismissible.
- `ReadinessGuidance.Unconfigured` now answers `{:error, :not_configured}`, which `assess/3` records as a `guidance` flag rather than an error. A configured adapter that fails still errors, so readiness cannot be judged until it answers. Migration `20260831090000_add_guidance_flag_to_readiness_assessments` adds the nullable column; a null reads as `configured`, since no row could exist before an adapter answered.
- The page says: "No guidance model is configured here. These findings come from the guided parts alone."
- Proof receipt: `Task 3` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/feature_readiness_findings_test.exs test/sdd_orchestrator_web/live/feature_readiness_section_test.exs test/sdd_orchestrator/delivery/readiness_test.exs test/sdd_orchestrator/delivery/suggestions_test.exs test/sdd_orchestrator/delivery/readiness_guidance_test.exs test/sdd_orchestrator/delivery/feature_specification_link_test.exs test/sdd_orchestrator_web/live/feature_specification_link_live_test.exs` — exit `0`.

`Task 10`, one source for every manifest.

- `Delivery.ExecutionProfile` maps an authority to the profile viewer and answers the five manifest values, so the four continuation builders and `Start` share one mapping. `Start.execution_config/0` and the `:delivery_execution` key are gone; a repository-wide search finds neither.
- `ReviewContinuation.manifest/3` became `manifest/4` to take the authority it now needs.
- Removing the key broke 31 more tests than the 18 expected, because `review_test` and `review_continuation_test` run every behavior twice and the device half needs a device profile. `DeliveryFixtures.approve_device_profile!/3` restores the project onto the device through the portability path and walks the real approval.
- The governance end-to-end test could not keep `git rev-parse HEAD` as its required check, because the profile payload's command allowlist rejects `git`. It now approves a profile carrying `make revision` against a two-line `Makefile` in the fixture repository. Same deterministic check, now one a profile can actually hold.
- Proof receipt: `Task 10` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/answers_test.exs test/sdd_orchestrator/delivery/retry_test.exs test/sdd_orchestrator/delivery/reconciliation_test.exs test/sdd_orchestrator/delivery/review_continuation_test.exs test/sdd_orchestrator/delivery/review_test.exs test/sdd_orchestrator/delivery/run_notifications_test.exs test/sdd_orchestrator/delivery/cancellation_test.exs test/sdd_orchestrator/delivery/start_test.exs test/sdd_orchestrator/privacy/local_worker_run_governance_privacy_test.exs test/sdd_orchestrator/worker/local_worker_runtime_governance_end_to_end_test.exs test/sdd_orchestrator_web/controllers/e2e_bootstrap_controller_test.exs test/sdd_orchestrator_web/live/feature_detail_live_test.exs test/sdd_orchestrator/project_assistant/turn_orchestrator_test.exs test/sdd_orchestrator/project_assistant/project_context_store_test.exs` — exit `0`.

Two findings that outlived their tasks.

- `DeliveryFixtures.feature_fixture/3` built features production can no longer produce: `specification_id` was nil, while `Features.create/3` has linked one since `Task 1`. It now routes through `Features.create/3`, with a `requirements: :filled` option for tests that need a clean verdict. Roughly 40 call sites deliberately attribute a feature to someone the participant guard refuses, so those create under `ParticipantGuard.owner/1` and correct `creator_account_id` afterwards. This also exposed a latent flake in `start_test`: a stale-revision test edited whichever specification sorted first by id, which was a coin flip.
- The fixture's new repository connection sent `RepositorySourceAuthorization` down its GitHub branch for five `TurnOrchestratorTest` cases whose own helper claims a `test` provider. The helper now deletes the connection it is replacing, which is what naming a different provider means. One further case asserted the citation named the specification its setup created; the feature now owns one too, so it resolves the cited specification and asserts the answer names that one. No assertion was weakened.
- Still open: `Start.current_revision/2` binds a run's starting revision to the project's first specification while readiness reads the feature's own, which contradicts the business rule that both read the feature's linked specification. `Task 6` now owns that surface and proves it against a project holding two specifications.
- Both receipts were confirmed on the main thread by real exit status, after the regression fix.

### 2026-08-31 - Tasks 2, 5, and 7 complete

`Task 2`, the guided requirements form.

- `Delivery.GuidedRequirements` owns the document shape. `structure/0` and `render/1` derive the four headings from `Readiness.guided_structure/0` at runtime, so what the form writes and what readiness judges cannot drift. `parse/1` answers an empty string for an absent or empty heading and ignores sections the four do not name, so a document a run later appends to still parses.
- The form reads the head revision id and the design and tasks documents once at mount and replaces them only on a successful save, so a head that moved is always refused rather than overwritten. Saving appends through `SpecificationStore.append_revision/5` with the acting person as actor.
- The save reuses the `:answer_question` guard action, which is the only existing action mapped to the `:edit_specifications` capability that owner and participant both hold. `ParticipantGuard` was not extended.
- Proof receipt: `Task 2` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/guided_requirements_test.exs test/sdd_orchestrator_web/live/feature_requirements_form_test.exs` — exit `0`.

`Task 5`, the started run's manifest.

- `RepositoryAssessments.approved_profile/2` answers the highest-version profile from `ProfileStore.list/2`, or `{:error, :no_execution_profile}`. `Start` derives the profile viewer from the storage authority; the actor's right to press start is already settled by `ParticipantGuard`.
- `manifest_for` no longer merges `execution_config()`, so no started run takes a value from configuration. `execution_config/0` itself stays until `Task 10`.
- Two corrections were taken with the user after the first pass. `manifest_version` moved to 2, because `reject_unknown_fields/1` would otherwise make a worker installed before this change refuse the new manifest with `unknown_manifest_field` rather than an honest version refusal. `ProtocolLimits.max_required_checks` moved from 50 to the profile's own 64, because an owner could approve a profile the manifest would then refuse to carry.
- The three golden fixtures were recomputed, not hand-edited, and renamed to `_v2`. New digest `4c090cc28660fdf335f491165d39923229a0c6653774031689aeb3f735afe66b`.
- 18 tests in `cancellation_test.exs`, `local_worker_run_governance_privacy_test.exs`, and `local_worker_runtime_governance_end_to_end_test.exs` now fail with `:no_execution_profile`, because `DeliveryFixtures.delivery_project_fixture/0` seeds no connected repository or profile. `Task 10` owns that fixture change. The four continuation builders pass untouched, which is what the empty field defaults are for.
- Proof receipt: `Task 5` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/start_test.exs test/sdd_orchestrator/delivery/execution_manifest_test.exs test/sdd_orchestrator/delivery/protocol_codec_test.exs` — exit `0`.

`Task 7`, the bound project's run topic.

- `Delivery.BoundProjectNotice` pushes `project_bound` and `project_unbound`, carrying the project id and nothing else, to every attachment `WorkerAttachment.attached/1` returns. Bindings are announced on connect, on disconnect through the single removal point in `HostedLocalRepositoryBindings.disconnect/2`, and on attach for every binding the Mac already holds.
- `Worker.ProjectConnections`, a `DynamicSupervisor` keyed by project id, opens one project-scoped `GatewayConnection` per bound project. That connection performs the existing credential exchange and join, so no connect, join, credential, or delivery code was written or changed.
- `DynamicSupervisor.start_child` reports an exit reason quoting the whole `%Configuration{}`, including `worker_credential`, and `Configuration` has no `Inspect` guard. `ProjectConnections.open/3` therefore drops the reason and answers `:project_connections_unavailable`. A test asserts the credential never reaches the log and that the Mac connection survives the failure.
- `WorkerChannel.confirm_execution_target/2` now reads the socket's project with `Map.get`. The specs/39 test that asserted `join crashed` was replaced with one asserting `unauthorized_execution_target`, no crash, and the same socket still attaching for its own Mac.
- Announcing on attach needs a database read in the channel join, so `worker_workspace_channel_test.exs` and its selection companion moved to `DataCase`; the first lost `async: true`.
- Proof receipt: `Task 7` — scope `Focused` — command `mix test test/sdd_orchestrator_web/channels/worker_workspace_channel_bound_project_test.exs test/sdd_orchestrator/worker/bound_project_connection_test.exs test/sdd_orchestrator_web/channels/worker_workspace_channel_test.exs test/sdd_orchestrator_web/channels/worker_workspace_channel_repository_selection_test.exs test/sdd_orchestrator_web/channels/worker_channel_test.exs test/sdd_orchestrator/worker/supervisor_test.exs test/sdd_orchestrator/worker/gateway_connection_test.exs test/sdd_orchestrator/worker/mac_scoped_connection_end_to_end_test.exs test/sdd_orchestrator/portability/hosted_local_repository_bindings_test.exs test/sdd_orchestrator/portability/hosted_local_repository_connection_test.exs` — exit `0`.
- All three receipts were confirmed on the main thread by real exit status.

### 2026-08-31 - Two decided mechanisms found unworkable, replaced with the user

Implementation of `Task 5` and `Task 7` stopped on the agreement, not on code. Both replacements were chosen by the user.

- The worker cannot join a project's run topic on its Mac socket. `WorkerSocket.connect/3` assigns `project_id` only from a project-scoped connect token, and `WorkerChannel.confirm_execution_target/2` compares the topic against `socket.assigns.project_id`. A Mac-scoped socket has no such key, so the join raises `KeyError` and crashes the channel instead of refusing. A join param is negotiated as a protocol contract and never read as a credential, so the project credential exchange the design relied on could not reach the check. Replacement: the worker starts a second project-scoped `Worker.GatewayConnection` per bound project, which reuses the whole verified connect, join, registry, and `deliver/1` path and leaves the topic's authorization untouched. The rejected alternative was to accept a credential as a join param, which widens a boundary `specs/33` and `specs/37` verified.
- The crash itself is a fail-closed defect predating this slice, from `specs/39`. `Task 7` now owns the one-line correction and its refusal test.
- The manifest cannot carry the profile's lists in `agent_ref` or `worker_ref`. Both are flat string maps capped at `ProtocolLimits.max_reference_bytes`, 512 bytes per value, while a profile holds up to 64 commands and scope entries of up to 1024 bytes each, so a legitimate profile could produce a manifest that `ExecutionManifest.validate_reference/2` refuses. Replacement: three typed fields, `repository_root`, `commands`, and `allowed_scope`, at `manifest_version` 1.
- `Task 5` as written was two outcomes. Removing `:delivery_execution` also forces the four other manifest builders, in `Answers` at `answers.ex:216`, `Retry` at `retry.ex:397`, `Reconciliation` at `reconciliation.ex:400`, and `ReviewContinuation` at `review_continuation.ex:116`, onto the profile, and ten test files set the key. Those four hold an authority and no actor, so they derive the profile viewer differently from `Start`. `DeliveryFixtures` also has no profile: both `AssessmentStore.Hosted.put/2` and `ProfileStore.Hosted.append/5` require a connected repository binding, which `delivery_project_fixture/0` does not create. Split: `Task 5` keeps the start manifest and AC-09; the new `Task 10` moves the four builders, seeds the fixtures, and deletes the key.
- Task labels stayed stable. The second half became `Task 10` rather than renumbering. The slice is now 10 tasks with a longest `Depends on:` path of 7, inside the Slice Size Gate.
- No code changed in this update.

### 2026-08-31 - Task 1 complete: a feature owns its specification from creation

- `Features.create/3` runs one `Repo.transaction`: it validates the title, resolves the project owner's `PersonalWorkspace` from the project, creates the specification through `SpecificationStore.create/4` under that authority with the acting person as the revision actor, inserts the feature, then links it. A refused specification rolls the whole thing back, so no feature is left behind.
- The empty requirements document is built at runtime from `Readiness.guided_structure/0`, so the four headings cannot drift from the structure readiness judges: `## The outcome`, `## Who it is for`, `## Rules that must hold`, `## How you will know it works`. Design and tasks documents are placeholders stating they belong to the coding agent.
- `Repo.transaction` was chosen over `Ecto.Multi` because the Multi form trips the known `Ecto.Multi` plus MapSet `call_without_opaque` dialyzer false positive, which would have needed an entry in the shared `.dialyzer_ignore.exs`.
- `@spec` for `create/3` widened to `{:error, atom() | Ecto.Changeset.t()}` to match `SpecificationStore`'s own refusals now surfacing through it.
- Rollback proved on the nested path too: `SpecificationStore.create/4` opens its own transaction, so the test forces a failure inside it and asserts a real `{:error, %Ecto.Changeset{}}` rather than `{:error, :rollback}`, with the feature count unchanged.
- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/feature_specification_creation_test.exs test/sdd_orchestrator/delivery/feature_lifecycle_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 19 tests passed.

### 2026-08-28 - Specification created after tracing the core loop to no UI

- Found by clicking through `http://localhost:4000` and grepping callers: `Delivery.Start.start/4` has no caller under `lib/`, `Features.transition/5` is called only by the browser-suite bootstrap, `FeatureBoardLive` has one event, `FeatureDetailLive` dead-ends at `Start development when you're ready.` with no control, `Readiness` is never called from the web layer, and no LiveView creates or revises a specification. Slice 07 is `Verified` on proofs that drive domain functions and `/_e2e/session` seeding.
- Diagnosis: a feature holds no text; readiness judges the project's first specification rather than one tied to the feature; `Start` builds its manifest from `:delivery_execution`, which only the bootstrap sets; the readiness guidance adapter is `Unconfigured` everywhere; a Mac-paired worker joins no project run topic, so `deliver/1` would find no worker.
- Product decisions taken with the user: each feature owns its specification; a structural check gates readiness and a configured model adds findings on top; `Start development` requires an approved execution profile; the hosted local-repository project is the first target and the accountless board is deferred.
- Engineering decisions recorded in `design.md`: the four-part guided document with fixed headings; structural findings merged with adapter findings and a not-configured flag; the manifest from the approved profile with `:delivery_execution` removed; `project_bound` over the Mac-scoped attachment with an on-demand project topic join; the preconditions readout shared with the start check.
- Scope: classified `focused specification`. One outcome, one workflow, one verification gate, nine tasks, longest `Depends on:` path of seven. `Task 6` and `Task 7` are blocked until `specs/40` and `specs/39` deliver their capabilities; `Task 1` through `Task 5` are executable now.
- No code changed in this update.
