# Project Instructions

## Project Purpose

This repository develops SDD Orchestrator, a dashboard and control plane for moving specifications through AI-assisted implementation with local or remote coding agents.

It is also the first real project built with those workflows. Keep the result useful as a maintained personal project. Do not change product or engineering decisions only to produce a cleaner article or demonstration.

Read `README.md` for the project identity, current direction, and unresolved product questions. Treat it as project context, not as an approved implementation specification.

## Shared Codex And Claude Contract

Codex and Claude Code work in the same repository and follow the same engineering rules.

- Keep `AGENTS.md` and `CLAUDE.md` identical. Update both in the same change.
- Inspect the working tree before editing. Treat existing uncommitted changes as intentional work from the user or another tool. Do not revert, overwrite, or reformat changes outside the active task.
- Stop when another active task owns the same files or responsibility.

Canonical project skills live under `.agents/skills/` in the shared Agent Skills `SKILL.md` format. Codex reads them directly; Claude Code reads them through links under `.claude/skills/` and must be version `2.1.203` or newer. Do not keep a second copy of a skill for one tool.

The long-form contracts these rules summarize live in `.agents/reference/sdd-gates.md`. The SDD skills read the section they need. Do not paste it back into this file.

## Communication Style

Write every message to the user short and straight to the point.

- Use simple English. Prefer short common words over precise rare ones.
- Keep each point to one sentence. Split a long sentence instead of joining clauses with commas, dashes, or semicolons.
- This applies to every message, including plans, `AskUserQuestion` questions, option labels, and option descriptions.
- Lead with the answer. Do not restate the question or narrate the steps taken to reach it.
- Prefer a few lines over paragraphs, and paths with line numbers over quoted file contents.
- Cut preamble, summaries of work already visible, and offers of unrequested next steps.
- Let length follow the question: a status question gets a status answer, not a report.
- Detail belongs in the specification files, `progress.md`, and the code, not in chat.

## Product Copy

Copy the user reads inside the product follows the same plain-English rules as messages to the user, plus these.

- Do not use em dashes. Use a period, a comma, a colon, or parentheses. An em dash in product copy reads as machine-written, and the user has rejected it on sight.
- Prefer two short sentences to one sentence joined by punctuation.
- Do not assert what the product cannot know. State what the control plane actually knows, and offer the rest as a branch the reader picks. A browser cannot see whether a native app is installed, so copy may not claim it is missing.
- One instruction has one wording. When two surfaces say the same thing, they render one owned value instead of holding two copies that drift.

## Source Of Truth

`README.md` describes what the project is. Approved behavior and implementation decisions belong in feature specifications under `specs/<feature>/`:

- `requirements.md` defines expected behavior and product boundaries.
- `design.md` defines technical decisions and tradeoffs.
- `tasks.md` defines the active implementation slice and verification state. Its `## Progress Log` body is only the pointer line `See [progress.md](progress.md).`
- `progress.md` holds the progress-log entries as `### ...` sections, newest first. They are compliance evidence: proof receipts, failed checks, status transitions, and environment incidents. Read the last relevant entries, not the whole log.

Do not replace an explicit project decision with an assumption.

## Privacy And Data Protection

GDPR compliance is a project-wide requirement for every schema, backend path, integration, log, export, retention and deletion process, worker, and agent data flow.

- Apply data protection by design and by default, purpose limitation, data minimization, storage limitation, least privilege, appropriate security, and auditable lifecycle enforcement from the specification onward.
- Before adding or changing personal-data storage or processing, use the applicable SDD workflow to record purpose, lawful basis, necessity, access boundary, retention, deletion, data-subject-rights behavior, processors, transfers, and required privacy review.
- Analytics are aggregate and genuinely anonymous. Pseudonymised, hashed, encrypted, or otherwise linkable data is personal data, not analytics.
- Include derived records, soft-deleted data, logs, caches, indexes, backups, exports, local workers, coding agents, model providers, and other subprocessors in privacy and retention analysis.
- Tests and technical controls are compliance evidence, not legal compliance. Keep a stage blocked only when its required privacy or legal decisions are unresolved. Put deployment-specific controller details, vendors, regions, transfer safeguards, notices, and final reviews in an explicit release gate when they are not needed to implement or locally verify the approved contract.

Primary references: the official [GDPR text](https://eur-lex.europa.eu/eli/reg/2016/679/oj) and the [EDPB anonymisation guidance](https://www.edpb.europa.eu/topics/ai-and-technology/anonymisation-pseudonymisation_en).

## Product Proof

Tests prove the domain. A person clicking proves the product. A slice needs both.

- A slice whose outcome is something a person does is `Verified` only after one click path from `/` in a real browser, with the worker stand-in off and no `/_e2e` seeding, reaches that outcome. Record the path and the screens in `progress.md` at the slice gate.
- A task that delivers a user action names the screen and the control that triggers it. A domain function with no web-layer caller does not complete a user-facing acceptance criterion.
- The dev server runs with `:device_worker_stub` off. `E2E_MODE=true` turns it on for the browser suite only.
- Prefer one working vertical path over a wider set of verified domain modules. Widen after a person can click through.

## SDD Workflows

The SDD skills are mandatory. Pick the skill from the user's intent even when the user does not name it:

- `add-spec` to define, scope, plan, or create a new specification, feature, or implementation slice.
- `update-spec` to change existing requirements, scope, business rules, design decisions, implementation boundaries, acceptance criteria, or verification expectations.
- `implement-spec` to implement, continue, or verify one approved active slice.
- `review-spec` to review, audit, or second-check a slice another agent delivered. It re-runs proofs and reports; it edits neither code nor specification.

Invoke the skill through the current tool's skill system and execute its canonical `SKILL.md` under `.agents/skills/`. Each skill owns its decision, question-batching, coverage, workflow, stop-condition, and write-back rules, and reads the gate contracts it needs from `.agents/reference/sdd-gates.md`.

- When one request combines a specification change with implementation, complete the spec workflow and stop. Begin `implement-spec` only after the slice is approved. Spec-only work does not touch code, migrations, tests, dependencies, or runtime configuration.
- When the user asks to implement or complete work, carry every requested task through in one pass. Commit at each task boundary. Stop only for a genuine blocker: a decision that is the user's, an unresolved specification decision, a hard environment or tooling failure, an unrecoverable error, or the context handoff below.
- Every new `tasks.md` carries `## Cross-Specification Dependencies`, `## Slice Size Gate`, `## Task Size Gate`, and `## Proof Scope Gate` in that order after `## Active Slice`. Limits: at most 12 tasks, a longest `Depends on:` path of 8, one provable outcome per task, and focused task proof through `python3 .agents/scripts/run_proof.py task --task <n> -- <command>`. Repository-wide gates run once, at the slice, through `run_proof.py slice`. Never re-run a suite to find which test failed; read the first output.

## Agent Execution Mode

- Delegate task development to a sub-agent by default. The main thread keeps preflight, gate validation, reconciliation, proof confirmation, specification write-back, and the commit. A brief carries the exact files, the decided design, the hard constraints, and one task; the sub-agent does not re-run the preflight or re-derive the agreement, and it stops and reports when the brief is wrong.
- A sub-agent's report that a check passed is a claim. The main thread confirms each proof by real exit status, once.
- Run sub-agents in parallel only when `Depends on:` and disjoint ownership of files, surfaces, and proof allow it. Name the owned paths in every brief.
- When the main thread passes roughly half its context, finish the task in flight through proof, write-back, and commit, then stop and hand off with a prompt that names the branch, the active specification, the next task, and the files to recover state from. If the user said the run is long or automatic, continue instead.

## Readiness And Write-Back

- Report requirement, design, implementation, verification, and release readiness separately, and name the earliest stage each unresolved item blocks. `Approved` is not implemented; `Verified` is not releasable.
- An unavailable service, daemon, credential, or network is an environment blocker, not a defect: pause only the affected proofs, continue independent work, tell the user, and record it in `tasks.md`. Never fake, skip, or weaken a proof.
- Persist decisions, blockers, status changes, and progress into the specification files through the matching skill, never an ad hoc edit. A `Delivered:` line in `tasks.md` is at most two sentences; mechanism and receipts go in `progress.md`.

## File And Commit Rules

- Do not create Markdown files unless the user asks or an invoked SDD workflow requires its defined spec files.
- Keep changes scoped to the active task. Inspect the working tree before staging; other changes are intentional.
- Stage only the active task's own paths by explicit list and commit with one shell command. Never `git add -A`, `git add .`, or a broad glob.
- Use a conventional prefix (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`). No assistant, model, or tool authorship in commits or titles.
- Commit at each task boundary once its proof passes and its `tasks.md` write-back is recorded. One task per commit.
- One branch per slice, `slice/<feature-directory>`, from an up-to-date default branch; continue an existing slice branch after rebasing, never create a second. Merge it when the slice passes its gate. Parallel agent sessions get their own worktree, branch, and server port. Details in `.agents/reference/sdd-gates.md`.

## Current Project Checks

Run the checks that apply to the change.

- Toolchain and database: `mise install`, `docker compose up -d postgres`, `mix setup`; local server `mix phx.server`.
- Standard developer gate: `mix check`.
- Explicit code-quality gate: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, `mix test`.
- Browser proof: `npm --prefix assets ci`, `npm --prefix assets run test:e2e`. Production proof: `MIX_ENV=prod mix assets.deploy`, `MIX_ENV=prod mix release`.
- Instructions and skills: `cmp -s AGENTS.md CLAUDE.md`; `find -L .claude/skills -type l` returns nothing; `git diff --check`; validate changed skills with the active skill-authoring validator.
- Specifications: `python3 .agents/scripts/validate_spec.py specs/<feature>`, `python3 .agents/scripts/validate_spec.py --all specs`, `python3 .agents/scripts/split_progress_log.py --check`; script suites `python3 .agents/scripts/test_validate_spec.py` and `python3 .agents/scripts/test_run_proof.py`.
- Repository tooling (`slice_status.py`, `capability_index.py`, `run_proof.py` partitions, `prime_worktree.sh`, `drop_test_databases.sh`) is described in `.agents/reference/sdd-gates.md` under Repository Tooling.

Do not mark a slice `Verified` while a required check is failing or unavailable without an explicit accepted exception.
