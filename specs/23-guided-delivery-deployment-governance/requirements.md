# Guided Delivery Deployment Governance

## Status

Approved

## Outcome

Each deployment can describe and validate the actual guided-delivery controller, processors, regions, transfers, retention and training-use settings, support and incident boundaries, deletion enforcement, notices, and accountable review evidence without turning deployment-specific unknowns into implementation blockers.

## Users

- Operators configuring a hosted or device-enabled SDD Orchestrator deployment.
- Privacy, security, and legal reviewers evaluating the actual processing boundary.
- Project participants reading the processing disclosure before a guided-delivery run starts.

## In Scope

- One local deployment privacy profile for guided-delivery services and destinations.
- Configured worker, model, preview, artifact, hosting, backup, support, and deletion processor records.
- Regions, transfers, safeguards, retention, model-training use, and incident-boundary configuration.
- Linkage between the configured profile and the start-time processing disclosure.
- Validation that implementation and local-verification readiness remain separate from release evidence.
- Release-gate checks for controller details, notices, enforced deletion, DPIA or legal review, and final accountable approval.

## Out of Scope

- Selecting vendors, negotiating contracts, or determining legal conclusions for the operator.
- Implementing the underlying processing, retention, deletion, or rights controls owned by focused provider specifications.
- Publishing the final `capability:guided-specification-delivery`, which belongs to completion coordination.
- Production deployment, release execution, or incident response itself.

## Primary Workflow

1. An authorized operator creates or updates the deployment's guided-delivery privacy profile.
2. The profile identifies every configured processing destination, region, transfer, safeguard, retention and training-use setting, support path, incident boundary, and deletion mechanism.
3. The product derives the participant-facing start disclosure from the matching current profile version.
4. Validation reports implementation, local verification, and release readiness separately and names missing deployment evidence at the release stage.
5. Privacy, security, and accountable reviewers attach the required deployment evidence before release approval.

## Business Rules

- `DeploymentPrivacyProfile` is deployment configuration and evidence, not a substitute for runtime technical controls.
- Every configured worker, model, preview, artifact, hosting, backup, support, cache, index, notification, and deletion processor or recipient is listed with purpose and data categories.
- Regions, international transfers, safeguards, retention, model-training use, support access, incident handling, and deletion enforcement are explicit; unknown is a visible value, never inferred as safe.
- The participant-facing start disclosure references the exact current profile version and changes when a material processing boundary changes.
- Missing controller contact, notice, vendor agreement, transfer safeguard, live enforcement evidence, DPIA decision, legal review, or final approval blocks release at the earliest applicable release gate, not implementation or deterministic local verification.
- Secrets, credentials, project content, prompts, output, evidence bytes, and personal-data samples are prohibited from the profile.
- Profile changes are authorized, versioned, auditable, purpose-limited, and excluded from product analytics.

## Acceptance Criteria

- [AC-01] Given an authorized operator configures guided delivery, when the deployment profile is saved, then it records every required configured destination, purpose, data category, region, transfer, safeguard, retention, training-use, support, incident, deletion, notice, review, and evidence state without secrets or project content.
- [AC-02] Given the worker, model, preview, artifact, hosting, backup, support, region, transfer, retention, or training-use boundary changes, when a participant next starts delivery, then the disclosure references the new profile version and requires confirmation before processing.
- [AC-03] Given deployment evidence is incomplete, when readiness is evaluated, then implementation and deterministic local verification remain independently classified, each missing item names its earliest release gate, and release stays blocked until required controller, notice, agreement, transfer, deletion, DPIA or legal, security, and accountable approval evidence is present.

## Open Questions

- None.
