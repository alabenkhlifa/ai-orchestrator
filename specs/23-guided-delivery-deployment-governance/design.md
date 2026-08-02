# Guided Delivery Deployment Governance Design

## Context

The guided-delivery product contract fixes purposes, prohibited uses, access boundaries, maximum retention, deletion, rights, and no-analytics behavior. Actual controllers, vendors, regions, transfers, provider settings, notices, and live enforcement evidence vary by deployment and should not block implementation when the technical contract is already approved. They must still be explicit before release.

## Proposed Approach

Extend the deployment inventory with a versioned `DeploymentPrivacyProfile` containing allowlisted configuration and evidence references for each guided-delivery destination. Validate completeness by processing category and classify every missing field at implementation, local-verification, or release readiness, with deployment-specific evidence normally assigned to release.

Bind the participant-facing start disclosure to the profile version and material-boundary digest. A changed worker, model, preview, artifact, hosting, backup, region, transfer, retention, or training-use boundary invalidates the prior confirmation. The profile stores only configuration facts, review states, and protected evidence references, never secrets or project content.

## Components Affected

- Deployment processing inventory and privacy-profile configuration.
- Worker, model, preview, artifact, hosting, backup, support, and deletion destination registry.
- Start-disclosure profile-version linkage.
- Deployment readiness classifier and evidence validator.
- Privacy, security, legal, and accountable approval records.

## Data and Access Boundaries

- `DeploymentPrivacyProfile`: one immutable versioned deployment record containing controller and contact state, configured processing destinations, purposes, data categories, processors or recipients, regions, transfers and safeguards, retention and training-use settings, support and incident boundaries, deletion enforcement state, notice and review state, and protected evidence references.

Required boundaries:

- Only authorized deployment operators and reviewers can mutate or inspect non-public profile evidence.
- Participant disclosure exposes only the approved processing summary, not contracts, internal evidence, support details, credentials, or secrets.
- Evidence references resolve through the deployment's protected evidence store and do not embed personal data or project content in the profile.
- The profile consumes technical-control readiness from provider capabilities and does not implement those controls again.
- Unknown or not-applicable values require an explicit reason and reviewer-visible state.
- A material profile change creates a new version and invalidates only disclosures bound to the earlier digest.

## Interfaces

- Deployment-profile interface: create and version allowlisted controller, processor, destination, region, transfer, retention, training-use, support, incident, deletion, notice, and review fields.
- Processing-destination registry: enumerate the configured guided-delivery boundaries and consume the owning technical-control capability for each category.
- Start-disclosure interface: derive the participant-visible summary and material-boundary digest from the exact profile version.
- Readiness interface: return separate implementation, deterministic local-verification, and release states with missing evidence and earliest blocking stage.
- Review-evidence interface: attach protected references and record privacy, security, legal or DPIA, and accountable approval outcomes without copying source evidence into the profile.

## Decisions and Tradeoffs

### Deployment Facts Stay In A Release Profile

- Choice: Store deployment-variable facts and evidence in `DeploymentPrivacyProfile` while keeping stable product and technical rules in their owning specifications.
- Reason: Vendor, region, transfer, and controller facts cannot be truthfully fixed in reusable implementation code.
- Consequence: One implementation can be locally verified before a particular deployment is releasable, and every deployment must complete its own profile.

### Material Changes Invalidate Disclosure Confirmation

- Choice: Bind confirmation to a profile-version digest and invalidate it only for material processing-boundary changes.
- Reason: Participants need informed confirmation when processing changes, not repetitive prompts for unrelated configuration edits.
- Consequence: The profile classifier must distinguish material processing fields from evidence-only updates.

### Evidence References Instead Of Evidence Copies

- Choice: Store protected evidence references and review state, not uploaded contracts or personal-data samples in the profile itself.
- Reason: Duplicating evidence expands access, retention, and deletion obligations.
- Consequence: Release validation must fail closed when a required protected reference is unavailable or stale.

## Risks

- An incomplete destination registry may hide a processor. Reconcile configured runtime adapters against the profile before release.
- A setting may drift after review. Bind evidence to profile versions and re-open affected release gates on material change.
- Operators may mistake local verification for legal approval. Present readiness stages separately and require accountable release approval.

## Open Questions

- None.
