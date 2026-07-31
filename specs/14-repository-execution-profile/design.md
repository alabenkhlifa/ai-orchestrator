# Repository Execution Profile Design

## Context

Guided delivery already binds a managed run to an immutable specification revision and execution manifest, while project specification storage owns the authoritative complete document set. Mature repositories that predate SDD may still lack an explicit repository root, reliable commands, instruction precedence, or a verification contract. Requiring permanent external skills would add a repository-mutation and supply-chain decision before the user has proved the managed workflow.

Local repository access already occurs through a workspace-authorized worker, and local onboarding explicitly reserves later source operations for a separate data contract. This feature defines that read-only contract without changing onboarding permissions or repository files.

## Proposed Approach

Create a worker-local scanner that receives an authorized project, repository identity, selected root, exact commit, scan contract version, limits, and processing confirmation. It inspects an allowlisted set of high-signal files, produces source-anchored structured findings, and retains any raw index only in the worker boundary. Complete results may be cached for the exact commit and contract.

Persist a minimized `RepositoryAssessment` and immutable approved `RepositoryExecutionProfile` in the project's authoritative storage mode. The profile normalizes the root, base revision, existing instruction precedence, project commands, required-check contract, allowed execution scope, and readiness blockers without replacing repository rules. Link one pilot to an existing authoritative specification identity and revision.

Expose the completed profile as a capability for a later `update-spec` change to Slice 07. The current feature proves the consumer value contract but does not silently change Slice 07's approved manifest.

## Components Affected

- SDD adoption assessment and profile review surfaces.
- Worker repository-assessment protocol and local scanner.
- Hosted and device-authoritative assessment and profile adapters.
- Commit-scoped worker cache and cancellation.
- Pilot feature selection through the shared specification-store interface.
- Four-axis readiness presentation.
- Privacy, lifecycle, authorization, and redaction controls.

## Data and Access Boundaries

- `RepositoryAssessment`: one project-scoped read-only assessment request and terminal result bound to repository identity, selected root, exact commit, scanner contract version, limits, structured findings, evidence anchors, readiness outcomes, and cache provenance.
- `RepositoryExecutionProfile`: one immutable approved profile version containing selected root, base revision, instruction precedence, allowed execution scope, normalized project commands, required-check contract, blockers, approval actor, and the referenced pilot specification and revision when selected.

Required boundaries:

- Both entities follow the project's hosted or device-authoritative storage mode; device-authoritative assessment data creates no durable hosted copy.
- Worker authorization comes from `capability:workspace-bound-local-worker-authorization` and grants only the command's project, repository, root, commit, and read-only assessment capability.
- Raw file content, repository index, paths outside the selected root, ignored secrets, binaries, dependencies, and generated output remain outside authoritative project storage.
- Stored evidence anchors are repository-relative and content-minimized. Any necessary excerpt is bounded, redacted, purpose-specific, and included in the disclosed processing boundary.
- Only the project owner may authorize assessment or approve a profile. Current authorized participants may read the resulting readiness within their project role.
- Profiles never contain repository credentials, worker secrets, model credentials, absolute paths, secret values, or source archives.
- The specification identity and revision reference are consumed from `capability:project-specification-store`; the profile does not copy specification documents.

## Interfaces

- Assessment start interface: show root, commit, scan categories, configured limits, processors, transfer behavior, and changed-boundary confirmation before issuing a command.
- Worker assessment command: authorize project and worker, validate normalized root containment and exact commit, apply the allowlist and limits, support cancellation, and return structured findings with source-relative anchors.
- Worker cache interface: store only complete assessment results under the project, repository identity, root, exact commit, scanner version, and limit contract; reject incomplete or stale reuse.
- Assessment-store interface: persist request state and minimized structured results through equivalent hosted and device-authoritative adapters.
- Profile approval interface: compare the current commit and assessment, show every field and blocker, require owner approval, and append an immutable profile version.
- Pilot-selection interface: resolve one current specification and revision through the shared store and add only their stable references to the approved profile.
- Readiness interface: project assistant, specification, agent execution, and release status with separate reason codes and earliest blocking stage.
- Managed-runtime compatibility interface: serialize the approved profile as an allowlisted value suitable for a future execution-manifest consumer without repository mutation.

## Decisions and Tradeoffs

### Managed Runtime Before Permanent Installation

- Choice: Deliver an approved profile for managed runtime without installing repository files.
- Reason: Users can prove SDD value before accepting an external kit or repository changes.
- Consequence: Agents launched independently outside Orchestrator do not automatically receive the managed profile.

### High-Signal Bounded Scan

- Choice: Inspect allowlisted instructions, contribution rules, manifests, CI, checks, and structure instead of indexing all source.
- Reason: These surfaces establish agent constraints and verification with less privacy exposure and predictable latency.
- Consequence: A profile may remain blocked when reliable behavior cannot be established from the bounded evidence; the product asks for owner input instead of expanding silently.

### Existing Instructions Remain Authoritative

- Choice: Normalize existing rules into the profile without replacing their meaning.
- Reason: Mature repositories may encode security, release, compliance, and engineering constraints that an imported workflow cannot supersede.
- Consequence: Unresolved incompatibility blocks autonomous execution, while compatible read-only assistant access remains separately available.

### One Pilot And No Backlog Import

- Choice: Link one user-selected authoritative specification revision and leave all repository backlog systems untouched.
- Reason: A controlled pilot is easier to verify and avoids accidental duplication or reprioritization of existing work.
- Consequence: Backlog import and synchronization require a separate specification.

### Verification Must Be Reliable

- Choice: Block verified completion and `Ready for review` until an approved reliable required-check contract exists.
- Reason: Agent output without reproducible proof is not verified delivery.
- Consequence: Assistant and specification work can proceed while agent-execution or review readiness remains blocked.

### Worker-Local Source Boundary

- Choice: Keep scanning and indexing worker-local and persist only minimized structured results.
- Reason: Whole-repository upload is unnecessary for this workflow and would expand privacy, security, retention, and processor exposure.
- Consequence: Remote support or model analysis receives only explicitly disclosed allowlisted content.

## Risks

- High-signal files may not describe the real build. Surface uncertainty and require owner confirmation rather than claiming readiness.
- Malicious repository instructions may attempt prompt injection. Treat all scanned text as untrusted evidence, never execute it during scanning, and preserve fixed tool and safety policy above repository content.
- A stale cache may approve obsolete commands. Bind reuse to exact commit, root, scanner contract, and completed result.
- Profile approval may be mistaken for repository approval. Show that the profile governs managed runtime only and does not change repository policy.
- Source anchors or excerpts may expose confidential data. Minimize, redact, access-control, and keep raw content worker-local.

## Open Questions

- None.
