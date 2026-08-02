# Guided Delivery Completion Design

## Context

Slice 07 remains the shared end-to-end product agreement and completed delivery foundation. Focused continuation specifications own notification access, processing controls, operational and device retention, deletion and recovery, rights and anonymization, and deployment governance. Making Slice 07 require its own consumers would create a capability cycle, while letting any one continuation publish the overall feature would give it authority over unrelated contracts.

## Proposed Approach

Create a coordination-only specification at the end of the directed capability graph. Its single task reads provider readiness and compatibility fixtures without changing provider data or behavior. The slice verification gate runs the complete deterministic repository, browser, security, dependency, production-build, and integration matrix after every provider is ready.

Record implementation, local-verification, and release readiness separately. Publish `capability:guided-specification-delivery` only after the single coordination task has a focused proof receipt and the full slice verification gate passes; deployment-specific evidence remains visible at the release gate.

## Components Affected

- Global cross-specification capability graph.
- Guided-delivery provider-readiness registry and progress write-backs.
- Cross-provider compatibility fixtures.
- Repository quality, security, dependency, browser, production-build, and integration proof orchestration.
- Downstream guided-delivery capability consumers.

## Data and Access Boundaries

No new stored entity is introduced. This specification reads specification metadata, proof receipts, readiness write-backs, and deterministic test results. It does not read or copy project content, personal data, credentials, artifacts, prompts, outputs, or deployment evidence bodies.

Required boundaries:

- Each provider remains the sole authority for its capability and implementation data.
- Readiness input is limited to provider reference, task state, proof receipt identity, contract version or digest, verification state, and blocker stage.
- Full tests use deterministic fixtures and the already-approved development privacy boundary.
- Release evidence is referenced only by readiness state and remains protected by deployment governance.
- A coordination failure changes no provider state and cannot mark a provider ready.

## Interfaces

- Provider-readiness interface: resolve one exact provider task, completion state, accepted proof receipt, readiness write-back, and contract identity for every required capability.
- Compatibility interface: run deterministic fixtures across foundation, notification, processing, retention, deletion, rights, and deployment-governance seams.
- Verification interface: execute the canonical repository, browser, security, dependency, production-build, and deterministic integration matrix through slice scope.
- Readiness interface: record separate implementation, local-verification, and release states with the earliest blocking provider or release gate.
- Final capability interface: publish one `capability:guided-specification-delivery` readiness record for downstream consumers only after all required proof succeeds.

## Decisions and Tradeoffs

### Separate Completion Node

- Choice: Publish the final capability from a coordination-only specification after the foundation and all focused continuations.
- Reason: The directed graph stays acyclic and no topic-specific continuation gains authority over unrelated providers.
- Consequence: Downstream consumers wait for one additional focused readiness task and verification gate, while provider work remains independently implementable and reviewable.

### Focused Coordination Task And Broad Slice Gate

- Choice: Keep provider-resolution and readiness-write-back proof focused in Task 1, and run full repository, browser, security, dependency, production, and integration checks only at the slice gate.
- Reason: Task proof should verify the coordination invariant without disguising repository-wide proof as a focused task command.
- Consequence: Final publication requires both the task receipt and the separately recorded slice-gate evidence.

### Independent Release Readiness

- Choice: Allow implementation and deterministic local verification to become ready while deployment-specific evidence remains release-blocked.
- Reason: Controller, vendor, transfer, notice, and accountable approval facts vary by deployment and do not change the approved implementation contract.
- Consequence: The final capability can describe local product readiness without authorizing a production release whose release gate is incomplete.

## Risks

- A stale readiness write-back may publish an incompatible contract. Bind compatibility fixtures and readiness to exact provider references and contract identities.
- A broad gate may be run as routine task proof. Enforce focused Task 1 receipts and slice-scoped full commands.
- Downstream specs may retain the legacy Slice 07 provider edge. Validate the global graph and require this specification as the sole provider.

## Open Questions

- None.
