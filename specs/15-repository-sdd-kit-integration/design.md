# Repository SDD Kit Integration Design

## Context

Managed runtime skills and authoritative Orchestrator specification revisions allow a pilot to run without changing the repository. Some teams nevertheless want durable, repository-visible workflows so independently launched supported agents can discover the SDD contract. That choice changes source files and introduces package provenance, conflict, update, removal, and software-supply-chain concerns.

The existing GitHub onboarding permission is metadata read-only and cannot be expanded implicitly. Repository changes therefore run through an already authorized worker and isolated branch after a separate owner decision.

## Proposed Approach

Register immutable `RepositoryKitPackage` versions in a trusted package catalog. Each package carries an exact content digest and a complete manifest for vendored workflow files, scripts, licenses, supported adapters, permissions, and compatibility.

After the managed pilot milestone, create a worker-local `RepositoryKitChangePlan` against the approved execution profile and exact commit. The planner reads but never executes repository or package content, preserves existing instructions, identifies ordinary and safety conflicts, and returns an exact file-operation diff.

After owner confirmation, apply the unchanged plan on a new isolated branch. Persist a `RepositoryKitInstallation` with package, plan, branch, commit, installed-file digests, verification, and lifecycle state. Updates and removal derive new reviewable plans from recorded ownership and never modify unproven files.

## Components Affected

- Optional post-pilot kit offer and package inspection UI.
- Immutable kit package catalog and integrity validation.
- Worker-local conflict planner and exact diff renderer.
- Isolated branch application adapter.
- Installation, update, removal, and ownership records.
- Hosted and device-authoritative persistence and governance.
- Agent-skill authoritative-specification adapter boundary.

## Data and Access Boundaries

- `RepositoryKitPackage`: one immutable distributable kit version with source, publisher, version, digest, provenance, license, file and script manifests, supported adapters, required permissions, compatibility, and supersession metadata.
- `RepositoryKitChangePlan`: one immutable project-scoped proposed operation set bound to profile version, repository identity, base commit, package digest, target branch, complete diff, conflicts, safety decision, and expiry.
- `RepositoryKitInstallation`: one project-scoped lifecycle record containing the applied package and plan, owner confirmation, branch, resulting commit, installed-file digests and ownership, verification evidence, current state, and later update or removal references.

Required boundaries:

- Package content is untrusted until its digest, manifest, provenance, paths, sizes, license presence, and declared permissions validate.
- Planning and apply run through the project's authorized worker. Repository credentials and worker credentials never enter package content or project-visible diffs.
- Package and repository files are parsed as inert content during planning. No script, hook, command substitution, symlink target, or remote reference executes.
- Hosted and device-authoritative project records follow the selected project storage mode. Device-authoritative repository content and diffs create no durable hosted source copy.
- Only current project participants may inspect plans; only the project owner may confirm mutation.
- Diffs and stored evidence exclude secret values and absolute local paths.
- Project-specific specification content remains in `capability:project-specification-store` and is never vendored by the kit.

## Interfaces

- Post-pilot eligibility interface: consume the selected pilot's managed-delivery state and offer the optional action only at `Ready for review` or `Done`.
- Kit-catalog interface: retrieve one immutable package by digest and expose its provenance, license, contents, scripts, adapters, permissions, and compatibility without following mutable references.
- Change-plan interface: ask the authorized worker to compare one package with the exact repository commit and approved profile, produce all file operations and conflicts, and execute nothing.
- Conflict-policy interface: preserve existing repository rules, distinguish compatible adaptation, ordinary manual conflict, and non-overridable safety conflict.
- Confirmation interface: bind the owner to the exact package digest, base commit, profile, branch, operation set, and rendered diff.
- Apply interface: validate unchanged inputs, create one isolated branch, apply only confirmed operations with hooks disabled, commit once, run only the separately approved non-package verification contract, and return evidence.
- Lifecycle interface: plan and confirm explicit update or removal using recorded file ownership and current digests.
- Authoritative-specification adapter: let installed skills access project specifications only through authorized Orchestrator tools and fail closed when unavailable.

## Decisions and Tradeoffs

### Optional After A Managed Pilot

- Choice: Offer permanent kit integration only after the pilot reaches `Ready for review` or `Done`.
- Reason: Users can evaluate actual managed SDD value before accepting repository files.
- Consequence: Repository-visible workflows are not available during the initial pilot, while managed runtime remains fully available.

### Vendored Immutable Package

- Choice: Install inspectable files from one digest-addressed package rather than remote references.
- Reason: Reviewers need to know exactly what agents may read and which scripts or permissions exist.
- Consequence: Updates require a new package, plan, diff, and confirmation.

### Existing Repository Rules Win

- Choice: Preserve existing instructions and adapt or omit compatible generic kit rules.
- Reason: A mature repository's rules may encode obligations unknown to the generic kit.
- Consequence: Some repositories require manual integration; safety conflicts block installation entirely.

### Branch-Only Mutation

- Choice: Apply one confirmed plan on a new isolated branch and never merge automatically.
- Reason: Repository owners and existing branch protection remain the final review authority.
- Consequence: Installation is not complete in the default branch until the repository's normal review and merge process accepts it.

### One Specification Authority

- Choice: Vendor workflow material but no project-specific specifications.
- Reason: Repository copies or bidirectional synchronization would create conflicting revision authority.
- Consequence: Installed skills require authorized Orchestrator tools for project feature reads and writes and stop when those tools are unavailable.

## Risks

- A malicious package may hide executable behavior. Validate complete contents and permissions, prohibit remote execution, and render every script before confirmation.
- A repository may change after planning. Bind confirmation and apply to the exact commit, profile, package, and diff.
- Removal may delete user work. Delete only unchanged files with recorded kit ownership and surface everything else as conflict.
- Existing rules may conflict indirectly. Keep evidence and block when precedence cannot be established safely.
- Diffs may expose secrets. Exclude secret paths, redact values, and keep raw repository comparison worker-local.

## Open Questions

- None.
