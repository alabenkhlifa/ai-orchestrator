# Live Repository Metadata Binding Tasks

## Status

Not Started

## Active Slice

Prepare and revalidate a repository binding against a real attached worker, so the assessment screen shows the repository's own identity, normalized root, and exact commit read from the person's Mac, and saves one pending assessment without a stub, a seed, or a stand-in.

## Cross-Specification Dependencies

Requires:

- `capability:mac-scoped-worker-connection` — provider `specs/39-mac-scoped-worker-connection#Task 8` — required before `Task 3`.
- `capability:worker-repository-selection` — provider `specs/40-worker-repository-selection#Task 9` — required before `Task 4`.
- `capability:mac-repository-assessment` — provider `specs/46-assessing-a-repository-on-a-mac#Task 3` — required before `Task 7`.

Provides:

- `capability:live-repository-metadata-binding` — ready after `Task 8`.

## Slice Size Gate

- Slice size: Standard
- One outcome, one verification gate, eight tasks, and a longest `Depends on:` path of seven: Task 1, Task 2, Task 3, Task 5, Task 6, Task 7, Task 8.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- No exception is required.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One optional worker capability name for repository metadata, on both sides of the negotiation.
- A control-plane request lifecycle for one metadata question and its single outcome.
- The Mac-scoped attachment message pair and codec that carry the question, its cancellation, and its answer.
- A worker-side responder that gets a folder through the Mac's one panel owner, matches identity, resolves the root, reads the commit, and holds the folder for the binding's life.
- The live adapter implementing the behaviour `specs/14-repository-execution-profile/` defined, and the configuration that selects it outside tests.
- The assessment screen's waiting state, stop action, live readout, and not-on-a-Mac state.

Excluded:

- The repository scan, its command, its result, and the completion that follows.
- Approving an execution profile, which needs a completed assessment.
- Any change to the adapter's request or result types, the binding's window, the disclosure, or how an assessment is stored. Those are `specs/14-repository-execution-profile/`'s.
- Any change to who may open the assessment screen, which is `specs/46-assessing-a-repository-on-a-mac/`'s rule.
- Any change to `specs/40-worker-repository-selection/`'s selection request, its two app-facing files, or its deletion on read.
- Any change to the installed Mac app. This slice reuses the file exchange the app already serves.

Deferred after this slice:

- The live scan and completion, so a pending assessment can reach a terminal state against a real Mac. This is the named follow-on specification and it is what `specs/41-feature-delivery-from-the-ui/` still waits on.
- Assessing a local clone of a repository that lives on GitHub. It needs the expected repository name in the adapter request, which is `specs/14-repository-execution-profile/`'s contract and a later agreement change.

Release gates:

- `specs/14-repository-execution-profile/`'s "live configured worker smoke proof for each supported deployment profile" closes only when this slice and the deferred live scan are both verified. This slice proves the binding half for the hosted route and the device route.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Add the repository metadata capability to the protocol vocabulary.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let a worker announce that it can answer a metadata question, so a request is never pushed to a worker that cannot read it.
  - Owned surfaces: `Delivery.WorkerProtocol` optional capability list and the worker's hardcoded twin in `Worker.GatewayConnection`.
  - Owns: none
  - Proof: Focused protocol tests prove the name is granted when announced, dropped when not, and that no required capability, envelope type, command operation, or event type changed.
  - Delivered: `repository_metadata` added to `WorkerProtocol.@optional_capabilities` and to `GatewayConnection`'s hardcoded twin, identically. `negotiate/1`'s existing tests reference `WorkerProtocol.capabilities/0` dynamically rather than a hardcoded list, so no test needed a change; the existing `"matches SddOrchestrator.Delivery.WorkerProtocol exactly"` test proves the two files still agree.

- [x] Task 2 — Establish the control-plane metadata request lifecycle.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Own one question, one answer, and exactly one outcome, so the adapter can block on a real answer and a foreign answer reaches nobody.
  - Owned surfaces: `RepositoryMetadata` context, its in-memory request record, correlation, expiry, cancellation, requester exit, the `Transport` behaviour, and the `Unavailable` default.
  - Owns: entity:MetadataRequest
  - Proof: Focused lifecycle tests prove one outcome per request, that an unknown, foreign, cancelled, or expired answer changes nothing, that a lost attachment ends the wait, and that no path, remote, or file name appears in a record or a log line.
  - Delivered: `RepositoryMetadata.inspect/2` blocks its caller — the outer `GenServer.call/3` is given `:infinity`, and `RepositoryMetadata.Server` owns the actual expiry through its own timer, replying via `GenServer.reply/2` exactly once from whichever path settles the request (a worker's `MetadataAnswer`, the worker's channel going down, the requester going down, or the expiry timer). `answer/2`, `MetadataRequest`, `MetadataAnswer` (strict allowlisted-key parsing, mirroring `SelectionResult`), and `Transport`/`Transport.Unavailable` complete the lifecycle. No `cancel/1`: the calling process is expected to be a supervised task, and its own exit is the cancellation path. `SddOrchestrator.RepositoryMetadata.Server` added to the application's supervision tree beside `RepositorySelection.Server`.

- [ ] Task 3 — Carry the question and its answer over the Mac-scoped attachment.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Reach the one worker the person chose, and accept an answer only from the attachment the question was pushed to.
  - Owned surfaces: `RepositoryMetadata.Transport.Attachment`, its codec, and the `WorkerWorkspaceChannel` outbound push pair and inbound result frame.
  - Owns: AC-05
  - Proof: Focused transport and channel tests prove the question reaches the named capable worker, that an unattached worker is refused before anything is pushed, that a worker without the capability is refused as needing an update, and that the payload is closed to its declared fields.

- [x] Task 4 — Let the Mac's panel owner answer a chosen folder to an in-release caller.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Keep one owner of the pending and answer files, so a second feature can ask for a folder without showing a second panel or overwriting the first question.
  - Owned surfaces: `Worker.RepositorySelection`'s added entry point and its held-request shape.
  - Owns: none
  - Proof: Focused worker tests prove the added entry point opens the same pending file, answers one chosen path or a cancellation to its caller, and leaves the existing selection request, its result payload, its file names, and its deletion on read unchanged.
  - Delivered: `request_path/3` added alongside `open/3`, both funneling into one `handle_cast({:open, payload, reply, home_override, result_builder}, state)` clause. The held-request map gains one `:result_builder` field (`&result/2` for `open/3`, an identity pass-through for `request_path/3`); `finish/2` calls `request.reply.(request.result_builder.(request, choice))`. `open/3`'s signature, doc, and every existing test are unchanged.

- [ ] Task 5 — Answer the metadata question on the worker.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3, Task 4
  - Purpose: Turn a folder the person points at into the four fields the adapter contract allows, and hold that folder so the revalidation needs no second panel.
  - Owned surfaces: `Worker.RepositoryMetadata`, the identity match, the call into the verified `WorkerRepositoryMetadata.inspect/4`, the held folder and its expiry, the cancellation path, and the two `Worker.GatewayConnection` inbound handlers.
  - Owns: AC-03, AC-07, AC-08, entity:HeldRepositoryFolder
  - Proof: Focused worker tests prove a matching folder answers the four fields, a non-matching folder is refused and nothing is held, a second question with the same reference answers from the held folder with no panel, a held folder is dropped at its expiry and at restart, and no path, remote, history, file name, or content appears in an answer or a log line.

- [ ] Task 6 — Implement the live adapter and configure it outside tests.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Make `RepositoryMetadataAdapter.configured/0` resolve to a real worker in every environment a real worker is expected, so preparation and revalidation stop falling back to `Unavailable`.
  - Owned surfaces: `RepositoryAssessments.RepositoryMetadataAdapter.Worker`, its mapping of outcomes to the atoms the assessment service reads, and the adapter selection in `config/config.exs` and `config/test.exs`.
  - Owns: AC-04, AC-09
  - Proof: Focused adapter tests prove `prepare/1` and `revalidate/1` satisfy the behaviour, that a refusal maps to the atom the assessment service reads, that a revalidation opens no panel, and that a hosted and a device-authoritative project both reach the configured adapter and persist in their own store.

- [ ] Task 7 — Show the wait and let the person stop it.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 6
  - Purpose: A native panel takes tens of seconds, so the screen must stay alive, say what it is waiting for, and be able to stop.
  - Owned surfaces: `RepositoryAssessmentLive`'s monitored preparation task, the waiting stage and its copy, the stop action, the cancellation of the open request, and the task-failure path.
  - Owns: AC-01, AC-06
  - Proof: Focused LiveView tests prove confirming renders the waiting stage with a stop action, that stopping cancels the request and returns the screen to the disclosure stage with nothing saved, that a task that dies without answering is reported as a retryable failure, and that the copy uses no em dash and claims nothing about the app being installed.

- [ ] Task 8 — Show the real repository, and name a repository that is not on a Mac.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 7
  - Purpose: Present what the worker actually read, and stop offering a confirmation for a project that has no folder on this Mac to point at.
  - Owned surfaces: `RepositoryAssessmentLive`'s verified-binding readout for a live answer, the refusal wording for a folder that is not this project's repository, the not-on-a-Mac disclosure state, and `capability:live-repository-metadata-binding`.
  - Owns: AC-02, AC-10
  - Proof: Focused LiveView tests prove the identity, normalized root, and full commit the worker answered are rendered before start, that a project whose repository identity is not a portable local one is told this assessment reads a repository on a paired Mac and is offered no confirmation, and that who may open the screen is unchanged.

## Verification Gate

- [ ] Acceptance criteria pass
- [ ] Relevant automated tests pass
- [ ] Build and type checks pass
- [ ] `mix check` passes at slice scope
- [ ] `npm --prefix assets run test:e2e` passes at slice scope
- [ ] `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` pass
- [ ] `python3 .agents/scripts/validate_spec.py specs/47-live-repository-metadata-binding` and `python3 .agents/scripts/split_progress_log.py --check` pass
- [ ] Product proof, hosted route: one click path from `/` in a real browser against the installed Mac app, worker stand-in off, no `/_e2e` seeding, reaching the verified repository, root, and commit and a saved pending assessment, recorded in `progress.md`
- [ ] Product proof, device route: the same click path for a device-authoritative project, recorded in `progress.md`
- [ ] New decisions are written back
- [ ] Deferred work is recorded

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
