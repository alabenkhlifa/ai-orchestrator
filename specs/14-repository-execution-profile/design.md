# Repository Execution Profile Design

## Context

Guided delivery already binds a managed run to an immutable specification revision and execution manifest, while project specification storage owns the authoritative complete document set. Mature repositories that predate SDD may still lack an explicit repository root, reliable commands, instruction precedence, or a verification contract. Requiring permanent external skills would add a repository-mutation and supply-chain decision before the user has proved the managed workflow.

Local repository access already occurs through a workspace-authorized worker, and local onboarding explicitly reserves later source operations for a separate data contract. This feature defines that read-only contract without changing onboarding permissions or repository files.

## Proposed Approach

Before creating an assessment, show the processing disclosure and require confirmation when the boundary is first used or materially changed. Only then may a repository-binding preparation call the existing workspace-authorized worker boundary. The owner selects one root inside the connected repository; the worker proves the project's canonical repository identity, normalizes the repository-relative root, resolves the current full commit, and returns a short-lived single-use `RepositoryBindingPreparation`. No absolute path, source content, Git history, remote URL, credential, or raw diagnostic crosses the worker boundary. Authorization consumes the preparation only after the worker revalidates that the identity, root, and commit are unchanged.

Create a worker-local scanner that receives the authorized `RepositoryAssessment` binding, scan contract version, limits, and processing confirmation. It inspects an allowlisted set of high-signal files, produces source-anchored structured findings, and retains any raw index only in the worker boundary. While that evidence is local, a deterministic worker component derives one strict minimized `RepositoryExecutionProfileProposalPayload`; it emits only normalized commands, required checks, allowed scope, gaps, conflicts, and multi-root blockers, and records stable blocker codes instead of guessing from ambiguous evidence. Complete results and their exact payloads may be cached for the exact commit and contract.

For every fresh or cached delivery, rebuild one transient worker envelope from the cache-stable payload and bind it to the current assessment command, Task 9 cache-key and evidence digests, payload digest, repository identity, root, commit, scanner and limit contracts, and its own deterministic envelope digest. Persist the minimized terminal `RepositoryAssessment` result, that current exact envelope, and immutable approved `RepositoryExecutionProfile` in the project's authoritative storage mode. The envelope repeats no raw evidence and a prior assessment binding is never reusable. A completed assessment also persists the worker-reported cache source and whether the complete evidence remained cached; canceled and failed outcomes persist neither cache provenance nor a proposal envelope. Task 11 reconstructs Task 10's transient proposal only from that authoritative envelope, then the owner may approve or reject it. Pilot selection and independent readiness continue in `specs/30-repository-execution-profile-completion/`.

Publish `capability:repository-profile-review` to `specs/30-repository-execution-profile-completion/`. That focused continuation owns pilot selection and independent readiness, enforces privacy and lifecycle controls, and publishes the final profile capability for a later `update-spec` change to Slice 07. Neither specification silently changes Slice 07's approved manifest.

## Components Affected

- SDD adoption assessment and profile review surfaces.
- Disclosure-confirmed repository-binding preparation and worker metadata adapter.
- Worker repository-assessment protocol and local scanner.
- Worker-local proposal-payload derivation, cache parity, and current-command envelope binding.
- Hosted and device-authoritative assessment and profile adapters.
- Commit-scoped worker cache and cancellation.
- Field minimization, project authorization, worker-locality, and redaction boundaries.

## Data and Access Boundaries

- `RepositoryBindingPreparation`: one short-lived, single-use worker-verified value bound to the owning project, canonical repository identity, normalized repository-relative root, current full commit, scanner-contract and processing-boundary digests, opaque worker reference, nonce, and issue and expiry times. It is not authoritative project data and contains no absolute path, source content, Git history, remote URL, credential, or raw diagnostic.
- `RepositoryAssessment`: one project-scoped read-only assessment request and terminal result bound to repository identity, selected root, exact commit, scanner contract version, limits, structured findings, evidence anchors, and minimized cache provenance. Cache provenance contains only the worker-reported `fresh_scan` or `complete_cache` source, SHA-256 cache-key and evidence digests, and a cache-stored boolean, and exists only for a completed result.
- `RepositoryExecutionProfileProposalPayload`: one worker-local cache value containing only normalized `commands`, `required_checks`, `allowed_scope`, `gaps`, `conflicts`, and `multi_root_blockers`, bound to Task 9's reusable cache-key and evidence digests plus a deterministic payload digest. It contains no assessment id, disclosure digest, worker reference, raw content, excerpt, index, absolute path, credential, or raw diagnostic.
- `RepositoryExecutionProfileProposalEnvelope`: one strict worker-generated minimized delivery bound to a single current completed assessment, its project and repository identity, selected root, exact commit, scanner and limit contracts, cache-key, evidence and payload digests, and a deterministic envelope digest. It contains the exact cache-stable payload but never reuses a prior assessment binding; raw content, excerpts, indexes, absolute paths, credentials, and raw diagnostics are prohibited.
- `RepositoryExecutionProfile`: one immutable approved profile version containing selected root, base revision, instruction precedence, allowed execution scope, normalized project commands, required-check contract, blockers, and approval actor. The continuation references this version without mutating it when it stores a pilot.

Required boundaries:

- `RepositoryAssessment`, `RepositoryExecutionProfileProposalEnvelope`, and `RepositoryExecutionProfile` follow the project's hosted or device-authoritative storage mode; device-authoritative assessment data creates no durable hosted copy. A `RepositoryBindingPreparation` remains transient and creates no durable hosted copy in either mode.
- Worker authorization comes from `capability:workspace-bound-local-worker-authorization` and grants only the preparation or assessment command's project, repository, root, commit, and read-only capability. A hosted-project preparation requires explicit current selection of one available device workspace and worker without creating an implicit account-to-device association.
- The preparation adapter must prove the selected repository matches the project's canonical repository identity before returning a root or commit. It rejects unknown, malformed, mismatched, cross-project, cross-workspace, unavailable, expired, replayed, and changed inputs without persisting an assessment or issuing a scan command.
- Raw file content, repository index, paths outside the selected root, ignored secrets, binaries, dependencies, and generated output remain outside authoritative project storage.
- `RepositoryExecutionProfileProposalPayload` remains worker-local and, when retained, exists only inside the complete cache. Authoritative storage receives only the current assessment-bound envelope after Task 15 validation.
- Stored evidence anchors are repository-relative and content-minimized. Any necessary excerpt is bounded, redacted, purpose-specific, and included in the disclosed processing boundary.
- Only the project owner may authorize assessment or approve a profile. Current authorized participants may read the assessment, proposal envelope, and approved profile within their project role.
- Proposal envelopes and profiles never contain repository credentials, worker secrets, model credentials, absolute paths, secret values, source excerpts, indexes, or source archives.
- The profile contains no specification document or pilot reference. The continuation consumes the specification identity and revision through `capability:project-specification-store` and stores its stable reference separately.

## Interfaces

- Assessment start interface: show scan categories, configured limits, processors, transfer behavior, and first or changed-boundary confirmation before any repository command; after a fresh preparation, show the verified repository, normalized root, and full exact commit before assessment authorization.
- Repository-binding preparation interface: consume an owner confirmation and explicit worker selection, prove the project's canonical repository identity inside the worker boundary, select and normalize one contained root, resolve the current full commit, return only the minimized short-lived value, and revalidate it unchanged on single-use consumption without scanning content or mutating the repository.
- Worker assessment command: authorize project and worker, validate normalized root containment and exact commit, apply the allowlist and limits, support cancellation, and return structured findings plus one current assessment-bound minimized proposal envelope with source-relative evidence support.
- Worker proposal interface: deterministically normalize only explicit evidence-supported commands, required checks and scope while raw evidence remains local; emit stable gaps, conflicts and multi-root blockers for missing or ambiguous evidence; bind the cache-stable payload to Task 9's reusable digests; then bind each delivery envelope to the current command, completed result, payload digest and envelope digest without executing repository content or calling a model.
- Worker cache interface: store only complete assessment results with their exact cache-stable proposal payloads under the project, repository identity, root, exact commit, scanner version, and limit contract; on a hit rebuild the current assessment envelope and reject incomplete, payload-missing, mismatched, stale, or prior-binding reuse.
- Cache-provenance handoff: require the worker cache result to supply its strict minimized provenance with a completed terminal result, validate the provenance against the exact command and evidence, persist it through the authoritative assessment adapter, and never infer a fresh scan or cache hit from stored findings.
- Assessment-store interface: persist request state, minimized structured results, cache provenance, and the exact proposal envelope through equivalent hosted and device-authoritative adapters without a cross-authority fallback.
- Profile approval interface: resolve the newest exact completed assessment and persisted envelope, reconstruct the transient Task 10 proposal without accepting caller-owned managed-runtime fields, compare the current commit and assessment, show every field and blocker, require owner approval, and append an immutable profile version.
- Profile-review capability interface: publish the exact immutable approved profile after Task 11 proof and readiness write-back without transferring assessment, envelope, or profile authority.
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

### Minimized Cache Provenance In Authoritative Results

- Choice: Persist the worker-reported cache source, deterministic cache-key and evidence digests, and cache-stored flag with completed authoritative assessment results; keep cache entries and raw indexes worker-local.
- Reason: Owners and participants need truthful provenance during profile review, while Task 9's ephemeral worker return cannot support later or cross-participant review by itself.
- Consequence: The digests and source flag become confidential project data governed by the project's authoritative storage mode and lifecycle; unsuccessful results contain none, and the control plane must reject missing, malformed, mismatched, or inferred provenance. Earlier completions without provenance remain immutable, cannot be backfilled or approved into a new profile, and require a new assessment.

### Cache-Stable Proposal Payload And Current Assessment Envelope

- Choice: Derive and cache the six managed-runtime proposal fields as one payload bound to Task 9's reusable evidence, then rebuild a separate minimized envelope bound to the current assessment command for every fresh or cached delivery.
- Reason: The worker is the only approved boundary that sees the evidence needed to identify real commands and checks, while Task 9 deliberately reuses evidence across assessment ids, disclosure digests, and worker references. A byte-identical assessment-bound envelope therefore cannot be both cache-stable and current. Separating the payload preserves deterministic cache parity without accepting a stale delivery binding.
- Consequence: The processing disclosure names only the minimized current envelope transfer; fresh scans and complete-cache hits return the same six fields and payload digest, while their envelope digest changes whenever the assessment command changes. Unsupported or ambiguous evidence becomes stable gaps or conflicts; earlier completions without a verifiable current envelope remain immutable and require reassessment before profile approval.

### Confirmed Binding Before Assessment Authorization

- Choice: Separate processing-boundary confirmation, short-lived worker repository binding, and final assessment authorization. The metadata-only preparation runs only after confirmation, returns one normalized root and full commit, and is revalidated when authorization consumes it.
- Reason: Existing hosted and device project records intentionally contain no trusted selected root or current commit, while owner-entered values cannot prove exactness or reject stale and cross-project input.
- Consequence: A stale, expired, replayed, mismatched, or unavailable preparation blocks assessment before persistence or scanning. The preparation adds no independent repository scan and does not use or modify the personal-AI socket, channel, or Endpoint owned by Slice 11 Task 7.

## Risks

- High-signal files may not describe the real build. Surface uncertainty and require owner confirmation rather than claiming readiness.
- Malicious repository instructions may attempt prompt injection. Treat all scanned text as untrusted evidence, never execute it during scanning, and preserve fixed tool and safety policy above repository content.
- A stale cache may approve obsolete commands. Bind reuse to exact commit, root, scanner contract, and completed result.
- Cache provenance may be detached from the evidence it describes. Validate the worker-reported cache key and evidence digests against the exact completed command and result before authoritative persistence, and never reconstruct the source flag after the fact.
- A proposal payload may be detached from its evidence or a cached envelope may retain a prior assessment binding. Bind the payload to Task 9 cache-key and evidence digests, rebuild the envelope for the current command, bind both digests, and reject missing, mismatched, caller-supplied, prior-binding, or legacy envelopes.
- A prepared binding may become stale before authorization. Make it short-lived and single-use, and require worker revalidation of repository identity, root, and full commit when it is consumed.
- Profile approval may be mistaken for repository approval. Show that the profile governs managed runtime only and does not change repository policy.
- Source anchors or excerpts may expose confidential data. Minimize, redact, access-control, and keep raw content worker-local.

## Open Questions

- None.
