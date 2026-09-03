# SDD Gate Contracts

The full text of the planning, proof, execution, and commit contracts that `CLAUDE.md` / `AGENTS.md` summarize. The SDD skills read the section they need when they plan, implement, or review a slice. Nothing here overrides the short rules in `CLAUDE.md`; it spells them out.

## Cross-Specification Capability Dependencies

Slice numbers are stable identifiers, not execution order. Express implementation order through task-level capabilities instead of relying on numbering or broad whole-slice dependencies.

- Every new or changed `tasks.md` must include `## Cross-Specification Dependencies` after `## Active Slice`, with `Requires:` and `Provides:` lists.
- Use the exact requirement form ``- `capability:<name>` — provider `specs/<feature>#Task <n>` — required before `Task <n>`.`` Use `- None.` when there is no requirement.
- Use the exact provider form ``- `capability:<name>` — ready after `Task <n>`.`` Use `- None.` when the slice provides no downstream capability.
- Name one primary provider task for each capability. A consumer may not redefine the provider's schema, interface, authoritative data, or lifecycle.
- Depend on the smallest stable capability, not an entire slice, when the consumer needs only one provider contract.
- A provided capability becomes available only after its named task is checked complete, its full proof passes, and the readiness write-back is recorded. Release-only evidence does not delay an implementation capability unless the consumer crosses that release boundary.
- Keep the earliest affected consumer task `Blocked` while its required capability is unavailable. Keep the slice `Blocked` only when its next executable task is blocked; a later unavailable capability must not prevent independent earlier tasks. Before changing status, confirm the provider paths needed at that stage.
- Run the repository's global cross-specification dependency validator when available. It must reject missing or ambiguous providers, malformed references, cycles, unavailable prerequisites for active consumers, and provider/consumer contract conflicts.
- When a capability edge changes, update both provider and consumer specifications in the same specification change and re-run their individual validators plus the global graph check.
- Treat a capability's provider task moving to a different specification, such as during an umbrella-to-child split, as a scope change, not a reference repair. In that same change, re-justify every existing consumer's edge against that consumer's own `requirements.md` or `design.md`, and repoint it to the smallest still-accurate capability instead of mechanically following the provider to its new specification. Keeping the reference valid does not by itself prove the consumer still needs what the capability now means.

## Slice Size Gate

Adopt the slice-size contract for every new task plan. Do not retrofit an active legacy slice solely to satisfy the numeric limits; when its unfinished work is next materially refined, preserve completed history and move independently executable remaining outcomes into new child specifications that adopt the gate.

- Every new `tasks.md` must include `## Slice Size Gate` after `## Cross-Specification Dependencies` and before `## Task Size Gate`.
- Declare exactly `- Slice size: Standard` or `- Slice size: Exception — <why no smaller slice can deliver a coherent independently verifiable capability without duplicating authority or creating an invalid lifecycle boundary>.`
- A standard slice delivers one primary product or platform outcome through one coherent end-to-end workflow and one verification gate, contains at most 12 tasks total, and has a longest `Depends on:` path of at most 8 tasks.
- Treat 12 total tasks and an 8-task critical path as hard planning limits, not targets. Split earlier when workflows, integrations, trust boundaries, data lifecycles, owners, failure paths, or proof modalities can be implemented and verified independently.
- Do not evade the slice limit by combining work that fails the Task Size Gate. Every resulting task must still deliver one independently provable outcome.
- Use a slice-size exception only when every smaller boundary would duplicate one authoritative contract or create a concrete invalid lifecycle or verification state. Complexity, convenience, chronology, a shared release milestone, or a desire for one pull request is not an exception.
- Express sequencing between smaller slices with capability dependencies. Keep shared rules and release coordination in an umbrella specification only when its executable work lives in focused child specifications.

## Task Size Gate

Adopt the task-size contract when Slice 06 or any later slice is next refined. Do not rewrite completed Slice 05 tasks solely to migrate them.

- Every new `tasks.md` must include `## Task Size Gate` after `## Slice Size Gate` and before `## Implementation Boundary`. Preserve the established position in a legacy plan that has not adopted the Slice Size Gate.
- Give every task exactly one size declaration: `Size: Standard` or `Size: Exception — <why splitting creates an invalid intermediate state>.`
- A standard task delivers one independently provable outcome, owns one primary state transition or invariant and normally one adapter or workflow, produces one task-boundary implementation commit, owns at most three acceptance criteria and two entities, and has focused proof expected to run in about ten minutes.
- Use 30–45 minutes as a planning target, not a promise. Expected work beyond 60 minutes or more than one meaningful implementation commit is a split signal.
- Split tasks that combine independently testable behaviors, multiple adapter integrations, domain foundation plus UI plus authentication or recovery, source-owned integration from another specification, or proof modalities that can fail independently.
- Keep the full repository, production, security, and browser-matrix gates at slice verification. Task proof should be focused and include only directly applicable safety checks unless the task owns a broader gate.
- Allow an exception only when splitting an atomic migration, transaction, or invariant would create a concrete invalid intermediate state. Complexity, convenience, chronology, or test duration is not an exception.
- Preserve completed task labels and history. When splitting unfinished work, update affected task dependencies and cross-specification capability references together and re-run the individual and global validators.

## Task Proof Gate

Adopt the task-proof contract when an active slice's next unfinished task is refined after the proof runner is available. Do not rewrite completed task history solely to migrate it.

- Every newly created `tasks.md`, and every existing `tasks.md` that adopts the contract prospectively, must include `## Proof Scope Gate` after `## Task Size Gate` and before `## Implementation Boundary`.
- Declare applicability as exactly `- Applies to: all tasks.` for a new task plan or as a comma-separated list of stable task labels for prospective adoption, such as `- Applies to: Task 36, Task 37.` Unknown or duplicate task labels are invalid.
- Give every applicable task exactly one declaration: `Proof scope: Focused` or `Proof scope: Broad — <why this task owns a broader gate>.` A broad declaration is an exception and requires a concrete ownership reason.
- Run each focused task-proof command through `python3 .agents/scripts/run_proof.py task --task <n> -- <command>`. For a validator-approved broad task exception, add `--broad` before `--`. The runner must reject unscoped full tests, full browser matrices, dependency installation, production proof, and repository-wide security or quality gates in focused task scope.
- Paste every successful runner receipt into the task's entry in `specs/<feature>/progress.md`. An applicable task may not be checked complete, committed, or provide a capability until the specification validator accepts a matching focused or approved broad receipt.
- The main thread must confirm the same scoped proof by real exit status. Reconciliation does not authorize an additional full-suite run.
- Run complete repository, browser, security, production, and release commands only through `python3 .agents/scripts/run_proof.py slice -- <command>` at the slice verification gate. Do not use slice scope as a routine task-proof override.
- Run the full test suite, `mix check`, the browser matrix, and every other repository-wide gate once, when the slice is done. A task runs its own scoped tests and nothing else, however tempting broader confidence feels.
- Reconciling a sub-agent's work does not authorize repeating a broad check it already ran. Confirm that task's scoped proof by real exit status and move on.
- Never re-run a suite to discover which test failed. Capture full output the first time and read it.
- Record a known flaky test as gate evidence instead of re-running until it passes. Re-run only the single file, and only to establish that the failure is the flake.
- If focused proof exposes evidence of a cross-task regression, record the evidence and run the narrowest additional command that can confirm it. Escalate to the slice gate only when the broader gate itself is the affected behavior or a documented stop condition requires it.

## Product Proof Gate

Tests prove the domain. A person clicking proves the product. Both are required; neither replaces the other.

- Every slice whose outcome is something a person does must list, in its Verification Gate, one click path that starts at `/` in a real browser, with the worker stand-in off and no `/_e2e` seeding, and reaches the outcome. When the slice touches the worker, the path runs against the paired worker app. Record the path and the screens seen in `progress.md` at the slice gate. A slice is not `Verified` until that entry exists.
- A task that delivers a user action names the screen and the control that triggers it in its `Owned surfaces`. A public domain function with no web-layer caller does not complete a user-facing acceptance criterion, whatever its tests say.
- The dev server runs with `:device_worker_stub` off. `E2E_MODE=true` turns it on for the browser suite only. A flow that only works with the stand-in is a flow that does not work.
- A browser scenario that seeds state through `/_e2e/session` proves the screens it asserts, not the path a person takes to reach them. Name it as such in the gate.
- Green suites are not evidence that a person can do the thing, and the failure is systematic rather than unlucky. Three consecutive slices in one run each passed every domain, integration, and browser check while the path a person takes was broken at a different point: creation finished and returned the person to the entry page, the next screen redirected with no reason given, and the step after that was refused outright. Each suite passed because it supplied the very thing missing in reality, whether a session, a seeded project, or a stubbed adapter. Treat a fully green gate as the moment to run the click path, not as a reason to skip it.
- A test double is a contract boundary, so name what it leaves unproven. A suite that injects an adapter, a transport, or a session proves the code around that seam and nothing about the seam itself. When a slice ships a double on purpose, its gate says which real implementation is still missing and which specification owns it; otherwise the absence is invisible until someone clicks, and the slice that finds it is rarely the slice that owns it.

## Agent Execution Mode

- Delegate task development to a sub-agent by default and keep the main thread on orchestration, review, proof, committing, and specification write-back. A brief carries the exact files to read, the decided design, and the hard constraints instead of asking the sub-agent to rediscover them.
- A dispatched sub-agent works from its closed brief. It does not invoke an SDD workflow skill, repeat the specification preflight, or re-read the specification files to rediscover an agreement the brief already carries. The main thread owns the preflight, the gate validation, the capability confirmation, the reconciliation, the proof confirmation, the specification write-back, and the commit. A sub-agent that finds its brief wrong, incomplete, or contradicted by the code stops and reports instead of re-deriving the agreement itself.
- A brief covers one task, budgets about 45 minutes, and asks for a short report: files changed, the exact proof command, and its output. The main thread re-runs the proof; the report is a claim.
- Run sub-agents in parallel whenever their tasks are genuinely independent. Independence follows from each task's `Depends on:` line together with disjoint ownership of files, surfaces, and proof. Assign explicit path ownership in every brief, and serialize instead when two tasks would touch the same module, migration, or screen.
- Reconcile every sub-agent result in one place. Confirm each proof by real exit status; a sub-agent's report that a check passed is a claim, not evidence.
- Manage the main thread's context deliberately. When it passes roughly half its window, finish the task in flight through its proof, write-back, and commit, then stop. Do not start another task in a degraded context, and do not abandon one midway to save room.
- Hand off by pointing at the repository, never by carrying state. Ask the user to clear the context, then supply the exact prompt for the next session: the branch, the active specification, the next executable task, which tasks to avoid and why, and the instruction to recover state from `specs/<feature>/tasks.md` and the last relevant entries of `specs/<feature>/progress.md`.
- Exception: when the user says the session is a long or automatic run, do not stop at the context threshold; continue through the task chain.

## Readiness And Write-Back

Report product-requirement, technical-design, implementation, verification, and release readiness separately, and name the earliest stage each unresolved item blocks; a later-stage unknown must not make an earlier ready stage look blocked. `Approved` requirements are not thereby implemented or releasable.

- Keep deployment-dependent evidence in a release gate. It blocks release, not implementation or local verification, when the implementation contract is already approved.
- Distinguish an environment or tooling blocker, such as an unavailable service, daemon, credential, or network, from an implementation defect: pause only the affected proofs, continue independent work, surface it to the user, and record it in `tasks.md` as environment-blocked. Do not fake, skip, or weaken a proof. A canonical check that flags a later task's work may be deferred with a narrow, documented suppression and a recorded follow-up owned by that task.
- Persist accepted decisions, resolved questions, new blockers, status changes, and progress into the specification files through the matching SDD skill, never an ad hoc edit. A new conversation must recover state from the repository, not a handoff prompt.
- Record a resolved, non-behavioral engineering mechanism in `specs/<feature>/progress.md`, or in `design.md` when it changes a documented decision. Do not leave it only in the conversation.
- In `tasks.md`, a task's `Delivered:` line is at most two sentences naming what now exists and where. Mechanism, discoveries, and receipts go in `progress.md`.

## Branch And Worktree Rules

- Branch implementation per slice, not per task. Use one branch per active slice named `slice/<feature-directory>`, such as `slice/02-local-project-onboarding`, and open at most one pull request per slice.
- Before starting or resuming a slice, fetch and check whether its slice branch already exists locally or on the remote. If it exists, continue on it after rebasing or fast-forwarding onto the latest default branch and never create a second branch for the same slice; only create the branch, from an up-to-date default branch, when none exists.
- Let task commits accumulate on the slice branch under the scoped, explicit-path, task-boundary rules, and merge the slice branch into the default branch when the slice passes its verification gate.
- Coordinate multiple agents or developers within one slice at task granularity through `tasks.md` ownership and the stop condition; use a short-lived per-task branch off the slice branch only for genuine parallel work inside the same slice, then merge it back into the slice branch.
- When the user says this work will run in parallel with other AI agents, give each agent its own Git worktree and assigned branch, and run each concurrent local server on a distinct port. Never share one working directory or runtime port across parallel agents. Sub-agents that one main thread dispatches, reconciles, and commits share its working tree and are separated by disjoint path ownership instead.
- Before running agents on more than one slice in parallel, analyze the surfaces those slices actually share, judged by what each slice will modify rather than by filenames, then choose and record a sequencing decision (serialize, partition by ownership, or foundation-first) in the affected slices' `tasks.md` before implementation starts.

## Repository Tooling

- `.agents/scripts/slice_status.py` is a read-only cross-slice task and readiness report over `main` plus matching active slice worktrees. It defaults to Slice 07 through the latest slice with Slice 11 expanded, and accepts `--from <slice>` and `--focus <slice>`. It does not replace the specification validators.
- `python3 .agents/scripts/capability_index.py` answers cross-specification capability questions. `--capability <name>` reports one capability's provider task, readiness, and consumers. Its readiness reads the provider task's checkbox only; `validate_spec.py` remains the authority. Open a provider `tasks.md` only when the index reports a problem or the consuming work would touch the provider's own contract.
- `python3 .agents/scripts/split_progress_log.py [<spec> ...]` keeps the progress log out of `tasks.md`. `--check` reports without writing and exits nonzero when any file would change. It is idempotent: a slice branch that still carries the legacy inline shape resolves that rebase conflict in favor of the branch version and re-runs the tool. Existing entries are matched by their exact `### ` heading and are never duplicated, reordered, or rewritten.
- `python3 .agents/scripts/run_proof.py` derives one stable `MIX_TEST_PARTITION` from the worktree root and injects it into the child environment, so each worktree gets its own test database. Do not hand-write the partition in a proof command; a caller-supplied value still wins. `mix check` does not get the partition injected; pass it explicitly at the slice gate.
- Prime every newly created slice worktree with `.agents/scripts/prime_worktree.sh <target-worktree-path>` before its first build. It clones `_build`, `deps`, `priv/plts`, and `assets/node_modules` from the main worktree. It is idempotent and refuses to run against the main worktree.
- `.agents/scripts/drop_test_databases.sh` lists the leftover `sdd_orchestrator_test*` and `sdd_orchestrator_e2e_*` databases in the Postgres container and drops them with `--yes`. Run it when the container fills with partition databases.
