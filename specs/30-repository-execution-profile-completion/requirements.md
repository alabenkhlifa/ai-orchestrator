# Repository Execution Profile Completion

## Status

Approved

## Outcome

An approved repository execution profile and pilot become a privacy-governed, deterministic managed-runtime capability without copying source, specification documents, credentials, or repository files into a new authority.

## Users

- Project owners relying on the approved profile and pilot for managed SDD work.
- Current authorized project participants reading readiness within their role.
- Engineers and reviewers deciding whether the final execution-profile capability is safe and compatible.
- Operators distinguishing local implementation and verification readiness from deployment release readiness.

## In Scope

- Privacy, security, retention, deletion, rights, processor, transfer, logging, analytics, and secondary-use controls for the completed assessment, worker cache, profile, and pilot records.
- Equivalent hosted and device-authoritative governance with raw source and the scan index remaining worker-local.
- Deterministic allowlisted serialization of the exact approved profile and stable pilot specification reference.
- No-repository-mutation and no-specification-copy compatibility proof.
- Final `capability:repository-execution-profile` publication after the focused task proof and full slice verification gate pass.

## Out of Scope

- Repeating repository binding, scanning, cache, profile proposal, approval, pilot selection, or readiness implementation owned by `specs/14-repository-execution-profile/`.
- Changing Slice 07's approved execution manifest or beginning a managed run.
- Permanent repository kit installation, repository mutation, backlog import, or production deployment.
- Selecting deployment vendors or approving deployment-specific privacy or legal evidence.

## Primary Workflow

1. The continuation resolves the exact approved-pilot and repository-readiness capability versions from Slice 14.
2. It verifies that assessment, cache, profile, and pilot data follow the project's authoritative storage mode, access, lifecycle, minimization, processor, transfer, logging, and no-secondary-use rules.
3. It serializes only the allowlisted approved profile fields and stable pilot specification identity and revision with a deterministic digest.
4. It proves the value can be supplied with authoritative SDD revisions and versioned runtime skills without copying specifications or changing repository files.
5. After its focused tasks and complete deterministic verification gate pass, it publishes `capability:repository-execution-profile` for separately approved consumers.

## Business Rules

- Slice 14 remains authoritative for assessment results, cache provenance, profile versions, pilot references, readiness reasons, and their product behavior. This continuation cannot redefine those records or approve a new profile or pilot.
- Assessment and profile data are confidential project data and follow the project's hosted or device-authoritative storage mode. Device-authoritative values create no durable hosted copy.
- Raw repository content and the scan index remain worker-local. Authoritative storage contains only the minimized structured result, source-relative anchors, approved profile, stable pilot reference, readiness values, and disclosed necessary metadata.
- Current authorized participants may read readiness within their role; only the project owner may approve or replace a profile or pilot through the Slice 14 workflow.
- Retention, deletion, rights, processor, transfer, log-redaction, cache, backup, and project-isolation controls cover derived records and both authoritative storage modes.
- Assessment, cache, profile, pilot, readiness, and compatibility data are prohibited from product analytics, advertising, model training, and unrelated reuse.
- The managed-runtime value contains no raw source, scan index, absolute path, repository credential, worker credential, model credential, raw diagnostic, specification document, or repository archive.
- `capability:repository-execution-profile` remains unavailable after any missing provider, privacy or lifecycle failure, incompatible or nondeterministic serialization, specification copy, repository mutation, or required deterministic verification failure.
- Missing deployment-specific controller, processor, region, transfer safeguard, notice, live retention enforcement, incident, or accountable privacy or legal evidence blocks release at the explicit release gate without making approved implementation behavior incomplete.
- Slice 07 may consume the final capability only after its own requirements, design, tasks, and capability edge are changed through `update-spec`.

## Acceptance Criteria

- [AC-01] Given assessment, cache, profile, pilot, readiness, and disclosure records in either authoritative storage mode, when privacy and security proof runs, then raw source and the scan index remain worker-local, authoritative data is minimized and project-scoped, access and lifecycle controls apply, sensitive logs are redacted, and no analytics or secondary use exists.
- [AC-02] Given the exact approved profile and pilot, when managed-runtime compatibility is verified, then one deterministic allowlisted value references the authoritative pilot specification and revision, is available only after all required proof passes, and creates or changes no specification document or repository file.

## Open Questions

- None.
