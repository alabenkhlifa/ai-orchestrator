# Repository Execution Profile Design

## Context

Guided delivery already binds a managed run to an immutable specification revision and execution manifest, while project specification storage owns the authoritative complete document set. Mature repositories that predate SDD may still lack an explicit repository root, reliable commands, instruction precedence, or a verification contract. Requiring permanent external skills would add a repository-mutation and supply-chain decision before the user has proved the managed workflow.

Local repository access already occurs through a workspace-authorized worker, and local onboarding explicitly reserves later source operations for a separate data contract. This feature defines that read-only contract without changing onboarding permissions or repository files.

## Proposed Approach

Before creating an assessment, show the processing disclosure and require confirmation when the boundary is first used or materially changed. Only then may a repository-binding preparation call the existing workspace-authorized worker boundary. The owner selects one root inside the connected repository; the worker proves the project's canonical repository identity, normalizes the repository-relative root, resolves the current full commit, and returns a short-lived single-use `RepositoryBindingPreparation`. No absolute path, source content, Git history, remote URL, credential, or raw diagnostic crosses the worker boundary. Authorization consumes the preparation only after the worker revalidates that the identity, root, and commit are unchanged.

Create a worker-local scanner that receives the authorized `RepositoryAssessment` binding, scan contract version, limits, and processing confirmation. It inspects an allowlisted set of high-signal files, produces source-anchored structured findings, and retains any raw index only in the worker boundary. Complete results may be cached for the exact commit and contract.

Persist a minimized terminal `RepositoryAssessment` result and immutable approved `RepositoryExecutionProfile` in the project's authoritative storage mode. The profile normalizes the root, base revision, existing instruction precedence, project commands, required-check contract, allowed execution scope, and readiness blockers without replacing repository rules. Link one pilot to an existing authoritative specification identity and revision.

Publish the approved-pilot and independent-readiness handoffs to `specs/30-repository-execution-profile-completion/`. That focused continuation enforces privacy and lifecycle controls and publishes the final profile capability for a later `update-spec` change to Slice 07. Neither specification silently changes Slice 07's approved manifest.

## Components Affected

- SDD adoption assessment and profile review surfaces.
- Disclosure-confirmed repository-binding preparation and worker metadata adapter.
- Worker repository-assessment protocol and local scanner.
- Hosted and device-authoritative assessment and profile adapters.
- Commit-scoped worker cache and cancellation.
- Pilot feature selection through the shared specification-store interface.
- Four-axis readiness presentation.
- Privacy, lifecycle, authorization, and redaction controls.

## Data and Access Boundaries

- `RepositoryBindingPreparation`: one short-lived, single-use worker-verified value bound to the owning project, canonical repository identity, normalized repository-relative root, current full commit, scanner-contract and processing-boundary digests, opaque worker reference, nonce, and issue and expiry times. It is not authoritative project data and contains no absolute path, source content, Git history, remote URL, credential, or raw diagnostic.
- `RepositoryAssessment`: one project-scoped read-only assessment request and terminal result bound to repository identity, selected root, exact commit, scanner contract version, limits, structured findings, evidence anchors, readiness outcomes, and cache provenance.
- `RepositoryExecutionProfile`: one immutable approved profile version containing selected root, base revision, instruction precedence, allowed execution scope, normalized project commands, required-check contract, blockers, approval actor, and the referenced pilot specification and revision when selected.

Required boundaries:

- `RepositoryAssessment` and `RepositoryExecutionProfile` follow the project's hosted or device-authoritative storage mode; device-authoritative assessment data creates no durable hosted copy. A `RepositoryBindingPreparation` remains transient and creates no durable hosted copy in either mode.
- Worker authorization comes from `capability:workspace-bound-local-worker-authorization` and grants only the preparation or assessment command's project, repository, root, commit, and read-only capability. A hosted-project preparation requires explicit current selection of one available device workspace and worker without creating an implicit account-to-device association.
- The preparation adapter must prove the selected repository matches the project's canonical repository identity before returning a root or commit. It rejects unknown, malformed, mismatched, cross-project, cross-workspace, unavailable, expired, replayed, and changed inputs without persisting an assessment or issuing a scan command.
- Raw file content, repository index, paths outside the selected root, ignored secrets, binaries, dependencies, and generated output remain outside authoritative project storage.
- Stored evidence anchors are repository-relative and content-minimized. Any necessary excerpt is bounded, redacted, purpose-specific, and included in the disclosed processing boundary.
- Only the project owner may authorize assessment or approve a profile. Current authorized participants may read the resulting readiness within their project role.
- Profiles never contain repository credentials, worker secrets, model credentials, absolute paths, secret values, or source archives.
- The specification identity and revision reference are consumed from `capability:project-specification-store`; the profile does not copy specification documents.

## Interfaces

- Assessment start interface: show scan categories, configured limits, processors, transfer behavior, and first or changed-boundary confirmation before any repository command; after a fresh preparation, show the verified repository, normalized root, and full exact commit before assessment authorization.
- Repository-binding preparation interface: consume an owner confirmation and explicit worker selection, prove the project's canonical repository identity inside the worker boundary, select and normalize one contained root, resolve the current full commit, return only the minimized short-lived value, and revalidate it unchanged on single-use consumption without scanning content or mutating the repository.
- Worker assessment command: authorize project and worker, validate normalized root containment and exact commit, apply the allowlist and limits, support cancellation, and return structured findings with source-relative anchors.
- Worker cache interface: store only complete assessment results under the project, repository identity, root, exact commit, scanner version, and limit contract; reject incomplete or stale reuse.
- Assessment-store interface: persist request state and minimized structured results through equivalent hosted and device-authoritative adapters.
- Profile approval interface: compare the current commit and assessment, show every field and blocker, require owner approval, and append an immutable profile version.
- Pilot-selection interface: resolve one current specification and revision through the shared store and add only their stable references to the approved profile.
- Readiness interface: project assistant, specification, agent execution, and release status with separate reason codes and earliest blocking stage.
- Completion handoff interfaces: publish the immutable approved profile plus current pilot reference and the four-axis readiness value without transferring profile, assessment, or specification authority.
- Managed-runtime compatibility interface: `specs/30-repository-execution-profile-completion/` serializes the approved profile as an allowlisted value suitable for a future execution-manifest consumer without repository mutation.

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

### Confirmed Binding Before Assessment Authorization

- Choice: Separate processing-boundary confirmation, short-lived worker repository binding, and final assessment authorization. The metadata-only preparation runs only after confirmation, returns one normalized root and full commit, and is revalidated when authorization consumes it.
- Reason: Existing hosted and device project records intentionally contain no trusted selected root or current commit, while owner-entered values cannot prove exactness or reject stale and cross-project input.
- Consequence: A stale, expired, replayed, mismatched, or unavailable preparation blocks assessment before persistence or scanning. The preparation adds no independent repository scan and does not use or modify the personal-AI socket, channel, or Endpoint owned by Slice 11 Task 7.

## Risks

- High-signal files may not describe the real build. Surface uncertainty and require owner confirmation rather than claiming readiness.
- Malicious repository instructions may attempt prompt injection. Treat all scanned text as untrusted evidence, never execute it during scanning, and preserve fixed tool and safety policy above repository content.
- A stale cache may approve obsolete commands. Bind reuse to exact commit, root, scanner contract, and completed result.
- A prepared binding may become stale before authorization. Make it short-lived and single-use, and require worker revalidation of repository identity, root, and full commit when it is consumed.
- Profile approval may be mistaken for repository approval. Show that the profile governs managed runtime only and does not change repository policy.
- Source anchors or excerpts may expose confidential data. Minimize, redact, access-control, and keep raw content worker-local.

## Open Questions

- None.
