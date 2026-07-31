# Empty Repository Initialization Design

## Context

The current local onboarding identity derives from root commits and explicitly leaves unborn repositories unsupported. An empty repository also lacks the project-specific commands and verification needed for autonomous delivery. Installing workflow skills alone would create process files without a valid technical foundation.

The governed AI runtime can host a read-only support conversation and a separately authorized working agent. Repository kit integration supplies the immutable vendored kit package and source-of-truth contract. Project specification storage becomes available after the initialized repository completes normal onboarding.

## Proposed Approach

Use `capability:ai-runtime-session` to conduct product-first discovery and retain a versioned `RepositoryInitializationPlan` without filesystem mutation. The plan records the approved purpose, first outcome, technical foundation, structure, commands, checks, Git behavior, kit choice, exact package, processing boundary, and required capabilities.

After explicit confirmation, create a `RepositoryInitializationRun` and send the immutable plan to a separately authorized working agent in a worker-owned staging root. Generate the minimal skeleton, vendor the approved kit when selected, initialize Git with hooks disabled, run the approved checks, and create one first commit in staging. Publish only after revalidating that the selected target is still empty and unchanged.

Record one `RepositoryInitializationResult`, then hand the repository to normal local onboarding. After project creation, use the shared specification store to create the initialization agreement as one complete authoritative document set. No project-specific specification is written into the repository.

## Components Affected

- Empty-repository entry, eligibility, and operating-system directory selection.
- Governed read-only initialization support conversation.
- Initialization-plan review, disclosure, kit choice, and confirmation.
- Working-agent staging, filesystem, Git, package, and command adapters.
- Check evidence, first-commit identity, idempotency, and publication.
- Normal local-onboarding and specification-store handoffs.
- Four-axis readiness and initialization activity presentation.
- Privacy, lifecycle, rights, redaction, and no-analytics controls.

## Data and Access Boundaries

- `RepositoryInitializationPlan`: one versioned pre-project plan containing user-approved purpose, users, first outcome, constraints, technical foundation, structure, commands, checks, Git behavior, kit choice and package digest, processing boundary, target eligibility reference, and confirmation state.
- `RepositoryInitializationRun`: one authorized plan-bound working-agent lifecycle with staging identity, worker and provider references, minimum capability grants, ordered progress, check evidence, cancellation or failure state, and idempotency key.
- `RepositoryInitializationResult`: one immutable successful outcome containing the plan and run references, target boundary reference, exact first commit, checked tree digest, selected kit version when any, proof references, completion time, and onboarding handoff state.

Required boundaries:

- Before project creation, plans, runs, and results live only inside the governed AI runtime's approved pre-project boundary. After handoff, applicable records follow the selected project storage and lifecycle contract.
- Support-session tools exclude filesystem mutation, Git mutation, package apply, process execution, and working-agent launch.
- The working agent receives only the confirmed plan and staging-scoped capabilities. Runtime, worker, provider, and repository credentials remain outside agent-readable content.
- Staging is contained under a normalized worker root and is separate from the selected target. The target is read only for eligibility and unchanged-boundary checks until publication.
- Raw staging indexes and source content remain worker-local. Only minimized plan, progress, evidence, result, and disclosed content cross configured processor boundaries.
- Package content is pinned to the `capability:sdd-kit-package` digest and treated as inert vendored input. Hooks and remote execution are disabled.
- After onboarding, project specification documents exist only through `capability:project-specification-store`.

## Interfaces

- Empty-target eligibility interface: select through the operating system, classify empty directory or unborn Git repository, reject commits and unexpected content, and issue an opaque target reference without exposing an absolute path.
- Initialization support interface: use a governed AI session with read-only project-discovery and plan tools and no mutation tools.
- Plan interface: append versioned product and technical decisions, validate completeness, render exact structure, commands, checks, Git actions, kit contents, permissions, providers, and transfers.
- Confirmation interface: bind one user authorization to the exact plan, target reference, provider and worker boundary, kit digest, capabilities, and disclosure version.
- Working-agent command: create one plan-bound run, materialize only in staging, enforce capability and path containment, normalize progress, and support cancellation.
- Skeleton adapter: create only allowlisted plan files and directories and reject undeclared output.
- Git adapter: initialize only inside staging, disable hooks, stage the exact generated tree, and create one first commit after checks pass.
- Check adapter: execute only confirmed commands, capture typed results, and bind every required passing result to the committed tree.
- Publication interface: revalidate the target, publish the exact staged repository without merging, and fail closed on any change.
- Handoff interface: continue through normal local onboarding, then create one complete first specification revision in the shared store.
- Readiness interface: report assistant, specification, agent-execution, and release readiness independently.

## Decisions and Tradeoffs

### Product Before Technical Foundation

- Choice: Resolve purpose, users, first outcome, and constraints before asking for the minimum technical foundation.
- Reason: A skeleton should serve an approved product direction rather than reflect an arbitrary framework choice.
- Consequence: Initialization remains blocked while consequential product or architecture decisions are unresolved.

### Read-Only Support And Separate Working Agent

- Choice: Give the conversational assistant only planning tools and launch a distinct working agent after confirmation.
- Reason: Conversation should not become implicit permission to modify the user's filesystem.
- Consequence: Users see a clear transition from advice to authorized work and can cancel before mutation.

### Staged Initialization Before Publication

- Choice: Build, check, and commit in a worker-owned staging root before publishing to the still-empty target.
- Reason: Partial skeletons and failed checks should not leave the selected directory pretending to be initialized.
- Consequence: Publication requires target revalidation and a supported local atomic or rollback-safe transfer mechanism.

### Permanent Kit Proposed By Default

- Choice: Include the exact permanent kit in the reviewed plan by default but permit the user to decline it.
- Reason: A new repository has no conflicting instructions and benefits from durable agent discovery, while installation still requires informed consent.
- Consequence: Declining preserves managed runtime SDD but independently launched repository agents lack automatic access to those workflows.

### First Commit Before Normal Onboarding

- Choice: Establish the checked root commit before invoking local onboarding.
- Reason: Portable local repository identity depends on root commits.
- Consequence: Initialization uses a pre-project runtime boundary and hands authority to ordinary onboarding only after success.

### Specification Authority After Project Creation

- Choice: Convert the approved initialization agreement into one complete shared-store revision after onboarding, without repository specification files.
- Reason: The project specification store requires project authority and must remain the sole revision source.
- Consequence: The pre-project plan is a governed initialization record, not a second project specification identity.

## Risks

- The support model may pressure users into a stack choice. Keep consequential decisions explicit and user-approved.
- A generated skeleton may include undeclared files or unsafe commands. Enforce the plan allowlist and run only confirmed checks.
- The target may change during staging. Revalidate identity, emptiness, symlinks, permissions, and commit state immediately before publication.
- Failed publication may leave partial data. Use an atomic or rollback-safe local transfer and preserve failure evidence without deleting unexpected user content.
- Package or template content may include executable behavior. Pin the digest, show scripts and permissions, disable hooks and remote execution, and execute only confirmed project checks.
- Pre-project data may outlive a canceled attempt. Apply short retention, deletion, rights, processor, and backup rules through AI runtime governance.

## Open Questions

- None.
