# Project Instructions

## Project Purpose

This repository develops SDD Orchestrator, a dashboard and control plane for moving specifications through AI-assisted implementation with local or remote coding agents.

It is also the first real project built with those workflows. Keep the result useful as a maintained personal project. Do not change product or engineering decisions only to produce a cleaner article or demonstration.

Read `README.md` for the project identity, current direction, and unresolved product questions. Treat it as project context, not as an approved implementation specification.

## Shared Codex And Claude Contract

Codex and Claude Code work in the same repository and follow the same engineering rules.

- Keep `AGENTS.md` and `CLAUDE.md` identical.
- Update both files in the same change when a shared rule changes.
- Inspect the working tree before editing.
- Treat existing uncommitted changes as intentional work from the user or another tool.
- Do not revert, overwrite, or reformat changes outside the active task.
- Stop when another active task owns the same files or responsibility.

Canonical project skills live under `.agents/skills/` and follow the shared Agent Skills `SKILL.md` format.

- Codex discovers the canonical skill folders directly.
- Claude Code discovers the same folders through links under `.claude/skills/`.
- Do not maintain a second copy of a skill for one tool.
- Claude Code must be version `2.1.203` or newer because the project uses linked skill folders.

## Source Of Truth

`README.md` describes what the project is. Approved behavior and implementation decisions belong in feature specifications.

Before implementation, read the relevant files under `specs/<feature>/`:

- `requirements.md` defines expected behavior and product boundaries.
- `design.md` defines technical decisions and tradeoffs.
- `tasks.md` defines the active implementation slice and verification state.

Do not replace an explicit project decision with an assumption.

## Privacy And Data Protection

GDPR compliance is a project-wide requirement for every database schema, backend path, integration, log, export, retention process, deletion process, worker, and agent data flow.

- Apply data protection by design and by default, purpose limitation, data minimization, storage limitation, least privilege, appropriate security, and auditable lifecycle enforcement from the specification onward.
- Before adding or changing personal-data storage or processing, use the applicable SDD workflow to record its purpose, lawful basis, necessity, access boundary, retention, deletion, data-subject-rights behavior, processors, transfers, and required privacy review.
- Analytics must always be aggregate and genuinely anonymous. Do not retain user, device, workspace, project, repository, network, content, or stable pseudonymous identifiers in analytics.
- Treat pseudonymised, hashed, encrypted, or otherwise linkable data as personal data, not anonymous analytics.
- Include derived records, soft-deleted data, logs, caches, indexes, backups, exports, local workers, coding agents, model providers, and other subprocessors in privacy and retention analysis.
- Automated tests and technical controls provide compliance evidence but do not establish legal compliance by themselves. Keep a stage blocked only when its required privacy or legal decisions are unresolved. Put deployment-specific controller details, vendors, regions, transfer safeguards, notices, and final reviews in an explicit release gate when they are not needed to implement or locally verify the approved contract.

Use the official [GDPR text](https://eur-lex.europa.eu/eli/reg/2016/679/oj) and [European Data Protection Board anonymisation guidance](https://www.edpb.europa.eu/topics/ai-and-technology/anonymisation-pseudonymisation_en) as primary references.

## SDD Workflows

The SDD skills are mandatory. Select the matching skill from the user's intent even when the user does not name the skill explicitly:

- Always use `add-spec` when defining, scoping, planning, or creating a new specification, feature, or implementation slice.
- Always use `update-spec` when changing existing requirements, scope, business rules, design decisions, implementation boundaries, acceptance criteria, or verification expectations.
- Always use `implement-spec` when implementing, continuing, or verifying one approved active slice.
- Always use `review-spec` when reviewing, auditing, or second-checking the implementation of a slice another agent delivered, including checking for missed behavior, scope drift, privacy or security gaps, or needed refactoring. It re-runs the task proofs and verification gate, reports findings, and routes fixes to `implement-spec` or agreement changes to `update-spec` without editing the code or the specification itself.

Invoke or activate the matching project skill through the current tool's skill system at the start of every workflow, and execute its canonical `SKILL.md` under `.agents/skills/` rather than reading it as reference and imitating the steps. Codex and Claude Code execute the same canonical instructions. Each skill carries its own decision-ownership, question-batching, product-before-technology, delivery-coverage, workflow, stop-condition, and write-back rules; follow the active skill for that detail.

When one request combines a new or changed specification with implementation, complete the applicable spec workflow and stop. Begin `implement-spec` only after the specification is reviewed and its active slice is approved. Spec-only work must stop after the specification and directly requested project guidance are updated; do not continue into code, migrations, tests, dependencies, or runtime configuration.

## Readiness And Write-Back

Report product-requirement, technical-design, implementation, verification, and release readiness separately, and name the earliest stage each unresolved item blocks; a later-stage unknown must not make an earlier ready stage look blocked. `Approved` requirements are not thereby implemented or releasable.

- Keep deployment-dependent evidence in a release gate. It blocks release, not implementation or local verification, when the implementation contract is already approved.
- Distinguish an environment or tooling blocker, such as an unavailable service, daemon, credential, or network, from an implementation defect: pause only the affected proofs, continue independent work, surface it to the user, and record it in `tasks.md` as environment-blocked. Do not fake, skip, or weaken a proof. A canonical check that flags a later task's work may be deferred with a narrow, documented suppression and a recorded follow-up owned by that task.
- Persist accepted decisions, resolved questions, new blockers, status changes, and progress into the specification files through the matching SDD skill, never an ad hoc edit. A new conversation must recover state from the repository, not a handoff prompt.
- Record a resolved, non-behavioral engineering mechanism in the `tasks.md` progress log, or in `design.md` when it changes a documented decision. Do not leave it only in the conversation.

## File And Commit Rules

- Do not create Markdown files unless the user explicitly asks for them or an invoked SDD workflow requires its defined spec files.
- Keep changes narrowly scoped to the active task.
- Inspect the working tree before staging. Another agent or the user may hold concurrent uncommitted or newly committed changes; treat them as intentional and do not stage, revert, or reformat them.
- When committing, stage only the active task's own paths by explicit path list and create the local commit with one shell command. Never stage with `git add -A`, `git add .`, or a broad glob, and confirm the staged set contains only your files before committing.
- Always use a conventional semantic prefix such as `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, or `chore:` in commit messages and titles.
- Do not add assistant, model, or tool authorship to commits or titles.
- Commit at each task boundary. Once a task's proof passes and its `tasks.md` write-back is recorded, create one local commit scoped to that task; also commit whenever the user explicitly asks. Do not batch multiple completed tasks into a single commit.
- Branch implementation per slice, not per task. Use one branch per active slice named `slice/<feature-directory>`, such as `slice/02-local-project-onboarding`, and open at most one pull request per slice.
- Before starting or resuming a slice, fetch and check whether its slice branch already exists locally or on the remote. If it exists, continue on it after rebasing or fast-forwarding onto the latest default branch and never create a second branch for the same slice; only create the branch, from an up-to-date default branch, when none exists.
- Let task commits accumulate on the slice branch under the scoped, explicit-path, task-boundary rules above, and merge the slice branch into the default branch when the slice passes its verification gate.
- Coordinate multiple agents or developers within one slice at task granularity through `tasks.md` ownership and the stop condition; use a short-lived per-task branch off the slice branch only for genuine parallel work inside the same slice, then merge it back into the slice branch.

## Current Project Checks

The repository has the Slice 01 Phoenix toolchain. Run the checks applicable to the change.

For instruction and skill changes, run the checks that currently apply:

- Shared instructions: `cmp -s AGENTS.md CLAUDE.md`
- Claude skill links: `find -L .claude/skills -type l` must return no broken links.
- Patch integrity: `git diff --check`
- Skills: validate every changed canonical skill under `.agents/skills/` with the validator provided by the active skill-authoring environment.
- Spec validator: `python3 .agents/scripts/test_validate_spec.py`
- Specifications: `python3 .agents/scripts/validate_spec.py specs/<feature>`

Slice 01 is the first approved executable slice. Its application-bootstrap task must establish these canonical commands:

- Toolchain and database: `mise install` and `docker compose up -d postgres`
- Initial setup: `mix setup`
- Local server: `mix phx.server`
- Standard developer gate: `mix check`
- Explicit code-quality gate: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test`
- Browser setup and proof: `npm --prefix assets ci` and `npm --prefix assets run test:e2e`
- Production proof: `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release`

The bootstrap implementation must add `mix check` as the standard formatting, compilation, lint, and test alias. Until the application skeleton exists, missing application commands are work owned by that bootstrap task, not verification exceptions.

Do not mark a slice `Verified` while a required established check is failing or unavailable without an explicit accepted exception.
