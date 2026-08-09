# Empty Repository Initialization

## Status

Approved

## Outcome

A technical or non-technical user can describe a new project's purpose and technical foundation, review the exact proposed structure and checks, and explicitly authorize a working agent to create one valid local Git repository with a verified skeleton, first commit, and permanent SDD kit by default, while retaining managed runtime SDD if the kit is declined.

## Users

- Founders, product owners, business analysts, and project managers starting a repository without needing terminal commands.
- Developers reviewing or supplying technical foundation, command, and verification decisions.
- Security and platform reviewers evaluating the initialization plan, agent boundary, package provenance, and resulting repository.

## In Scope

- One user-selected empty local directory, including an empty unborn Git repository with no root commit.
- A non-mutating support conversation that establishes project purpose and the minimum technical foundation.
- A proposed initialization plan with exact repository structure, project files, commands, required checks, Git behavior, and permanent-kit contents.
- Separate assistant, specification, agent-execution, and release readiness.
- First or changed-boundary processing disclosure and explicit confirmation.
- A working agent, distinct from the support conversation, operating only after confirmation in an isolated worker staging area.
- Git initialization, minimal project skeleton, reliable check contract, optional default permanent kit, required proof, and one first commit.
- Handoff to normal local repository onboarding and creation of the first authoritative complete SDD specification revision.

## Out of Scope

- Initializing a non-empty directory, replacing an existing repository, importing existing source, or merging generated files.
- Empty GitHub repository mutation, remote creation, remote push, or hosting-provider setup in the first executable slice.
- Product implementation beyond the explicitly confirmed minimal skeleton.
- Production deployment, infrastructure provisioning, secrets, billing, or provider credential setup.
- Support-chat file mutation, direct default-branch work before the repository exists, or autonomous architecture selection.
- Multiple application roots, monorepos, multiple services, or organization-wide repository templates.
- A repository-owned authoritative project specification or bidirectional synchronization.

## Primary Workflow

1. A user selects `Start with an empty repository` and chooses one empty local directory through the operating system boundary.
2. A support conversation explains that it cannot change files and asks focused product questions about purpose, users, first outcome, and constraints.
3. After product intent is sufficient, the conversation gathers only the technical foundation decisions required to create a valid skeleton and reliable checks.
4. The product shows the proposed directory structure, files, commands, required checks, Git initialization and first-commit behavior, runtime boundary, and permanent SDD kit files.
5. The permanent kit is included in the proposal by default. The user may decline it before confirmation and sees that managed runtime SDD remains available while agents launched outside Orchestrator will not automatically receive the repository workflow.
6. The product shows the first or changed processing boundary, then the user explicitly confirms the exact plan.
7. A separately authorized working agent builds the plan in an isolated worker staging area, validates the skeleton and required checks, and prepares the first commit.
8. If the target remains empty and the staged proof passes, the worker publishes the initialized repository into the selected directory and records the exact first commit. Otherwise it stops without replacing unexpected user data or claiming success.
9. The user reviews the resulting structure and proof, then continues through normal local onboarding.
10. After project creation, the approved initialization agreement is recorded as one authoritative complete `requirements.md`, `design.md`, and `tasks.md` revision through the shared specification store.

## Business Rules

- The first executable slice accepts only one local directory that is empty under the approved operating-system selection rules. An unborn Git repository is eligible; a repository with any commit routes to mature-repository assessment.
- Local onboarding cannot identify an unborn repository through its current portable repository identity because that identity requires root commits; initialization must establish the first commit before normal onboarding.
- The support conversation is read-only. It may create or revise the governed initialization plan through the governed pre-project support boundary, but it cannot call repository mutation tools, initialize Git, create files, install a kit, or launch the working agent.
- Product purpose, intended users, first outcome, constraints, chosen technical foundation, commands, and verification expectations are user-approved decisions. The assistant must not silently select consequential architecture.
- The plan must show every top-level directory, generated file category, configured command, required check, Git action, initial branch behavior, kit file, included script, and required permission before confirmation.
- The first plan must be the smallest runnable and verifiable foundation for the approved purpose. It must not implement unrelated product features.
- The permanent SDD kit from `capability:sdd-kit-package` is proposed by default only after its exact package identity and files are visible. The user can remove it from the plan without losing managed runtime SDD.
- If the kit is declined, the product must explain that independently launched repository agents will not automatically receive Orchestrator's managed skills, profile, or authoritative project specifications.
- Initialization requires one explicit confirmation bound to the plan version, target directory identity, staging boundary, technical foundation, commands, checks, kit choice, agent and model provider, transfer boundary, and package digest when included.
- A changed plan, target, provider, transfer boundary, kit version, or permission invalidates prior confirmation.
- Only the separately authorized working agent may perform initialization, and only after confirmation. The agent receives the exact plan and minimum filesystem, Git, package, and command capabilities required for that plan.
- Initialization work occurs in a normalized worker-owned staging root. The agent cannot read or write outside the staging area and cannot inspect unrelated user directories.
- Package and template material are treated as inert vendored inputs. Remote code, repository hooks, and unreviewed scripts do not execute during initialization.
- Before publish, the worker confirms that the selected target is still eligible and unchanged. Unexpected content, symlinks, path changes, permission changes, or a newly created commit stop publication.
- The staged repository must contain the confirmed minimal skeleton, reliable required-check contract, Git metadata, and the confirmed permanent kit choice.
- Every configured required check must pass in the staged repository before publication and against the exact commit recorded as initialized.
- A failed or canceled run remains visible with its stage and evidence, creates no successful initialization result, does not delete unexpected user data, and cannot claim assistant, agent-execution, or release readiness beyond the evidence obtained.
- Successful publication creates exactly one initial repository state and first commit. Retrying the same committed operation returns the recorded result rather than creating another root commit.
- Normal local onboarding, repository identity, project registration, and storage choice remain owned by their existing specifications and occur only after the root commit exists.
- After onboarding, the first project specification is created through `capability:project-specification-store` as one complete immutable document-set revision. The repository kit contains no project-specific specification copy.
- Assistant, specification, agent-execution, and release readiness are shown separately. A created skeleton may be agent-execution ready while release remains blocked by deployment choices.
- Source scanning and staging indexes remain worker-local. No whole-repository upload occurs; any configured model receives only content allowed by the confirmed processing boundary.
- Initialization plans, runs, results, prompts, outputs, proof, and authoritative specifications are confidential project or pre-project data, retained only for the active initialization and resulting project purposes, access-controlled, rights-capable, and prohibited from analytics, advertising, model training, or unrelated reuse.

## Acceptance Criteria

- [AC-01] Given an empty local directory or unborn local Git repository, when eligibility is checked, then initialization may continue; given any existing commit or non-approved content, then the workflow stops or routes to mature-repository assessment without mutation.
- [AC-02] Given the user talks with initialization support, when the conversation runs, then it can revise the governed plan but cannot invoke a repository mutation tool or working agent.
- [AC-03] Given product or technical foundation information is consequential or missing, when the plan is prepared, then focused questions remain visible and no architecture is silently selected.
- [AC-04] Given the plan is ready for review, when it is shown, then structure, files, commands, checks, Git behavior, kit package and files, scripts, permissions, agent, provider, and transfer boundary are explicit.
- [AC-05] Given the processing boundary is first used or changed, when confirmation is requested, then local, transferred, processor, purpose, and retention behavior is disclosed before authorization.
- [AC-06] Given the user declines the permanent kit, when the plan is confirmed, then managed runtime SDD remains available and the limitation for independently launched repository agents is explained.
- [AC-07] Given any confirmed input changes, when initialization is requested, then prior confirmation is invalid and the changed exact plan must be reviewed again.
- [AC-08] Given the exact plan is confirmed, when work starts, then only the separately authorized working agent receives the minimum plan-bound capabilities inside an isolated staging area.
- [AC-09] Given the target becomes non-empty, changes identity, gains a commit, contains an unexpected symlink, or leaves its permission boundary, when publication is evaluated, then publication stops without replacing the target or claiming success.
- [AC-10] Given staging completes, when contents are inspected, then the repository contains only the confirmed minimal skeleton, command and check contract, Git setup, and selected permanent kit files.
- [AC-11] Given every required check passes, when the initialized result commits, then one first commit identifies the exact checked tree and retry returns that result without another root commit.
- [AC-12] Given staging, checking, committing, or publication fails or is canceled, when the run ends, then failure stage and evidence remain visible, no successful result exists, and unexpected user data is not deleted.
- [AC-13] Given initialization succeeds, when normal local onboarding and project creation finish, then the repository has its portable identity and the initialization agreement is stored once as a complete authoritative three-document specification revision without a repository copy.
- [AC-14] Given initialization status is shown, when readiness is evaluated, then assistant, specification, agent-execution, and release readiness remain separate with their earliest blockers.
- [AC-15] Given plans, sessions, staging data, source indexes, prompts, outputs, proof, logs, caches, processors, or resulting records are inspected, when governance proof runs, then worker locality, minimization, access, retention, deletion, rights, redaction, and no-secondary-use rules are enforced.

## Open Questions

- None.
