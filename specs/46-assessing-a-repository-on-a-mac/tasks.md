# Assessing A Repository On A Mac Tasks

## Status

In Progress

## Active Slice

Run the repository scan on the Mac that holds it, so pressing `Start assessment` leaves a completed assessment with an approvable proposal instead of a saved request nothing ever moves: one scan question over the attachment the metadata question already uses, one worker that scans the folder it already holds, and one control-plane caller that stores every ending.

## Cross-Specification Dependencies

Requires:

- `capability:hosted-local-repository-projects` — provider `specs/44-hosted-local-repository-projects#Task 4` — required before `Task 1`.
- `capability:mac-scoped-worker-connection` — provider `specs/39-mac-scoped-worker-connection#Task 8` — required before `Task 6`.

Provides:

- `capability:mac-repository-assessment` — ready after `Task 3`.
- `capability:live-repository-scan` — ready after `Task 9`.

## Slice Size Gate

- Slice size: Standard
- Nine tasks total, six of them active, and a longest `Depends on:` path of five: `Task 4`, `Task 5`, `Task 6`, `Task 8`, `Task 9`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state. `Task 1` records the one exception in this plan.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One scan question with its own request, answer, closed codec, request lifecycle, wait window, cancellation, and transport, carried over the Mac-scoped worker attachment the metadata question already uses.
- The worker's side of that question: scanning the folder it already holds for the binding's `selection_ref`, through the existing worker-local scanner and its exact-commit cache.
- The one control-plane caller that issues a pending assessment's command, revalidates the answer against it, derives the authoritative envelope, and stores every ending through `finish_assessment/6`.
- The screen's running, completed, stopped, failed, and expired-binding states for the scan its start now runs.

Excluded:

- What the scanner reads and how a proposal is derived from it, owned by `specs/14-repository-execution-profile/`. This slice calls the scanner and stores its answer, and changes neither.
- Scanning a repository connected through GitHub, whose limitation and wording are owned by `specs/47-live-repository-metadata-binding/`.
- Running a scan the person is not watching, and telling them later that it finished.
- The `:device` route and the accountless flow behind it.
- Connecting, reconnecting, or moving the Mac, owned by `specs/37-hosted-local-repository-connection/`.
- Pressing `Start development`, owned by `specs/41-feature-delivery-from-the-ui/`.
- Every other screen that assumes a hosted project has a GitHub repository connection.

Deferred after this slice:

- Auditing the remaining screens for the same assumption. The first slice fixed the one that blocks a run.
- Resuming or retrying one saved assessment. Every ending is terminal, and a person starts a new one.

Release gates:

- The deployment-specific controller, processor, model, worker, region, transfer, notice, retention-enforcement, incident, and accountable privacy or legal evidence for a production managed run, owned by `specs/14-repository-execution-profile/`.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Admit a repository on a Mac at both assessability gates.
  - Size: Exception — five gates across four modules express one authorization rule. Changing any subset leaves a project admitted at one step and refused at the next, which is the defect itself rather than a smaller version of the fix.
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Stop the assessment refusing a project whose repository is reachable, so it can be scanned at all.
  - Owned surfaces: one owned assessability predicate in `RepositoryAssessments`, and every gate that expresses the same rule reading it: `authorize_project/2`, `RepositoryAssessmentLive`'s hosted context, `AssessmentStore.Hosted`'s `put/2` and `lock_project_binding/1`, and `ProfileStore.Hosted`'s `active_binding?/2` and `lock_project_binding/1`. All admit a hosted active project reachable through a connected GitHub connection or through its worker binding, and none becomes more permissive than the domain.
  - Owns: AC-01, AC-02, AC-06
  - Proof: Focused tests cover a hosted project whose repository is on a Mac starting an assessment, finishing it, and reaching a proposed profile; a GitHub project unchanged at every gate; a hosted project reachable by neither refused at every gate; and a person who does not own the project refused with nothing disclosed.
  - Delivered: `RepositoryAssessments.assessable_hosted_project?/1` is the one rule, and all five gates read it. A Mac project now assesses, finishes, proposes, and approves.

- [x] Task 2 — Name the repository, and name an unreachable Mac.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Make the screen say what it is about and why a start is not offered, instead of turning the person away.
  - Owned surfaces: `RepositoryAssessmentLive`'s repository label for a project whose repository is on a Mac, reusing the device route's existing wording, and its rendered state when the bound Mac is not reachable, which offers no start and changes nothing.
  - Owns: AC-03
  - Proof: Focused LiveView tests cover the screen naming such a repository with the device route's wording, rendering with no start and a stated reason when the bound Mac is not reachable, leaving the project unchanged in that state, and a GitHub project's label unchanged.
  - Delivered: both routes render one owned label for a repository on a Mac. The unreachable state needed no new code, because the screen's existing no-worker handling already produces it.

- [x] Task 3 — Prove the profile is approvable and the chain is clear.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Show the assessment actually produces something the owner can approve, which is the precondition that blocked a run.
  - Owned surfaces: The integration scenario from opening the assessment for a repository on a Mac through to an approved execution profile, which establishes `capability:mac-repository-assessment`.
  - Owns: AC-04, AC-05
  - Proof: An integration scenario assesses such a repository, completes it, and approves the execution profile from its proposal; and a GitHub project's assessment and profile approval are shown unchanged beside it.
  - Delivered: the journey runs through the screens, and the `execution_profile` start precondition is proven to flip from unmet to met, which is the thing the slice set out to unblock.
  - Corrected by `specs/47-live-repository-metadata-binding#Task 8`: AC-05 narrowed. The proof this task recorded that a GitHub project's assessment "completes and approves" ran against a test double and was never achievable against a real worker (no worker can match a GitHub numeric id to a local folder's identity). The screen, labeling, and no-redirect behavior this task actually delivered for a GitHub project stay unchanged and verified; only the completion claim was corrected.
  - Corrected by `Task 8` of this slice: the completion in this task's own scenario was produced by a seeded result, not by a worker. What it proved stays true, that a completed assessment yields an approvable profile. That a real scan produces one is `Task 8`'s and `Task 9`'s to prove.

- [ ] Task 4 — One closed shape for a scan command and its answer.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Fix what may cross to the Mac and back before anything is built on top of it, so no later task decides that for itself.
  - Owned surfaces: `SddOrchestrator.RepositoryScan.ScanRequest` and `SddOrchestrator.RepositoryScan.ScanAnswer` values, and `SddOrchestrator.RepositoryScan.AttachmentCodec` with its request, cancellation, and answer encodings.
  - Owns: AC-12
  - Proof: Focused tests cover a valid request and a valid answer round-tripping through the codec, a request missing any required field refused, an answer carrying an unknown field refused, an answer whose scan result or proposal payload is malformed refused, and no encoding admitting an absolute path, a remote URL, or file content.

- [ ] Task 5 — One scan, one outcome, one wait window.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Make every scan resolve exactly once, so a person waiting on one is never left waiting on a request nobody will answer.
  - Owned surfaces: `SddOrchestrator.RepositoryScan` with `run/2` and `answer/2`, `SddOrchestrator.RepositoryScan.Server` with its supervision entry, and the `SddOrchestrator.RepositoryScan.Transport` behaviour with its refusing `Unavailable` default.
  - Owns: AC-11
  - Proof: Focused tests cover one answer resolving a blocked call, a second answer for the same request refused as unknown, an answer from an attachment the request was not pushed to refused, the calling process dying resolving the request and cancelling it on the worker, the wait window closing as an unavailable worker, and the default transport refusing at once with nothing left open.

- [ ] Task 6 — Carry a scan over the Mac-scoped attachment.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Reach the one named Mac that holds the repository, over the attachment its metadata question already travels.
  - Owned surfaces: `SddOrchestrator.RepositoryScan.Transport.Attachment` with its declared capability, the `repository_scan`, `repository_scan_cancel`, and `repository_scan_result` frames on `SddOrchestratorWeb.WorkerWorkspaceChannel`, and the configuration selecting the real transport outside tests.
  - Owns: none
  - Proof: Focused tests cover a scan pushed to the named worker's attachment and not to another worker in the same workspace, no attachment refused as no worker, an attached worker that did not declare the capability refused as needing an update, a result frame handed to the request it names, and a result frame sent by a different attachment refused.

- [ ] Task 7 — The worker scans the folder it already holds.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Scan the repository the person already verified, without asking them for the folder a second time.
  - Owned surfaces: `SddOrchestrator.Worker.RepositoryScan` with its supervision entry, the held-folder lookup by `selection_ref` it reads from `SddOrchestrator.Worker.RepositoryMetadata`, the `repository_scan` and `repository_scan_cancel` handling in `SddOrchestrator.Worker.GatewayConnection`, and the `repository_scan` capability the release declares at attach. The held folder it reads is `specs/47-live-repository-metadata-binding#Task 8`'s, recorded here rather than as a capability edge because `specs/47` already requires this specification's `Task 3` and the graph must stay acyclic.
  - Owns: AC-09
  - Proof: Focused tests cover a scan of a held folder answering with the scanner's own result and proposal payload through the exact-commit cache, a `selection_ref` that is not held refused as expired with no panel opened, a held folder whose repository moved to another commit refused, a cancellation stopping an in-flight scan, and no absolute path, remote URL, or file content in any answer or log line.

- [ ] Task 8 — Take a pending assessment to a terminal one.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 6, Task 7
  - Purpose: Turn one worker answer into the stored assessment the profile screen reads, and make every other ending a stored failure instead of a row left pending.
  - Owned surfaces: `SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter` with its `Worker` and `Unavailable` implementations and its configuration, and the one `RepositoryAssessments` function that issues a pending assessment's command, revalidates the answer against that command, derives the authoritative envelope, and writes every ending through `finish_assessment/6`.
  - Owns: AC-10
  - Proof: Focused tests cover a completed answer stored with its derived envelope and cache provenance, an answer that does not match the command it was sent for refused and stored as failed, a refusal, a lost worker, and an unanswered window each stored as failed under their own reason, a cancelled scan stored as cancelled, a person who does not own the project refused with nothing stored, and a new assessment startable after a failed one.

- [ ] Task 9 — The screen assesses, and says what happened.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8
  - Purpose: Make pressing `Start assessment` actually assess, which is the click this specification exists for.
  - Owned surfaces: `SddOrchestratorWeb.RepositoryAssessmentLive`'s scan that its start now runs, its running state with the stop control, its completed state with the link to the execution profile, its failed and expired-binding states, and the replaced copy that says no scan command is sent. Completing it establishes `capability:live-repository-scan`.
  - Owns: AC-07, AC-08
  - Proof: Focused LiveView tests cover pressing start running the scan and rendering the running state with its stop control, a completed answer rendering the completed state and the profile link, the stop control ending the wait and leaving a state the person can start from, a failed answer rendering its reason, an expired binding offering to verify it again, and the device route unchanged.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] The first slice's criteria still pass: the screen opens, names the repository, states an unreachable Mac, and refuses a person who does not own the project.
- [ ] The existing repository-metadata question over the same attachment passes unchanged.
- [ ] The GitHub assessment's screen, labeling, and no-redirect behavior pass unchanged.
- [ ] The accountless device route passes unchanged.
- [ ] Nothing sent, stored, rendered, or logged by a scan carries an absolute or filesystem path, a remote URL, or file content.
- [ ] Build, formatting, lint, static checks, and logs review pass.
- [ ] Required browser scenarios pass.
- [ ] Product proof: one click path from `/` in a real browser, worker stand-in off, no `/_e2e` seeding, against the paired worker app: open a hosted project whose repository is on this Mac, verify the binding, press `Start assessment`, see the scan run and complete, then approve the execution profile it proposes. Recorded in `progress.md`.

## Blocked Decisions

- None.

## Release Gate

- The live worker-backed metadata adapter this specification's previous release gate waited on was delivered by `specs/47-live-repository-metadata-binding#Task 8`. What that gate still named, a scan against a real Mac, is this slice's own product proof rather than a release gate.
- What stays with `specs/14-repository-execution-profile/`: the deployment-specific controller, processor, model, worker, region, transfer, notice, retention-enforcement, incident, and accountable privacy or legal evidence a production managed run needs. This slice does not close that and does not claim to.

## Progress Log

See [progress.md](progress.md).
