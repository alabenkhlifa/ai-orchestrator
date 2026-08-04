---
name: implement-spec
description: Implement and verify one approved Spec-Driven Development slice from requirements.md, design.md, and tasks.md. Use when a user asks to build an approved feature slice, continue its active tasks, or complete its verification gate while preserving scope, stop conditions, progress logs, and specification write-back.
---

# Implement Spec

Implement only the active approved slice and preserve the agreement around it.

## Preconditions

Confirm that expected behavior, design decisions, implementation boundary, cross-specification capabilities, slice size, task size, task ownership, traceability, execution order, proof, and project checks are clear. Stop and use `update-spec` when an adopted standard slice exceeds its task-count or critical-path limit, a slice exception is unjustified, a required capability is missing, ambiguous, cyclic, unavailable, or redefined by the consumer; when a new or refined task is oversized or has an unjustified size exception; when a decision blocks active implementation or required verification; when a required delivery surface is unmapped or ambiguously owned; when an active acceptance criterion or data entity lacks task ownership; or when a task needs a surface first delivered by a later task. A later deployment or release gate is not an implementation stop condition unless the requested work would cross that gate.

## Workflow

1. Read the applicable `AGENTS.md` and all three feature specification files. Take the active task's recent history from the last relevant entry in `specs/<feature>/progress.md`; do not read the whole log.
2. Run the mechanical gates before reading any gate section. Run `python3 .agents/scripts/validate_spec.py specs/<feature>` and the global dependency validator `python3 .agents/scripts/validate_spec.py --all specs`. Together they enforce the required headings, cross-file agreement, and the active-slice ownership contract, the `## Slice Size Gate` declaration with its 12-task and 8-task critical-path limits and its exception wording, every `Size:` declaration with its acceptance-criterion and entity limits and exception wording, the `## Proof Scope Gate` applicability with every `Proof scope:` declaration and its required proof receipt, every `Depends on:` reference, the traceability contract of exactly one `Owns:` line per task with exactly one owning task per active `[AC-<n>]` criterion, at least one owning task per active data entity, and a deferred or release classification for every criterion and entity outside the active slice, and the cross-specification capability graph. Do not begin implementation while any of these fail.
3. Read a gate section only when a check names it, and confirm what the reported failure means for the active slice before routing the disagreement to `update-spec`. The validators skip a gate a plan never adopted, so an absent `## Slice Size Gate`, `## Task Size Gate`, or `## Proof Scope Gate` in a new or newly refined plan is a routing signal rather than a pass. Do not retrofit a legacy active slice solely to add a gate it never adopted.
4. Confirm every capability the active task requires with `python3 .agents/scripts/capability_index.py --capability <name>`, which reports the provider task, its readiness, and its consumers without opening the provider's specification. Treat a `ready` line as a pointer derived from the provider task's checkbox, not as gate approval; the validator run in step 2 remains the authority for the capability contract. Open the provider's `tasks.md` only when the index reports `missing`, `ambiguous`, `unresolved`, or `pending` for a capability the active task needs, or when the active task would touch the provider's own schema, interface, authoritative data, or lifecycle. Stop for a missing or ambiguous provider, malformed edge, cycle, incomplete provider task or proof, or consumer-owned duplicate of the provider contract.
5. Identify the active task. Read its `Depends on:` line when present and confirm every named task is complete. For a legacy task without the declaration, reconstruct its prerequisites and use `update-spec` when the ordering is not explicit enough to trust.
6. Preflight delivery coverage, which no validator derives from requirement and design prose: inventory every UI, API, domain, persistence, integration, security or privacy, and operational surface named by the active-slice requirements and design, then confirm that each has one primary task through `Owned surfaces`.
7. Preflight execution order before broad code exploration: inspect the active task's purpose, owned surfaces, traceability items, and proof; identify every schema, interface, route, service, fixture, earlier task output, and external capability it needs; then confirm each prerequisite exists in the baseline, an available named capability, the same task, or an earlier completed task. Step 2 validates the declared dependency graph; this semantic simulation is not mechanical and is not covered by it.
8. Judge the declarations whose form step 2 checks but whose truth it cannot. Accept a recorded `Slice size: Exception` only when it names an indivisible authority, lifecycle, or verification boundary, never complexity, convenience, chronology, a shared release milestone, or a desire for one pull request. Confirm a `Size: Standard` active task really delivers one independently provable outcome, one primary state transition or invariant, and normally one adapter or workflow and one task-boundary implementation commit; accept a size exception only for the recorded invalid intermediate state that splitting an atomic migration, transaction, or invariant would create. Confirm whether the `## Proof Scope Gate` `Applies to:` declaration covers the active task, and accept `Proof scope: Broad` only when its recorded reason shows the task owns that broader gate. Route an untrue or unjustified declaration to `update-spec`.
9. Confirm that unresolved items name the stage they block. Keep explicit deferred and deployment-only coverage visible without treating it as active implementation work.
10. Stop and use `update-spec` if the active task combines independently testable behaviors, multiple separable adapter integrations, mixed domain foundation plus UI plus authentication or recovery, source-owned integration from another specification, independently failing proof modalities, or work expected to need more than one meaningful implementation commit; if any required capability, surface, or active traceability item is missing, unavailable, unmapped, ambiguously owned, or cyclic; or if the active task has a forward dependency. Do not ask the user to choose an implementation mechanism and then continue coding. Complete the specification update and stop; resume implementation only in a later request after the repository contract records the decision. A browser check or other proof does not imply ownership of its implementation.
11. Inspect relevant existing code and confirm ownership boundaries. Keep this exploration scoped to the active task now that the agreement is ready.
12. Preflight environment readiness: confirm the external dependencies, services, runtimes, and credentials the task proofs require are available. When one is unavailable, treat it as an environment blocker, not an implementation defect: pause only the affected proofs, continue independent work, surface it to the user, and record it in `tasks.md` as environment-blocked.
13. Mark the active task `In Progress`.
14. Implement one task at a time. When the proof-scope contract is active, run every focused proof command through `python3 .agents/scripts/run_proof.py task --task <n> -- <command>`; add `--broad` before `--` only for a validator-approved broad task declaration. Paste each successful receipt into the task's entry in `specs/<feature>/progress.md`. Otherwise run focused proof plus directly applicable safety checks. In both cases, confirm real exit status and never treat piped or truncated output as proof. The main thread verifies the same scoped proof; reconciliation does not authorize a full-suite rerun.
15. Do not run unscoped full tests, the full browser matrix, dependency installation, production proof, or repository-wide security and quality gates during a focused task. Use a documented `Broad` proof scope only when the task itself owns that gate. Keep all other broad checks at slice verification.
16. Write progress, failures, discoveries, proof receipts, capability readiness, and deferred work into `specs/<feature>/progress.md` as newest-first `### ...` entries, and write the resulting status changes into `tasks.md`. `## Progress Log` in `tasks.md` holds nothing but the pointer line `See [progress.md](progress.md).`
17. Stop and use `update-spec` when implementation reveals more than one independently useful commit or behavior, or when behavior, design, scope, slice size, task size, proof scope, capability ownership, traceability, execution order, or blocker classification must change.
18. Run every complete verification-gate command through `python3 .agents/scripts/run_proof.py slice -- <command>` and preserve its successful receipt.
19. Mark the slice `Verified` only when every required check passes, and report release readiness separately.

## Stop Conditions

Stop when work expands beyond the approved boundary, an adopted slice fails the Slice Size Gate or its exception is unjustified, the active task fails the Task Size Gate or its exception does not preserve an atomic invariant, a required capability is missing, unavailable, ambiguous, cyclic, or redefined, a missing decision affects behavior or architecture required by the active slice, a required delivery surface lacks one clear owning task, the active task depends on a surface first delivered later, implementation conflicts with the specification, a required check fails outside the slice, or ownership overlaps another task or agent.

Do not stop implementation only because a recorded deployment or release gate remains incomplete. Do stop before deploying, releasing, or claiming release readiness while that gate remains incomplete.

An unavailable environment dependency, such as a stopped service, missing daemon, or absent credential, is an environment blocker, not an implementation defect. Pause the affected proofs, continue independent work, surface it to the user, and record it as environment-blocked. Verify evidence by real exit status and re-run ambiguous results; do not record a masked or piped exit code as a pass.

Delegate task development to sub-agents by default, and run them in parallel when work separates cleanly by ownership, files, and proof. Reconcile all results and run final verification in one place. A dispatched sub-agent works from its closed brief and does not repeat this preflight; the main thread keeps steps 1 through 12, the reconciliation, the proof confirmation, the specification write-back, and the commit.

## Boundaries

- Do not implement unapproved scope.
- Do not change acceptance criteria to fit code.
- Do not treat proof as ownership of implementation.
- Do not continue implementation after discovering that task order or an engineering mechanism must change the specification.
- Do not hide failing checks or unresolved decisions.
- Do not record a proof as passing without a verified real exit status, and do not stage another agent's concurrent changes.
- Do not bypass the proof runner when the specification has adopted `## Proof Scope Gate`, and do not use slice scope to evade a focused-task restriction.
- Do not mark work complete without its proof.
- Do not describe verified implementation as deployable or releasable unless its release gates also pass.

## Completion

Finish when approved behavior works, required checks pass, the specification files reflect the final implementation state, and any remaining release gate is reported explicitly.
