# Read-Only Project Assistant Tasks

## Status

In Progress

The product and technical agreements are approved. `capability:project-storage-authority`, `capability:project-participation-boundary`, `capability:ai-runtime-session`, `capability:ai-runtime-observation`, `capability:project-specification-store`, `capability:guided-delivery-data-surfaces`, and `capability:project-participation-governance` are all ready. Tasks 1 through 8 are complete on `slice/12-project-assistant`, rebased onto `main` after `specs/29-participation-completion` merged. Task 9, the next executable task, is now unblocked.

## Active Slice

Deliver one private project-assistant conversation for each current participant and project, reachable from every project screen, that uses the participant's configured personal AI connection to answer bounded read-only questions from current authoritative project context and on-demand authorized current-working-tree observations, with exact citations, visible uncertainty, no permission expansion, and the approved privacy lifecycle.

## Cross-Specification Dependencies

Requires:

- `capability:project-storage-authority` — provider `specs/05-project-storage-lifecycle#Task 4` — required before `Task 1`.
- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 1`.
- `capability:ai-runtime-session` — provider `specs/11-ai-runtime-governance#Task 11` — required before `Task 2`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 3`.
- `capability:guided-delivery-data-surfaces` — provider `specs/07-guided-specification-delivery#Task 54` — required before `Task 3`.
- `capability:ai-runtime-observation` — provider `specs/11-ai-runtime-governance#Task 5` — required before `Task 2`.
- `capability:ai-runtime-governance` — provider `specs/11-ai-runtime-governance#Task 6` — required before `Task 9`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 9`.
- `capability:project-participation-governance` — provider `specs/29-participation-completion#Task 1` — required before `Task 9`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 9`.

Provides:

- `capability:read-only-project-assistant` — ready after `Task 10`.

## Task Size Gate

- Every task is `Standard`: each owns one independently provable assistant state transition, policy, adapter, projection, or user-facing workflow and is expected to produce one task-boundary implementation commit.
- No task uses an exception. Full repository, live-runtime, browser-matrix, privacy, security, and release checks remain at the slice verification or release gate rather than inflating focused task proof.

## Implementation Boundary

Included:

- One participant-private project conversation and ordered read-only turn lifecycle in the project's authoritative hosted or device store.
- Current-participant authorization for panel, conversation, turn, context, history, citation, and deletion access.
- Personal-AI availability, first-use and changed-boundary disclosure, confirmation, bounded session execution, normalized failure, and cancellation.
- Default current project, specification, board, recent-run, and accepted-evidence context through existing read boundaries.
- On-demand acting-participant-authorized repository observation of the current working tree.
- Branch, commit, dirty-state, scan-time, exclusion, and stability provenance.
- Worker-local source indexing and authoritative-boundary stored-project projection with no hosted source index or bulk source copy.
- Trusted versioned SDD Orchestrator skill injection and bounded read-tool brokering.
- Typed citations, uncertainty, redaction, private conversation presentation, immediate deletion, maximum retention, participation and project cleanup, and no analytics or training reuse.
- Desktop and mobile browser proof across representative project screens and degraded runtime or worker states.

Excluded:

- Every feature, specification, comment, assignment, readiness, board, run, review, repository, project-setting, participation, provider, worker, billing, quota, and credential mutation.
- Repository SDD adoption, repository-installed skills, arbitrary third-party skills or tools, shell execution, unrestricted network access, and autonomous background work.
- Shared conversations, notifications, assistant delegation, proactive monitoring, and an Orchestrator-funded model.
- A hosted repository source index, bulk source cache, unrestricted tool output, or stale source presented as current.

Deferred after this slice:

- A separate focused child specification for previewed and explicitly confirmed feature, specification, comment, assignment, and gated board actions.
- Optional shared or published assistant answers.
- Background monitoring, proactive summaries, multiple assistant agents, and cross-project questions.
- A separately approved hosted source-processing or indexing boundary if later evidence establishes that it is necessary.
- Additional repository observation tools beyond bounded state, tree, text-search, and line-read operations.

Release gates:

- Confirm the deployed controller identity, contact and notices; actual AI, worker, hosting, storage, backup, support, and deletion processors; regions and international transfers; data-processing agreements and transfer safeguards; provider retention and model-training settings; incident handling; enforced immediate and scheduled deletion; encrypted-backup expiry; final conversation-retention period no longer than 30 days; any required DPIA or legal review; and final accountable privacy and security approval.
- Prove one configured personal AI connection and one authorized repository worker against the production-equivalent processing disclosure without using an Orchestrator-funded fallback or exposing exact account quota.

Traceability:

- Deferred criteria: none.
- Release criteria: AC-24
- Deferred entities: none.
- Release entities: none.

## Tasks

- [x] Task 1 — Establish private conversation identity, persistence, and authorization.
  - Size: Standard
  - Depends on: none
  - Purpose: Create the durable private history boundary that every later turn uses without treating the conversation as shared project activity.
  - Owned surfaces: `ProjectAssistantConversation` and `ProjectAssistantTurn` hosted and device schemas or equivalent records, unique participant-project identity, ordered turn lifecycle, authoritative-storage adapter, current-participant guard, private-history query, participation-loss behavior, future confirmed-action sharing boundary, fixtures, and rollback.
  - Owns: AC-02, AC-03, AC-23, entity:ProjectAssistantConversation, entity:ProjectAssistantTurn
  - Proof: Run focused domain and adapter tests that create exactly one conversation per participant and project, preserve independent histories for two participants, reject stale and cross-project reads without existence disclosure, create no shared activity, and prove equivalent hosted and device behavior.

- [x] Task 2 — Integrate personal AI availability and processing-boundary confirmation.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Make one participant-funded runtime session an informed, explicit boundary without exposing credentials or silently selecting a fallback.
  - Owned surfaces: `capability:ai-runtime-session` and `capability:ai-runtime-observation` consumers, normalized personal-connection and shared-runtime availability, current-participant-safe available, constrained, paused and unknown runtime projection, safe setup routing, no-fallback enforcement, processing-summary version and digest, first-use confirmation, material-boundary invalidation, unchanged-boundary reuse, pre-tool gate, participant-visible minimum status, owner-exact quota exclusion, fixtures, and failure recovery.
  - Owns: AC-04, AC-05, AC-06, entity:AssistantBoundaryConfirmation
  - Proof: Run focused runtime-adapter and LiveView tests proving unavailable and temporarily limited states, no provider fallback, no tool or model call before matching confirmation, invalidation after each material boundary change, and automatic bounded reads after unchanged confirmation.

- [x] Task 3 — Assemble and project current stored project context.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Ground ordinary questions in minimum current authoritative project data before any source observation is considered.
  - Owned surfaces: `capability:project-specification-store` current-snapshot consumer, `capability:guided-delivery-data-surfaces` read-only board, recent-run and accepted-evidence consumer, project metadata reader, context minimizer, destination-local `ProjectContextProjection`, projection refresh and deletion, hosted and device isolation, exact context-version references, fixtures, and negative source-copy assertions.
  - Owns: AC-07, AC-17, entity:ProjectContextProjection
  - Proof: Run focused hosted and device tests that assemble only current metadata, specification heads, board state, and needed recent run or evidence state; reject every delivery mutation; rebuild the projection idempotently; and find no repository path, source, source index, prior revision, raw log, or unrelated activity in the projection.

- [x] Task 4 — Observe the authorized participant's current working tree safely.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Add exact source provenance without converting project participation into repository authority or treating the last commit as the whole current project.
  - Owned surfaces: Acting-participant source authorization, worker and repository target binding, read-only repository-observation adapter, `RepositoryObservation`, branch, commit, dirty state, before-and-after state digests, scan timestamps, exclusions, current-working-tree fixtures with uncommitted changes, concurrent-change detection, worker-offline and source-denied outcomes, credential non-substitution, and normalized minimum observation return.
  - Owns: AC-08, AC-09, AC-16, entity:RepositoryObservation
  - Proof: Run focused worker-contract tests against clean, dirty, unborn-branch, concurrently changing, unauthorized, cross-project, offline, and credential-substitution fixtures, proving exact provenance and an unstable result whenever relevant state changes during observation.

- [x] Task 5 — Deliver bounded progressive source discovery and worker-local indexing.
  - Size: Standard
  - Depends on: Task 4
  - Purpose: Make empty and large repositories answerable without full upload, stale lookup, or a hosted derived-source copy.
  - Owned surfaces: Bounded repository state, tree, text-search and line-read operations, progressive discovery planner inputs, configured path and file exclusions, byte and result limits, `RepositorySourceIndex`, worker-local storage, project and source-authority scoping, working-tree-state key, invalidation and refresh, empty-repository result, large-repository fixtures, hosted-store and backup negative scans.
  - Owns: AC-13, AC-18, entity:RepositorySourceIndex
  - Proof: Run focused observation tests for empty, non-SDD, generated-heavy, secret-bearing, and large repositories; prove bounded calls and truncation; invalidate after source change; deny cross-project and unauthorized reuse; and verify no raw source or derived index reaches hosted persistence, caches, logs, or backups.

- [x] Task 6 — Enforce the trusted read-tool and skill-bundle runtime contract.
  - Size: Standard
  - Depends on: Task 2, Task 3, Task 5
  - Purpose: Keep runtime autonomy inside an external, inspectable capability boundary even when project content contains hostile instructions.
  - Owned surfaces: Read-tool manifest, trusted skill-bundle identity, version and integrity check, compatibility negotiation, tool-call, elapsed-time, context-byte, result-byte and model-usage budgets, turn cancellation, untrusted-content classification, prompt-injection denial, repository-skill rejection, arbitrary tool and network denial, normalized limit outcomes, fixtures, and security audit.
  - Owns: AC-14, AC-15
  - Proof: Run focused policy tests with hostile repository instructions, specifications, comments, source and run output that request secrets, writes, shell, network, new tools, more budget, or policy override; prove the manifest cannot widen, only the pinned skill version runs, and every limit or cancellation ends without mutation.

- [x] Task 7 — Produce grounded answers, exact citations, and explicit uncertainty.
  - Size: Standard
  - Depends on: Task 6
  - Purpose: Turn bounded current context into a reviewable answer rather than an unsupported model claim.
  - Owned surfaces: Stored-only and source-backed turn orchestration, worker-offline stored-only continuation, no stale-source-current rule, `ProjectAssistantCitation`, specification, repository, board, run and evidence citation codecs, authorization-checked citation resolution, exact line and Git provenance, claim-to-source validation, partial, stale, excluded, conflicting, unavailable and unstable markers, minimal excerpt policy, fixtures, and answer failure recovery.
  - Owns: AC-10, AC-11, AC-12, entity:ProjectAssistantCitation
  - Proof: Run focused tests for each citation type and uncertainty state, then prove a worker-offline answer contains only current stored project facts, a changed tree cannot yield a stable citation, inaccessible citations fail closed, and an uncited or fabricated material claim is rejected.

- [x] Task 8 — Deliver the assistant panel and private conversation experience.
  - Size: Standard
  - Depends on: Task 2, Task 7
  - Purpose: Make the approved assistant workflow reachable and understandable from every project screen without hiding degraded states or exposing account details.
  - Owned surfaces: Shared project-layout panel mount, desktop and mobile panel, one private history view, ask, pending, stream or complete, cancel, citation-open, unavailable, setup-needed, temporarily-limited, source-unavailable, unstable, failed, retry-question and delete presentation, keyboard and focus behavior, safe status copy, exact-quota and provider-diagnostic non-disclosure, navigation preservation, fixtures, and accessibility checks.
  - Owns: AC-01, AC-22
  - Proof: Run focused LiveView tests and the project-assistant browser scenarios from project overview, board, feature, run, and evidence screens on desktop and mobile, proving one preserved private conversation, keyboard and focus behavior, readable citations and uncertainty, every degraded state, no mutation control, no exact quota, and no other participant history.

- [x] Task 9 — Enforce redaction, retention, deletion, rights, and prohibited-use controls.
  - Size: Standard
  - Depends on: Task 7
  - Purpose: Apply the complete project-wide privacy and security lifecycle to assistant content, source-derived results, indexes, processors, logs, and backups.
  - Owned surfaces: `AssistantProcessingRecord`, field-purpose and access inventory, secret-path denial, credential, personal-data and source-minimization filters, model-input, answer, citation, persistence and log redaction, no analytics or training reuse, maximum 30-day inactivity retention, immediate participant deletion, participation-loss cleanup, project deletion, processor deletion request and reconciliation, rights handling, backup expiry integration, content-free security outcomes, fixtures, and local privacy and security review.
  - Owns: AC-19, AC-20, AC-21, entity:AssistantProcessingRecord
  - Proof: Run focused lifecycle, rights, redaction and negative-content tests across hosted and device stores, runtime payloads, worker results, projections, source indexes, logs, caches, exports, processor queues and backups; prove immediate authoritative deletion, scheduled expiry, no restoration of access, and no prompt, answer, citation, path, source, secret, raw provider event, hidden reasoning, stable analytics identifier, or exact quota in prohibited destinations.

- [ ] Task 10 — Verify the complete read-only project-assistant slice.
  - Size: Standard
  - Depends on: Task 8, Task 9
  - Purpose: Re-run the approved contract as one integrated workflow and publish the assistant capability only when local, live-runtime, browser, privacy, and security proof agrees.
  - Owned surfaces: `capability:read-only-project-assistant` provider and readiness write-back; end-to-end integration of already owned panel, authorization, disclosure, personal runtime, stored context, source observation, trusted skills, bounded tools, citations, uncertainty, private history, deletion and degraded states; full desktop and mobile browser matrix; live configured runtime and worker smoke evidence; and release-gate separation.
  - Owns: none
  - Proof: Run the complete verification gate below, record every real exit status and live-smoke artifact, confirm no forward dependency or unowned active criterion or entity remains, and record `capability:read-only-project-assistant` ready only after all implementation and required-verification proof passes.

## Verification Gate

- [ ] `python3 .agents/scripts/validate_spec.py specs/12-project-assistant` passes.
- [ ] `python3 .agents/scripts/validate_spec.py --all specs` passes with one provider for every required capability and no cycle or provider-consumer conflict.
- [ ] `mix format --check-formatted` passes.
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix credo --strict` passes.
- [ ] `mix dialyzer` passes.
- [ ] `mix deps.audit` passes.
- [ ] `mix sobelow --config` passes.
- [ ] `mix test` passes, including hosted and device conversation, authorization, runtime, projection, observation, tool-policy, grounding, citation, privacy, lifecycle, concurrency, idempotency, failure, and negative-content coverage.
- [ ] `mix check` passes.
- [ ] `npm --prefix assets ci` passes.
- [ ] `npm --prefix assets run test:e2e` passes the authenticated desktop and mobile project-assistant matrix from project overview, board, feature, run, and evidence screens, including keyboard, focus, viewport, accessibility, private-history isolation, exact citations, uncertainty, no mutation controls, runtime unavailable, worker offline, source denied, dirty tree, unstable scan, cancellation, limit, deletion, and removed-participant cases.
- [ ] `MIX_ENV=prod mix assets.deploy` passes.
- [ ] `MIX_ENV=prod mix release` passes.
- [ ] A live configured personal AI connection answers one stored-project question through `capability:ai-runtime-session` with the disclosed provider, no fallback, exact stored citations, and no exact quota disclosure.
- [ ] A live authorized repository worker answers one dirty-working-tree question through `capability:ai-runtime-observation` with branch, commit, dirty state, scan time, exact path and line, and a separate concurrent-change run that reports unstable.
- [ ] Hosted persistence, device persistence, logs, caches, indexes, backups, browser payloads, runtime payloads, and worker exchange contain no unauthorized project data, cross-participant conversation, hosted source index, bulk source copy, secret, credential, raw provider event, hidden reasoning, product analytics, training reuse, or exact account-wide quota.
- [ ] Immediate deletion, rolling retention, participation loss, project deletion, rights handling, processor cleanup, and backup expiry preserve no accessible assistant history or source index beyond the approved lifecycle.
- [ ] Requirements AC-01 through AC-23 pass; AC-24 remains visible as a release criterion until the deployment-specific review is approved.
- [ ] Task proofs, task-boundary commits, capability readiness, failed or environment-blocked evidence, and any accepted decision are written back without weakening a check.

## Blocked Decisions

- None. Tasks 1 through 9 are complete; Task 10's slice verification gate is the only remaining task.

## Progress Log

See [progress.md](progress.md).
