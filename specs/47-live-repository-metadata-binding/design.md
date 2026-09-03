# Live Repository Metadata Binding Design

## Context

`RepositoryAssessments.prepare_binding/4` and `consume_binding/4` both go through `RepositoryMetadataAdapter`, and `configured/0` falls back to its sibling `Unavailable`, whose `prepare/1` and `revalidate/1` return `{:error, :worker_unavailable}` for every input. No configuration file in any environment sets `:repository_metadata_adapter`. The only code that sets it is the `/_e2e` bootstrap controller, which is compiled out of every build that does not enable `:e2e_bootstrap`. The other implementations of the behaviour are test stubs. So the assessment screen refuses every project outside tests, including a GitHub-connected one, and `specs/46-assessing-a-repository-on-a-mac/` recorded that as `specs/14-repository-execution-profile/`'s release gate rather than a defect.

The worker-local half already exists and is verified. `RepositoryAssessments.WorkerRepositoryMetadata.inspect/4` takes an absolute repository path, a selected root, the expected identity, and an identity matcher, and returns exactly the four fields the adapter contract allows: provider, repository id, normalized relative root, and full commit. It resolves the repository top level, follows links, proves containment, and reads `HEAD`. Nothing in this slice needs to be added to it.

What is missing is a path. Nobody has one. `specs/40-worker-repository-selection/` deliberately made the chosen folder disappear: the app writes it to `selection_answer.json`, the release deletes that file as soon as it reads it, and the path then lives only in the local variables of one function. `HostedLocalRepositoryBinding` stores the project, the worker, and a validation time. The project stores a portable repository identity, not a location. `Delivery.Worker.Workspace` names a run's own directory under a configured root, which is where a run works, not where the person's repository is.

The transport this needs already has a precedent that fits exactly. `specs/40` added `repository_selection`, `repository_selection_cancel`, and `repository_selection_result` to the Mac-scoped attachment from `specs/39-mac-scoped-worker-connection/`, with its own small codec, an optional capability negotiated at attach, a control-plane request lifecycle that refuses foreign answers, and a worker-side holder that shows the panel through two owner-only files the installed app already polls. That app-facing file pair carries a request id and a chosen path and nothing else, so it is not specific to folder selection.

`specs/14`'s binding lives for 120 seconds and is single use. `prepare_binding/4` and `consume_binding/4` are synchronous and are called from the LiveView process.

## Proposed Approach

Add one live adapter that asks the person's own attached worker for the repository metadata, and answer it on the worker by asking the person to point at the folder.

- A `RepositoryMetadata` context on the control plane owns one question and one answer. `inspect/2` takes the adapter request, opens an in-memory record bound to the calling process, pushes the question to the named worker's Mac-scoped attachment, and blocks that caller until exactly one outcome arrives: the four metadata fields, a refusal, a cancellation, a timeout, or the loss of the attachment. It is synchronous because `RepositoryMetadataAdapter`'s callbacks are, and that contract is `specs/14`'s and stays as verified. An answer for a request that is not open reaches nobody.
- The attachment gains `repository_metadata` and `repository_metadata_cancel` outbound and `repository_metadata_result` inbound, with their own codec, mirroring `specs/40`'s pair. `repository_metadata` is added to `Delivery.WorkerProtocol`'s optional capabilities and to the worker's hardcoded twin, because `negotiate/1` drops any announced name outside its vocabulary. `ProtocolCodec` and the project-scoped `worker:` topic are untouched.
- The request rides the Mac-scoped attachment, not the project topic, for the same reason `specs/40`'s does: the assessment names a device workspace and a worker the person chose, and a device-authoritative project has no hosted project topic at all.
- On the worker, `Worker.RepositoryMetadata` answers the question. It needs a folder, and the Mac's one folder panel is already owned by `Worker.RepositorySelection`. That module gains one additive entry point that opens the same pending file and answers a chosen path to an in-release caller instead of building a selection result. Keeping one panel owner is what stops two features showing two panels and writing the same file.
- Once it has a folder, the worker calls the verified `WorkerRepositoryMetadata.inspect/4` with `PortableRepositoryIdentity.match/2` as the matcher, and replies with the four fields or one refusal atom. The folder is then held in memory, keyed by the request's selection reference, until the binding's own expiry passes.
- The revalidation that `start_assessment/4` performs arrives as a second question carrying the same selection reference. The worker finds the held folder, re-reads the commit, and answers without a panel. A worker with no held folder answers unavailable, which `consume_binding/4` already reports as stale. That is the correct reading: the proof that nothing changed is gone.
- The live adapter becomes the configured one in `config/config.exs`, so a plain development server and a release both use it. `config/test.exs` selects `Unavailable`, which is what the suite gets today by default, so no existing test changes behaviour. The `/_e2e` bootstrap keeps its own runtime override and the browser suite is unaffected.
- The assessment screen stops calling `prepare_binding/4` inline. A native panel takes a person tens of seconds, and a LiveView that blocks for that long cannot render a waiting state or accept a cancel. The call moves into a monitored task, the screen renders one waiting state with a stop action, and stopping cancels the request so the panel closes on the Mac.
- The screen also stops offering a start it cannot honour. A project whose repository identity is not a portable local one has no folder on this Mac to point at, so the screen says that in the disclosure stage and offers no confirmation. Who may open the screen is unchanged; `specs/46`'s assessability rule stays exactly as verified.

## Components Affected

- `SddOrchestrator.RepositoryMetadata` (new): the request lifecycle, correlation, expiry, cancellation, and refusal of foreign answers.
- `SddOrchestrator.RepositoryMetadata.Transport`, `.Transport.Unavailable`, `.Transport.Attachment`, and `.AttachmentCodec` (new): the hand-off to one named attached worker.
- `SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter.Worker` (new): the live implementation of the behaviour `specs/14` defined.
- `SddOrchestrator.Delivery.WorkerProtocol`: one added optional capability name.
- `SddOrchestratorWeb.WorkerWorkspaceChannel`: one outbound push pair and one inbound frame.
- `SddOrchestrator.Worker.GatewayConnection`: the capability twin and two inbound message handlers with the deferred-push reply shape it already uses.
- `SddOrchestrator.Worker.RepositorySelection`: one additive entry point that answers a chosen folder to an in-release caller.
- `SddOrchestrator.Worker.RepositoryMetadata` (new): identity match, root resolution, commit read, held folder, and cancellation.
- `SddOrchestrator.RepositoryAssessments.WorkerRepositoryMetadata`: called on the worker; no change.
- `SddOrchestratorWeb.RepositoryAssessmentLive`: the waiting and stop states, the refusal wording, and the not-on-a-Mac state.
- `config/config.exs` and `config/test.exs`: which adapter is configured.

## Data and Access Boundaries

- `MetadataRequest`: one in-memory record per open question on the control plane, holding the request id, the process waiting on it, the device workspace and worker it was sent to, the project and repository identities it carries, the selection reference, the selected relative root, and the expiry. It is never persisted and disappears on answer, refusal, cancellation, expiry, or the waiting process exiting.
- `HeldRepositoryFolder`: the worker's memory of the folder it just answered for, keyed by the request's selection reference and holding the absolute path and the moment it stops being usable. It exists only inside the release process, is never written to disk, never logged, and never sent. It is dropped when its moment passes, when the request is cancelled, and when the release stops.

Required boundaries:

- A question may be asked only of a worker that is attached now, paired to the device workspace the request names, and negotiated for `repository_metadata`. `specs/14`'s owner, device-workspace, worker, and disclosure checks all run before the adapter is reached and are unchanged.
- The channel accepts a result only from the attachment the question was pushed to, and the context delivers it only to the process that asked. A result for an unknown, foreign, cancelled, or expired request is refused and reaches nobody.
- A question carries the project id, the repository provider and identity, the device workspace id, the worker reference, the selection reference, the selected relative root, and the two digests. That is the request `specs/14` already defined, and nothing is added to it.
- An answer carries the repository provider, the repository id, the normalized relative root, and the full commit. That is the result `specs/14` already defined, and nothing is added to it.
- No filesystem path, remote URL, Git history, file name, or file content enters a question, an answer, a log line, a diagnostic, an analytics event, or any stored record on either side. Refusals are single atoms, so a Git error message cannot travel as a reason.
- The chosen folder exists in two places on the Mac and nowhere else: in `selection_answer.json` for at most one poll interval, which is `specs/40`'s rule and its deletion on read is unchanged, and in the release's memory for at most the binding's own life.
- The worker answers only for a folder whose portable identity matches the identity the project holds. A project whose identity is not a portable local one is refused before any panel opens.

## Interfaces

- Attachment message `repository_metadata` (control plane to worker): `request_id`, `selection_ref`, `repository_provider`, `repository_id`, `selected_root`, `expires_at`. Attachment message `repository_metadata_cancel` (control plane to worker): `request_id`. Attachment message `repository_metadata_result` (worker to control plane): `request_id`, `outcome`, and for a success the four fields `repository_provider`, `repository_id`, `root`, `commit`.
- `RepositoryMetadata.inspect(request, opts)` returning `{:ok, result}` or `{:error, reason}` with `reason` in `:worker_unavailable`, `:repository_mismatch`, `:cancelled`, `:timeout`, and `:invalid_worker_response`, and `RepositoryMetadata.cancel/1`.
- `RepositoryMetadataAdapter.Worker.prepare/1` and `revalidate/1`, satisfying the behaviour `specs/14` defined without changing it.
- `Worker.RepositorySelection`'s added entry point, which opens the existing pending file and answers one chosen path or a cancellation to an in-release caller. The two app-facing files, their names, their contents, and the deletion on read are unchanged, so the installed Mac app needs no rebuild for this slice.
- Compatibility that must hold: `RepositoryMetadataAdapter`'s request and result types, `prepare_binding/4`, `consume_binding/4`, `start_assessment/4`, the binding's 120 second single-use window, `specs/46`'s assessability rule, `specs/40`'s selection request and its path rule, the project-scoped `worker:` topic, `ProtocolCodec`, run execution, and the browser suite's existing scenarios through the `/_e2e` override.

## Decisions and Tradeoffs

### The person points at the folder each time a binding is prepared

- Choice: The worker opens the folder panel when it is asked for metadata and has no folder held for that selection reference.
- Reason: Nothing on either side knows where the repository is. The alternatives were to keep a path on the Mac when the repository is connected, which breaks the promise `specs/40` made and would need that specification reopened, or to search a configured root, which reads folder names and breaks whenever the repository moves.
- Consequence: One extra native panel per assessment. The person points at the same folder they pointed at when they connected the project, which is honest about what is being read.

### The folder is held in memory for the binding's life

- Choice: The worker keeps the answered folder, keyed by the selection reference, until the binding's expiry passes.
- Reason: `start_assessment/4` revalidates through the same adapter with the same request. Without a held folder the person would answer a second panel for one assessment, and the second answer would prove nothing the first did not.
- Consequence: A path now lives in the release's memory for up to two minutes, where `specs/40` kept it only inside one function. That widening is bounded by the binding's own window, is never written or sent, and is why the release restart case is an acceptance criterion rather than an implementation detail.

### The adapter stays synchronous and the screen moves the call into a task

- Choice: `RepositoryMetadata.inspect/2` blocks its caller, and `RepositoryAssessmentLive` calls `prepare_binding/4` from a monitored task while it renders a waiting state.
- Reason: The adapter behaviour is `specs/14`'s and is verified. Making it asynchronous would change a contract this slice is not allowed to reopen, and would push waiting into the domain, where nothing can render it.
- Consequence: The LiveView owns the waiting, the stop action, and the task's exit. A task that dies without answering is reported as a failed verification the person can retry.

### One panel owner on the Mac

- Choice: `Worker.RepositorySelection` gains an entry point that answers a path, and the metadata responder goes through it.
- Reason: The pending and answer files are one pair, and the installed app polls one pending file. Two writers would show two panels and overwrite each other's questions.
- Consequence: A folder selection and an assessment cannot be open at the same moment on one Mac. That is correct: there is one person and one panel.

### The live adapter is configured for every environment except test

- Choice: `config/config.exs` names the worker adapter; `config/test.exs` names `Unavailable`.
- Reason: The gap this slice closes was caused by a default nobody set. A default that is only correct in tests is the same defect again. Selecting `Unavailable` explicitly in the test environment keeps every existing suite byte-identical, because that is what they resolve to today.
- Consequence: A development server with no worker attached now refuses at the transport with no worker rather than at a stand-in, which is the truthful answer.

### GitHub-only repositories are named, not silently refused

- Choice: The screen states in the disclosure stage that this assessment reads a repository on a paired Mac, and offers no confirmation, when the project's repository identity is not a portable local one.
- Reason: Once the adapter is live, such a project would open a panel, have the person pick a folder, and then be refused with a message about a repository connection. `specs/46` already recorded that wording as GitHub-shaped and misleading.
- Consequence: Assessing a local clone of a GitHub repository stays impossible in this slice, and it is now visibly impossible rather than confusingly refused. Making it work needs the expected repository name in the adapter request, which is `specs/14`'s contract and a later agreement change.

## Risks

- The panel and the binding share a 120 second window. A person who takes a long time in the panel leaves less time to press start, and the binding then expires and is reported as stale. The window is `specs/14`'s and is not changed here; the screen's refusal already tells the person to verify again.
- `git` may resolve differently under the installed app than in a developer's shell. The worker answers a single refusal atom and the product proof runs against the installed app, which is where that difference shows.
- The held folder makes a second question cheap, so a defect that reuses a stale reference would read the wrong repository. The reference is generated fresh per attempt by the screen, and the identity match runs on the held folder as well as on a freshly picked one.
- A request can outlive the process waiting on it when a tab closes. The record is bound to that process, is dropped on its exit, and the worker is told so the panel closes.
- Making the live adapter the default changes what an unconfigured environment does. The test environment is pinned explicitly and the browser suite keeps its runtime override, so the change is visible only where a real worker is expected.

## Open Questions

- None.
