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

Invoke or activate the matching project skill through the current tool's skill system at the start of every workflow. Do not merely read its `SKILL.md` as reference material and imitate the steps in an ad hoc process.

The active skill must execute the canonical `SKILL.md` under `.agents/skills/`. Codex and Claude Code must execute the same canonical instructions.

When one request combines a new or changed specification with implementation, complete the applicable spec workflow and stop. Begin `implement-spec` only after the specification is reviewed and its active slice is approved.

Spec-only work must stop after the specification and directly requested project guidance are updated. Do not continue into code, migrations, tests, dependencies, or runtime configuration.

## Decision Ownership And Specification Depth

- Ask users for decisions they own: observable behavior, workflow, scope, business rules, ownership, data handling, risk acceptance, and acceptance outcomes.
- Do not ask users to choose implementation mechanisms, algorithms, normalization rules, storage representations, library choices, or exhaustive technical edge cases when the alternatives preserve the accepted product behavior.
- Ask about a technical alternative only when it materially changes a user-visible outcome or requires explicit product, security, privacy, cost, or operational risk acceptance.
- Consolidate unresolved engineering mechanisms in design open questions or task blockers. Do not turn them into serial product-discovery questions.
- Use representative acceptance criteria. Do not duplicate a full technical test matrix across requirements, design, and tasks.
- Stop refining a specification when the product agreement is sufficient for a useful `Draft` and the remaining decisions are clearly owned by technical design.

## Specification Question Batches

- Before asking, search the current requirements, design, tasks, and recorded project decisions. Do not ask for a decision that is already recorded.
- Group related, independent user-owned questions that share one workflow context and readiness stage into a small batch, usually two to five questions.
- Ask one question by itself only when its answer changes the next questions, it is a foundational product fork, or a previous answer needs clarification.
- Always provide one recommended answer and a brief reason for every question. When no product option can be responsibly preferred, recommend the next action, such as deferring the decision, gathering evidence, or asking the accountable owner.
- Format each batch so the user can answer every question individually or accept all recommendations together.
- Do not mix product-discovery and technical-design questions in one batch.
- After the user answers, apply the complete batch through one `update-spec` write-back and one validation pass before asking another batch or ending the session.

## Product-First SDD Sequence

- Complete product requirements before asking technical-design or implementation questions or asking the user to make implementation decisions.
- During product discovery, ask only about observable behavior, workflow, scope, business rules, ownership, data handling, risk acceptance, privacy expectations, and acceptance outcomes.
- Do not ask about frameworks, libraries, architecture, protocols, data models, storage mechanisms, algorithms, deployment, test commands, or other implementation details while product requirements remain unresolved.
- Record unresolved engineering questions in `design.md` or technical task blockers without presenting them to the user as missing product requirements.
- Do not describe a feature as unspecified merely because its technical design is pending. Report product-requirement completeness, technical-design readiness, and implementation-slice status separately.
- When product requirements are complete, state that clearly and explicitly transition to technical design.
- During technical design, make engineering-owned decisions from the approved requirements, project constraints, official documentation, and existing repository patterns. Ask the user only when a choice changes observable behavior or requires explicit product, security, privacy, cost, or operational risk acceptance.
- Do not begin implementation until the technical design and active slice are approved under the applicable SDD workflow.

## Readiness And Blocker Scope

- Report product-requirement readiness, technical-design readiness, implementation state, verification state, and release readiness separately.
- Every unresolved decision must name the earliest stage it blocks. A later-stage unknown must not make an earlier ready stage appear blocked.
- Requirements may be `Approved` while technical design, implementation, verification, or release work remains. `Approved` means the product agreement is stable enough to proceed, not that the feature is implemented or releasable.
- Mark `tasks.md` as `Blocked` only when an unresolved decision prevents the active slice from starting, continuing, or completing its required verification.
- Keep deployment-dependent evidence in an explicit release gate. It must block deployment and release claims without blocking implementation or local verification when the stable implementation contract is already approved.
- Distinguish an environment or tooling blocker from an implementation blocker. When a required external dependency, service, runtime, or credential is unavailable, such as a stopped database engine, a missing daemon, or absent network access, pause only the proofs that need it, continue independent work, surface the blocker to the user with options, and record it in `tasks.md` as environment-blocked. Do not fake, skip, or silently weaken the affected proof, and do not treat the unavailability as an implementation defect.
- A canonical check may flag work that a later task in the same slice owns. Defer that single finding with a narrowly scoped, documented suppression and a recorded follow-up owned by the naming task, rather than suppressing the whole check or leaving the finding hidden. This is distinct from an accepted exception for marking a slice `Verified`.

## Delivery Coverage

- Inventory every UI, API, domain, persistence, integration, security or privacy, and operational surface named by the active-slice requirements and design.
- Map every surface to one primary implementation task through that task's `Owned surfaces` field. Report and resolve any unmapped or ambiguously owned surface before implementation.
- Prefer vertical workflow tasks that own user-visible UI and its supporting logic together when one scenario can implement and prove them coherently.
- Treat browser checks and other tests as proof of an owned surface, not as ownership of its implementation. A page named only in proof remains unmapped.
- Use a final end-to-end task to integrate and verify surfaces already owned by earlier tasks. It must not silently become the sole owner of otherwise unassigned pages, APIs, or supporting behavior.

## Implementation Workflow

1. Confirm that requirements and design contain no blocking open questions.
2. Confirm that every required delivery surface has one unambiguous owning task.
3. Work only from the active slice in `tasks.md`.
4. Keep changes inside its implementation boundary.
5. Implement one task at a time.
6. Run the proof attached to each task before marking it complete.
7. Run the full verification gate before calling the slice complete.
8. Write progress and new decisions back to the spec files as the state changes.

## Stop Conditions

Stop implementation and report the issue when:

- The requested change expands the approved scope.
- A missing product, business, or design decision affects implementation.
- The code, acceptance criteria, and existing system disagree.
- A required check fails and cannot be fixed inside the approved slice.
- Continuing would require changing an acceptance criterion to fit the code.
- A required delivery surface has no clear owning task.
- Another task, Codex session, or Claude Code session owns the same files or responsibility.

Do not continue by silently choosing a new product or architecture decision.

## Write-Back Rules

- During discussion of an existing specification, any answer or agreement that needs to persist must be written through `update-spec`; do not edit the specification through an ad hoc workflow.
- Immediately after the user answers a question or related question batch about an existing specification, activate or continue `update-spec` and write all accepted answers into every affected specification file before asking the next batch or ending the session.
- Accepted decisions, resolved questions, newly exposed blockers, status changes, and progress must not live only in the conversation.
- A new conversation should recover specification state from the repository and need only the user's next intent. Do not compensate for missing write-back with a handoff mega-prompt.
- Update `requirements.md` when expected behavior, scope, or a business rule changes.
- Update `design.md` when a technical decision or tradeoff changes.
- Update `tasks.md` when progress, verification state, blocked decisions, or deferred work changes.
- Record a resolved, non-behavioral engineering mechanism, such as a local port choice or a build-step ordering fix, in the `tasks.md` progress log, or in `design.md` when it changes a documented decision. Do not ask the user to choose it and do not leave it only in the conversation.

Keep decisions in project files, not only in the conversation.

## File And Commit Rules

- Do not create Markdown files unless the user explicitly asks for them or an invoked SDD workflow requires its defined spec files.
- Keep changes narrowly scoped to the active task.
- Inspect the working tree before staging. Another agent or the user may hold concurrent uncommitted or newly committed changes; treat them as intentional and do not stage, revert, or reformat them.
- When the user asks for a commit, stage only the active task's own paths by explicit path list and create the local commit with one shell command. Never stage with `git add -A`, `git add .`, or a broad glob, and confirm the staged set contains only your files before committing.
- Always use a conventional semantic prefix such as `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, or `chore:` in commit messages and titles.
- Do not add assistant, model, or tool authorship to commits or titles.
- Commit only when the user asks.

## Current Project Checks

The repository has the Slice 01 Phoenix toolchain. Run the checks applicable to the change.

For instruction and skill changes, run the checks that currently apply:

- Shared instructions: `cmp -s AGENTS.md CLAUDE.md`
- Claude skill links: `find -L .claude/skills -type l` must return no broken links.
- Patch integrity: `git diff --check`
- Skills: validate every changed canonical skill under `.agents/skills/` with the validator provided by the active skill-authoring environment.
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
