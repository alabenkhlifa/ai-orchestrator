# Repository SDD Kit Integration

## Status

Approved

## Outcome

After a managed SDD pilot, a project owner can optionally review and apply an exact, provenance-backed permanent SDD kit change on an isolated repository branch, or decline it and continue using managed runtime SDD without repository mutation.

## Users

- Project owners deciding whether permanent SDD workflow files belong in their repository.
- Developers and security reviewers inspecting the exact package, scripts, permissions, conflicts, and repository diff.
- Organization maintainers applying repository contribution and software-supply-chain policy.

## In Scope

- An optional permanent-kit offer after the selected managed pilot reaches `Ready for review` or `Done`.
- One vendored, inspectable, versioned kit package with immutable provenance and digest.
- Exact file manifest, license, scripts, required agent and tool permissions, and compatibility information.
- A commit-bound, conflict-aware change plan and exact diff.
- Isolated branch application after explicit owner confirmation.
- Existing repository instruction, CI, template, and convention preservation.
- Explicit kit update and removal plans with reviewed diffs.
- Managed runtime continuation when the kit is declined or unavailable.
- The project specification store remaining the sole authoritative source of project specifications.

## Out of Scope

- Initial repository assessment and execution-profile approval, defined in `specs/14-repository-execution-profile/`.
- Empty-repository foundation creation, defined in `specs/16-empty-repository-initialization/`.
- Automatic issue or backlog import, project-specific specification export, bidirectional synchronization, or a repository-owned copy of Orchestrator specifications.
- Silent, background, or mandatory installation or update.
- Direct default-branch writes, automatic merge, production deployment, or bypass of repository review rules.
- Executing remote code, remote scripts, repository hooks, or unreviewed package content during planning or installation.
- Rewriting existing `AGENTS.md`, `CLAUDE.md`, CI definitions, specification templates, contribution rules, or project conventions.

## Primary Workflow

1. The selected pilot reaches `Ready for review` or `Done` through managed runtime SDD.
2. The product offers `Make this repository SDD-aware` as an optional action and explains that managed runtime continues if the owner declines.
3. The owner opens package details and reviews source, version, digest, provenance, license, every vendored file, referenced script, required permission, and supported agent adapter.
4. The worker verifies the repository's current commit against the approved execution profile and produces an exact non-executing change plan and diff.
5. Existing instructions and conventions remain authoritative. Compatible new files are proposed, ordinary conflicts adapt to existing rules or require manual resolution, and safety conflicts block installation.
6. The owner confirms the exact package, target commit, branch, file set, and diff.
7. The authorized worker applies only that plan on a new isolated branch and returns the resulting commit and verification evidence without merging.
8. Later update or removal follows the same explicit package, conflict, diff, branch, and confirmation workflow.

## Business Rules

- The permanent kit is optional. Declining, canceling, or being unable to install it must not disable managed runtime SDD.
- The offer appears only after the selected pilot has reached `Ready for review` or `Done`; it must not interrupt initial profile assessment or pilot execution.
- Only the project owner may approve installation, update, or removal. Other authorized participants may inspect the package and proposed diff.
- Every kit package is immutable and identified by source, publisher, semantic version, content digest, license, creation time, file manifest, included scripts, supported agent adapters, required permissions, and superseded version when applicable.
- All installed workflow files and scripts are vendored into the proposed branch and must be inspectable before confirmation.
- Planning and installation must not download or execute remote code, follow mutable remote references, run repository hooks, or execute included scripts.
- A package update is never selected or applied automatically. A newer available version is information only until the owner starts an explicit update.
- The change plan is bound to one approved execution profile, repository identity, exact base commit, kit digest, target branch name, and complete file-operation set.
- A stale base commit, changed execution profile, changed package digest, or changed diff invalidates prior confirmation.
- Existing `AGENTS.md`, `CLAUDE.md`, CI definitions, specification templates, contribution rules, and project conventions must never be overwritten.
- Existing repository instructions win when they can coexist safely. The kit may omit or adapt a conflicting generic rule in the reviewed plan but cannot silently reinterpret the existing rule.
- A conflict with fixed safety, least-privilege, secret-protection, branch-isolation, or verification requirements blocks installation and cannot be overridden in the product.
- An ordinary unresolved file or convention conflict blocks automatic application and shows the files and manual next step.
- Application occurs only on a new isolated branch created from the confirmed base commit. It never writes directly to or merges into the default branch.
- Application is limited to the confirmed file operations. An unexpected target file, symlink, path escape, repository change, hook request, or additional mutation stops the operation without applying the remainder as a successful installation.
- A successful installation records the exact package, plan, branch, resulting commit, installed file digests, verification evidence, and owner confirmation.
- Retrying the same confirmed operation is idempotent. A changed operation requires a new plan and confirmation.
- Update changes only files still proven to be owned by the installed kit. User-modified or repository-owned files produce a reviewed conflict rather than being replaced.
- Removal deletes only files proven to be owned by the recorded installation and leaves user-modified or shared files for explicit review.
- The kit may include workflow skills, tool contracts, validation scripts, and empty reusable templates, but it must not persist project-specific specifications in the repository.
- Project specifications remain authoritative only through `capability:project-specification-store`. Kit skills that read or change a project feature must use an authorized Orchestrator interface; they must stop when that authority is unavailable.
- Installation does not create bidirectional repository synchronization, background export, or another specification identity.
- Package, plan, installation, update, and removal records are governed confidential project data, follow the project's storage mode, and are prohibited from analytics, advertising, model training, or unrelated reuse.

## Acceptance Criteria

- [AC-01] Given the pilot has reached `Ready for review` or `Done`, when permanent adoption is presented, then the kit is clearly optional and declining it leaves managed runtime SDD available.
- [AC-02] Given an owner inspects a kit version, when package details open, then source, publisher, version, digest, provenance, license, file manifest, scripts, adapters, permissions, and supersession are visible and immutable.
- [AC-03] Given kit planning or installation runs, when network, script, hook, or mutable-reference behavior is inspected, then no remote code is downloaded or executed and no silent update occurs.
- [AC-04] Given an approved profile, exact base commit, and kit package, when planning completes, then every proposed create, modify, omit, and conflict operation appears in one exact reviewable diff.
- [AC-05] Given existing instructions, CI, templates, or conventions are present, when the plan is built, then none is overwritten and compatible existing rules remain authoritative.
- [AC-06] Given an ordinary conflict exists, when planning finishes, then automatic application remains blocked pending a compatible plan or manual resolution; given a safety conflict exists, then installation remains blocked without an override.
- [AC-07] Given the owner confirms the current plan, when application succeeds, then only the confirmed operations exist on a new isolated branch and one resulting commit and proof set are recorded.
- [AC-08] Given an application is stale, escapes its root, encounters an unexpected file or symlink, or attempts a default-branch write, when validation runs, then it stops without claiming successful installation.
- [AC-09] Given the same confirmed operation is retried, when its recorded result exists, then the same installation result is returned without duplicate files or commits; changed input requires a new confirmation.
- [AC-10] Given a newer package is available, when no owner-approved update plan exists, then installed files remain unchanged; an approved update changes only proven kit-owned files.
- [AC-11] Given removal is requested, when its reviewed plan runs, then only proven kit-owned unchanged files are deleted and user-modified or shared files remain visible for resolution.
- [AC-12] Given package, plan, installation, update, removal, logs, cache, or processor records are inspected, when governance proof runs, then storage, access, retention, deletion, redaction, and no-secondary-use rules are enforced.
- [AC-13] Given a kit is installed, declined, updated, or removed, when specification authority is inspected, then Orchestrator remains the only project-specification store and no project-specific repository copy or bidirectional synchronization exists.

## Open Questions

- None.
