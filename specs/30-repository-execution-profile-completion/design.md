# Repository Execution Profile Completion Design

## Context

`specs/14-repository-execution-profile/` owns the repository-binding, assessment, cache-stable minimized proposal payload, current-assessment proposal envelope, immutable profile, and owner-review workflow. Its proposal-envelope refinement moved the still-unimplemented pilot and independent-readiness outcomes here so Slice 14 can publish one focused profile-review capability without exceeding its critical-path limit.

The project already provides hosted and device-authoritative storage governance and project-specification governance. This continuation consumes the single Slice 14 profile-review capability without copying its assessment, envelope, profile schema, or authority.

## Proposed Approach

First consume one exact owner-reviewed immutable profile. Let the owner select one current authoritative project specification revision as the pilot, persist only its stable identity and revision, and compute assistant, specification, agent-execution, and release readiness independently with stable earliest-stage reason codes. Stale repository state, instruction or safety conflicts, unsupported multi-root evidence, and missing or unreliable checks fail closed only at their affected stage.

Then enforce one cross-boundary governance contract over the completed Slice 14 records, worker-local cache, pilot reference, and readiness values. Extend the existing processing inventory, access, deletion, retention, rights, processor, transfer, logging, backup, and negative analytics controls with strict field-purpose and locality proof for repository assessment data.

Then build one immutable allowlisted managed-runtime value from the exact approved profile, stable pilot specification identity and revision, readiness value, and versioned runtime-skill references. Serialize it deterministically, bind it to a digest, prove that no repository or specification document is copied or changed, and publish the final capability only after the focused tasks and slice verification gate pass.

## Components Affected

- Repository-assessment and profile processing inventory and field-purpose map.
- Authoritative specification revision selector and stable pilot reference.
- Four-axis readiness evaluation, reason codes, required-check gate, and presentation.
- Hosted and device-authoritative access, deletion, retention, rights, and backup controls.
- Worker-local assessment-cache lifecycle and raw-index locality proof.
- Structured security logging, redaction, processor and transfer controls, and analytics-absence proof.
- Managed-runtime execution-profile value, deterministic codec, digest, and compatibility fixtures.
- Cross-specification capability provider and downstream consumer edges.

## Data and Access Boundaries

No new top-level profile authority is introduced. This continuation consumes the existing `RepositoryAssessment`, `RepositoryExecutionProfileProposalEnvelope`, `RepositoryExecutionProfile`, and worker-local cache provenance; it governs but does not persist the worker-local `RepositoryExecutionProfileProposalPayload`, and owns the stable pilot reference and readiness value needed for final publication without redefining upstream schemas or profile lifecycle transitions.

Required boundaries:

- Hosted records remain in PostgreSQL under current project authorization; device-authoritative records remain in the owning device store with no durable hosted copy.
- Raw repository content, scan indexes, absolute paths, credentials, raw worker diagnostics, and repository archives remain outside authoritative project storage and the managed-runtime value.
- The worker cache stores only complete bounded structured results and their cache-stable minimized proposal payload under the exact key and follows the approved worker-local lifecycle; assessment-bound envelopes, incomplete, failed, canceled, or stale values are never reusable.
- Rights, project deletion, retention, backup expiry, access revocation, and log redaction cover assessment, proposal-envelope, profile, pilot, readiness, cache metadata, and derived compatibility values.
- The managed-runtime value references one authoritative specification identity and revision and never copies `requirements.md`, `design.md`, or `tasks.md` content.
- Release evidence remains inside the deployment-governance boundary and is represented here only by readiness state.

## Interfaces

- Profile-review consumer: resolve one exact immutable owner-approved profile through `capability:repository-profile-review` without accepting replacement proposal fields or changing profile authority.
- Pilot-selection interface: resolve one current specification and revision through `capability:project-specification-store`, persist only their stable references, and refuse stale revisions, copies, issue import, and non-owner mutation.
- Readiness interface: compute and present independent assistant, specification, agent-execution, and release values with stable reason codes, earliest blocked stage, stale repository checks, conflict behavior, multi-root behavior, and reliable required-check enforcement.
- Governance compatibility interface: assert exact field purpose, storage destination, role access, locality, lifecycle, redaction, processor, transfer, and no-secondary-use rules across Slice 14 and completion values.
- Profile-read interface: resolve one exact immutable approved profile and current readiness value without mutation or fallback across authorities.
- Pilot-reference interface: resolve one stable current specification and revision reference through `capability:project-specification-governance` without copying documents.
- Managed-runtime codec: validate an exact allowlist, serialize deterministically, and compute one content digest.
- Capability publication interface: expose `capability:repository-execution-profile` only after both task receipts and the complete slice verification gate are recorded.

## Decisions and Tradeoffs

### Separate Governance And Publication Continuation

- Choice: Keep pilot selection, independent readiness, privacy and lifecycle enforcement, and final capability publication in one focused continuation after Slice 14's profile-review handoff.
- Reason: Pilot and readiness are the two completion inputs for governance and publication, while moving them out of Slice 14 preserves the assessment-to-review task-size and critical-path gates without duplicating profile authority.
- Consequence: Slice 14 ends at one trusted reviewed profile; this continuation owns four focused tasks in sequence, with pilot selection establishing the exact feature context for readiness before governance and final publication.

### Reference, Do Not Copy

- Choice: Serialize stable profile, pilot, readiness, and runtime-skill references and obtain authoritative specification content only through its existing capability at execution time.
- Reason: Copying specification documents would create a second authority and unnecessary personal or project-content storage.
- Consequence: A missing, stale, or unauthorized authoritative revision blocks compatibility instead of falling back to a copied snapshot.

### Final Publication After Full Deterministic Proof

- Choice: Keep both tasks focused and publish the final capability only after the separate slice-scoped repository, browser, security, dependency, production-build, and compatibility gate passes.
- Reason: Capability consumers need one trustworthy readiness point without turning routine task proof into a broad regression run.
- Consequence: Completed task implementations do not by themselves make the final capability available.

## Risks

- A serializer may leak a field newly added upstream. Enforce an exact recursive allowlist and reject unknown fields.
- Device-authoritative data may accidentally gain a hosted cache. Prove negative hosted persistence and fail closed rather than falling back across authorities.
- A stale profile or pilot revision may be published. Bind the value and digest to the exact immutable profile version and authoritative specification revision.
- Readiness may collapse independent stages into one optimistic status. Preserve four values, stable reason codes and the earliest affected stage, and deny verified completion or `Ready for review` until a reliable required-check contract passes.
- Privacy tests may be mistaken for legal approval. Report local control evidence separately from deployment-specific accountable review.

## Open Questions

- None.
