# Repository Execution Profile Completion Design

## Context

`specs/14-repository-execution-profile/` owns the repository-binding, assessment, cache, immutable profile, pilot, and independent-readiness workflows. Its task-size preflight separated privacy and lifecycle enforcement plus final capability publication because those controls have independent ownership, failure paths, and proof from profile proposal and review.

The project already provides hosted and device-authoritative storage governance and project-specification governance. This continuation consumes those capabilities and the two focused Slice 14 handoffs without copying their schemas, documents, or authority.

## Proposed Approach

First enforce one cross-boundary governance contract over the completed Slice 14 records and worker-local cache. Extend the existing processing inventory, access, deletion, retention, rights, processor, transfer, logging, backup, and negative analytics controls with strict field-purpose and locality proof for repository assessment data.

Then build one immutable allowlisted managed-runtime value from the exact approved profile, stable pilot specification identity and revision, readiness value, and versioned runtime-skill references. Serialize it deterministically, bind it to a digest, prove that no repository or specification document is copied or changed, and publish the final capability only after the focused tasks and slice verification gate pass.

## Components Affected

- Repository-assessment and profile processing inventory and field-purpose map.
- Hosted and device-authoritative access, deletion, retention, rights, and backup controls.
- Worker-local assessment-cache lifecycle and raw-index locality proof.
- Structured security logging, redaction, processor and transfer controls, and analytics-absence proof.
- Managed-runtime execution-profile value, deterministic codec, digest, and compatibility fixtures.
- Cross-specification capability provider and downstream consumer edges.

## Data and Access Boundaries

No new authoritative stored entity is introduced. This continuation governs and serializes the existing `RepositoryAssessment`, `RepositoryExecutionProfile`, pilot reference, readiness value, and worker-local cache provenance without taking ownership of their schemas or lifecycle transitions.

Required boundaries:

- Hosted records remain in PostgreSQL under current project authorization; device-authoritative records remain in the owning device store with no durable hosted copy.
- Raw repository content, scan indexes, absolute paths, credentials, raw worker diagnostics, and repository archives remain outside authoritative project storage and the managed-runtime value.
- The worker cache stores only complete bounded structured results under the exact key and follows the approved worker-local lifecycle; incomplete, failed, canceled, or stale values are never reusable.
- Rights, project deletion, retention, backup expiry, access revocation, and log redaction cover assessment, profile, pilot, readiness, cache metadata, and derived compatibility values.
- The managed-runtime value references one authoritative specification identity and revision and never copies `requirements.md`, `design.md`, or `tasks.md` content.
- Release evidence remains inside the deployment-governance boundary and is represented here only by readiness state.

## Interfaces

- Governance compatibility interface: assert exact field purpose, storage destination, role access, locality, lifecycle, redaction, processor, transfer, and no-secondary-use rules across Slice 14 values.
- Profile-read interface: resolve one exact immutable approved profile and current readiness value without mutation or fallback across authorities.
- Pilot-reference interface: resolve one stable current specification and revision reference through `capability:project-specification-governance` without copying documents.
- Managed-runtime codec: validate an exact allowlist, serialize deterministically, and compute one content digest.
- Capability publication interface: expose `capability:repository-execution-profile` only after both task receipts and the complete slice verification gate are recorded.

## Decisions and Tradeoffs

### Separate Governance And Publication Continuation

- Choice: Keep privacy and lifecycle enforcement plus final capability publication in a focused continuation after Slice 14's approved-pilot and readiness handoffs.
- Reason: These controls have independent security, privacy, deletion, retention, compatibility, and full-gate proof and do not need to enlarge profile proposal or UI tasks.
- Consequence: Downstream consumers wait for one additional two-task specification, while Slice 14 profile work remains independently implementable.

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
- Privacy tests may be mistaken for legal approval. Report local control evidence separately from deployment-specific accountable review.

## Open Questions

- None.
