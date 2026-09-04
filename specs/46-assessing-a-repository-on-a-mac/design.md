# Assessing A Repository On A Mac Design

## Context

`SddOrchestratorWeb.RepositoryAssessmentLive` serves two routes. Its `:device` action assesses a Git repository on the machine in front of the person, for an accountless device project, and it works. Its `:hosted` action assesses a hosted project's repository, and it gated on `active_hosted_project?/1`, which required `match?(%{state: "connected"}, project.repository_connection)`.

`SddOrchestrator.RepositoryAssessments.authorize_project/2` carried the same requirement at the domain boundary for `{:hosted, account_id}`.

It was not two gates. Implementation found the same GitHub-shaped requirement in five places across four modules, each one refusing the project a step further along the flow: the screen's gate, the domain's `authorize_project/2`, `AssessmentStore.Hosted.put/2`, that store's `lock_project_binding/1`, and the profile store's `active_binding?/2` together with its own `lock_project_binding/1`. The two `lock_project_binding/1` functions returned `nil` unless a `RepositoryConnection` row existed, so they refused by failing to find the project at all. The first slice replaced all five with one owned predicate, `RepositoryAssessments.assessable_hosted_project?/1`, and the screen opens.

### The screen opens, and then stops

`start_assessment` saves a pending row and sends nothing. The screen's own copy states it: `Starting saves a pending assessment. This task sends no repository scan command.` Nothing moves that row afterwards.

`RepositoryAssessments.finish_assessment/6` is complete and proven, and in `lib/` it has exactly one caller: `SddOrchestratorWeb.E2eBootstrapController`, which builds a scan result in Elixir and stores it. Every completed assessment in the product today was seeded by the browser-test bootstrap. Nothing a person can click has ever produced one.

The scanner is not what is missing. `RepositoryAssessments.WorkerRepositoryAssessment.scan_with_proposal/3` reads allowlisted blobs directly from the authorized commit and returns a minimized result and a strict proposal payload, and `WorkerRepositoryAssessmentCache.scan_with_proposal/4` wraps it with the exact-commit cache, the result, the envelope, and cache provenance. Both are covered by tests. Neither has a caller outside them.

What is missing is only the road between the two. Nothing carries a command to the Mac, and nothing carries an answer back.

### That road already exists, for a smaller question

`SddOrchestrator.RepositoryMetadata` asks a Mac's worker to read a repository's identity, normalized root, and current commit. It has a blocking call, a request-lifecycle server owning correlation, expiry and cancellation, a transport behaviour with an `Unavailable` default and an `Attachment` implementation keyed by device workspace, a codec closed to the fields a request is made of, a negotiated worker capability, a `repository_metadata` and `repository_metadata_result` message pair on `WorkerWorkspaceChannel`, and a worker-side handler. `specs/47-live-repository-metadata-binding/` proved the whole of it against a real Mac.

That worker-side handler already holds what a scan needs. `SddOrchestrator.Worker.RepositoryMetadata` keeps the folder the person picked in memory, keyed by `selection_ref`, precisely so a revalidate of the same binding attempt needs no second panel. A scan of the same binding carries the same `selection_ref`, so the path is already there to be scanned.

## Proposed Approach

Send the scan as a second question over the road the metadata question already travels, and change neither the scanner nor the proposal.

- One new context, `SddOrchestrator.RepositoryScan`, shaped like `RepositoryMetadata`: a blocking `run/2`, one open request per call, a server that owns correlation, expiry, and cancellation, a transport behaviour whose default refuses at once, an attachment transport aimed at one named worker in one device workspace, and a codec closed to the fields a scan command and its answer are made of.
- Its wait window is longer than the metadata one, and its own. Reading a repository is not stat-ing one folder, and the scanner already has its own limits: it refuses on its own time, file, path, and byte bounds before this window matters.
- The worker answers from the folder it already holds. The scan message carries the `selection_ref` the binding used, the worker resolves it to the held folder, and calls `WorkerRepositoryAssessmentCache.scan_with_proposal/4`. It opens no panel. A `selection_ref` it no longer holds is refused as expired, and the screen says the verified binding expired and offers to verify it again.
- The control plane trusts its own command, not the answer. The worker returns the minimized scan result and the proposal payload. The control plane rebuilds the result with `RepositoryAssessmentResult.completed/2`, checks the payload with `RepositoryExecutionProfileProposalPayload.valid_for?/3` against the command it issued, and builds the envelope with `WorkerRepositoryExecutionProfileProposalEnvelope.new/3` itself. An answer that does not match its command is refused and stored as a failure.
- The domain gets one caller behind an adapter, exactly as the metadata read already has one: a `RepositoryScanAdapter` behaviour with a `Worker` implementation and an `Unavailable` default, configured to the real one everywhere and pinned to the refusing one in tests. A test installs a double; nothing reaches a worker by accident.
- Every ending is terminal. `RepositoryAssessmentResult.failed/2` and `canceled/1` already exist, and each ending other than a completed scan writes one of them through the same `finish_assessment/6`. A row left at `pending_scan` then means one thing, a scan still running, instead of meaning both that and a request abandoned months ago.
- The screen waits the way it already waits. `start_async` with a stop control mirrors the binding preparation directly above it, so the screen keeps one wait behaviour rather than growing a second.

## Components Affected

- `SddOrchestratorWeb.RepositoryAssessmentLive`: the hosted route's assessability gate, the repository label for a project whose repository is on a Mac, the not-reachable state, and the scan the start now runs, with its running, completed, stopped, and failed states.
- `SddOrchestrator.RepositoryAssessments` (`authorize_project/2`): the same assessability rule at the domain boundary, and the one place that owns it.
- `SddOrchestrator.RepositoryAssessments.AssessmentStore.Hosted`: its own copy of the rule in `put/2`, and its `lock_project_binding/1`.
- `SddOrchestrator.RepositoryAssessments.ProfileStore.Hosted`: `active_binding?/2` and its `lock_project_binding/1`.
- `SddOrchestrator.RepositoryScan`: the new context, its request and answer values, its codec, its request-lifecycle server, and its transport with an unavailable default and an attachment implementation.
- `SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter`: the domain's boundary to that context, with a worker-backed implementation and a refusing default.
- `SddOrchestrator.RepositoryAssessments`: the one function that takes a pending assessment to a terminal one, issuing the command and writing the answer through `finish_assessment/6`.
- `SddOrchestrator.Worker.RepositoryScan` and `SddOrchestrator.Worker.GatewayConnection`: the worker's side of a scan message, the held folder it scans, and the declared capability that makes the worker askable.
- `SddOrchestratorWeb.WorkerWorkspaceChannel`: the scan, cancellation, and result frames beside the metadata ones it already carries.

## Data and Access Boundaries

- No new stored record. The completed and failed assessment rows, their cache provenance, and the proposal envelope are the existing shapes `finish_assessment/6` already writes. This slice supplies real values where only a seeded scenario supplied them before.

Required boundaries:

- Authorization is unchanged. The acting person must still own the project, and every check that runs today still runs. Widening what counts as reachable must not widen who may act.
- A repository on a Mac is admitted only through its own worker binding. A hosted project with neither a connected GitHub connection nor a binding stays refused.
- A scan command is aimed at one named worker in one device workspace, never at whoever is attached. An answer from any other attachment is refused.
- A scan command carries opaque references and digests: the assessment's own command fields and the `selection_ref` the binding used. It carries no filesystem path, remote URL, or file name.
- An answer carries the scanner's already-minimized result and proposal payload, whose evidence is repository-relative anchors, sizes, line counts, and content digests. That shape is `specs/14-repository-execution-profile/`'s and is unchanged here. Nothing this slice sends, stores, renders, or logs may carry an absolute or filesystem path, a remote URL, a commit message, or file content.
- The `:device` route and the accountless flow behind it are untouched.

## Interfaces

- `RepositoryAssessments.authorize_project/2` admitting a hosted project whose repository is on a Mac, and refusing one that is reachable by neither route.
- `RepositoryScan.run/2`, blocking the caller until exactly one outcome is known, and `RepositoryScan.answer/2`, the entry point one worker's attachment calls with its result.
- `RepositoryScanAdapter.scan/1`, the domain's one way to ask, defaulting to a refusal.
- One `RepositoryAssessments` function taking a pending assessment to a terminal one, whose outcome is a stored assessment in every case.
- Compatibility that must hold: the GitHub assessment screen's rendering and labeling, the device route, the disclosure digest and the proposal envelope, the existing metadata question over the same attachment, and every refusal for a person who does not own the project. Whether a GitHub assessment can be started and approved is narrowed by `specs/47-live-repository-metadata-binding#Task 8`. See AC-05.

## Decisions and Tradeoffs

### Assessability is reachability, not a GitHub connection

- Choice: A hosted project is assessable when its repository is reachable, by a connected GitHub connection or by a worker binding.
- Reason: The screen exists to scan a repository. Requiring a `RepositoryConnection` asked whether the repository is on GitHub, which was the same question only while GitHub was the only source. `specs/44` made it a different question.
- Consequence: Two gates now name two ways of being reachable instead of one, and a third source would add a third. That is the honest shape: the alternative is a screen that silently serves some hosted projects and not others.

### The unreachable Mac is a state, not a redirect

- Choice: The screen opens for a bound project whose Mac is not reachable, names that, and offers no start.
- Reason: The redirect is what made this defect expensive to find, and the product already prefers naming an unmet requirement: `specs/41`'s start section lists each one with the link that resolves it.
- Consequence: The screen has one more state to render and to prove. A person who cannot start still learns why, which is what the business rule asks for.

### The label is the device route's existing wording

- Choice: A repository on a Mac is named the way the same screen's device route already names one.
- Reason: The product holds no repository name for such a project, only the folder name that became the project name. One wording for one fact is this repository's rule, and a second phrasing on the hosted route would drift from the device route saying the same thing.
- Consequence: The two routes share a sentence, so changing it changes both, which is the intent.

### A scan is a second question on the road the metadata question already travels

- Choice: A new `RepositoryScan` context mirrors `RepositoryMetadata` rather than extending it, and reuses its attachment, its channel, its capability negotiation, and its worker process.
- Reason: The two questions have different sizes, different wait windows, different answers, and different failure vocabularies. Folding a repository scan into a module whose contract is four fields would make one boundary that is honest about neither. Copying the shape keeps both readable and lets each move on its own.
- Consequence: Two contexts with a visibly similar skeleton. That similarity is load-bearing rather than accidental duplication, and a later change to how a worker is reached still has two callers to update.

### The worker scans the folder it already holds, and opens no panel

- Choice: The scan carries the binding's `selection_ref`, the worker resolves it to the folder it is already holding, and a hold that is gone is refused as expired.
- Reason: The person picked that folder once, for this binding. Opening a native panel on their Mac because a hold quietly lapsed is the product acting without being asked, and it would also let a scan run against a folder the binding never verified.
- Consequence: A slow person can lose the hold and has to verify the binding again. That is one repeated step, and it is honest about what the product still knows.

### The control plane rebuilds the result and the envelope from its own command

- Choice: The worker's answer supplies the minimized scan result and the proposal payload, and the control plane rebuilds the result, revalidates the payload against the command it issued, and builds the envelope itself.
- Reason: The command is the control plane's own; the answer is not. Storing an envelope the worker constructed would make the authoritative record something a worker asserted rather than something the control plane derived.
- Consequence: The same derivation exists on both sides, and the worker's cached envelope is discarded on arrival. That is the price of the authoritative record being derived here.

### Two things the control plane cannot re-derive, and what bounds them instead

- Choice: The worker's cache provenance crosses as `source` and `cache_stored`, and the six proposal fields are taken as the worker's word, bounded by their own validation rather than by re-derivation.
- Reason: Both are facts this side cannot compute. A cache's provenance is a fact about a cache the control plane cannot see, and inventing `fresh_scan` for every answer would make the stored record a guess. Deriving a proposal needs the repository's file contents, which deliberately never leave the Mac, so `RepositoryExecutionProfileProposalPayload.derive/3` can only run there; `valid_for?/3` checks a payload's self-consistency and its binding to the command and result, not that the evidence implies it.
- Consequence: A worker could assert a command its findings do not evidence. What is enforced is the payload's own validation: a known command shape, required checks drawn from the commands, a scope inside the root, allowlisted gap and conflict codes, and item and byte bounds. The two provenance digests are still derived here, so a worker can say where its answer came from but not what it is a digest of.

### Every ending is terminal, so a pending row means one thing

- Choice: A refusal, a lost worker, an unanswered window, and a stopped wait all write a terminal assessment through `finish_assessment/6`.
- Reason: `RepositoryAssessmentResult.failed/2` and `canceled/1` already exist and the store already accepts them. Leaving a row at `pending_scan` after a failure would make that state mean both a scan in flight and a scan that died, and nothing later could tell them apart.
- Consequence: A person retries by starting a new assessment, not by resuming the old one, and the history shows each attempt. The alternative, one row per attempt with a retry, was considered and rejected for the ambiguity it puts back into `pending_scan`.

## Risks

- Five gates in four modules can drift. They must read one predicate and be proven together, or a project will be admitted at one step and refused at the next, which is exactly the shape of the defect that was fixed.
- The two `lock_project_binding/1` functions refuse by answering `nil`, which reads as a missing project rather than a refused one. Widening them had to keep the provider and repository-identity checks that sit beside them, so a project is still matched to its own assessment.
- Widening an authorization gate is the kind of change that can quietly admit more than intended. The proof has to include a hosted project that is reachable by neither route, and a person who does not own the project.
- A long-running blocking call over a socket is a new load shape for this control plane. The scanner's own limits bound the work, but the wait window, the caller's monitor, and the transport's lost-attachment path have to resolve one outcome exactly once, or a LiveView is left waiting on a request nobody will answer.
- The worker's held folder was designed for a revalidate that follows a prepare within seconds. A scan follows a person reading a disclosure and pressing a button, so the expired-hold path is the normal path, not the rare one, and it must be proven as such.
- Two derivations of the same envelope, one on the worker and one on the control plane, can diverge. The control plane's revalidation of the payload against its own command is what catches that, and it has to refuse rather than store a mismatch.
- A scan answer is much larger than a metadata answer, and it is the first worker payload big enough for a size limit to matter. A refused frame must end as a named failure, not as a silent timeout.
- A scanner result uses atom keys and a metadata answer uses strings, so the wire crossing is not a pass-through. The codec has to rebuild the exact atom-keyed shape `RepositoryAssessmentResult.completed/2` validates, and a loose rebuild that accepts unknown keys would undo the closed boundary the metadata codec established.

## Open Questions

- None.
