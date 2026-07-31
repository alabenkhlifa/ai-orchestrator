# SDD Adoption Coordination Design

## Context

SDD adoption spans three materially different workflows. A mature repository needs bounded read-only assessment before autonomous execution. A permanent kit changes repository files and introduces a software-supply-chain boundary. A genuinely empty repository needs product and technical discovery before a working agent can create its first valid foundation.

Combining those workflows would hide meaningful authorization decisions and require unrelated proof gates. This specification is therefore a nested coordination umbrella whose children own implementation.

## Proposed Approach

Route repositories by observable eligibility while preserving one common SDD contract. Managed runs consume authoritative complete specification revisions and versioned runtime skills without requiring repository mutation. Mature repositories first establish an approved execution profile. Permanent kit integration is offered separately after a pilot proves the managed path. Empty repositories use a dedicated initialization workflow that establishes a valid Git and project foundation before ordinary onboarding and delivery.

The umbrella validates capability edges, shared terminology, source-of-truth rules, readiness presentation, and combined release evidence. It owns no repository command, mutation, persistence adapter, UI page, or worker protocol.

## Components Affected

- Adoption entry routing and cross-child release checklist.
- Cross-specification capability graph.
- Shared readiness terminology.
- Shared source-of-truth and trust-boundary rules.

## Data and Access Boundaries

No umbrella-owned data entity is introduced.

Required boundaries:

- Child workflows retain their own authoritative data, authorization, retention, deletion, and verification contracts.
- The umbrella may evaluate capability readiness and release evidence but must not copy repository content, specification content, execution profiles, kit files, or initialization artifacts.
- Specification documents remain authoritative only through `capability:project-specification-store`.

## Interfaces

- Adoption routing contract: classify an eligible repository into mature-repository assessment or empty-repository initialization without performing either workflow.
- Child readiness contract: receive separate assistant, specification, agent-execution, and release readiness states with reasons and owning child capability.
- Release coordination contract: verify capability readiness, shared source-of-truth rules, and required cross-child browser and security evidence.

## Decisions and Tradeoffs

### Umbrella With Focused Children

- Choice: Coordinate three child specifications rather than implement one broad adoption slice.
- Reason: Read-only assessment, repository mutation, and empty-repository creation have independent outcomes, trust boundaries, and proof.
- Consequence: Capability dependencies, not slice numbers, determine implementation order.

### Managed Runtime Is The Default

- Choice: Define uniform SDD behavior through authoritative revisions and managed runtime skills instead of mandatory repository installation.
- Reason: Users should receive autonomous Orchestrator execution without accepting external files in their repository.
- Consequence: Permanent kit integration remains optional and direct agents outside Orchestrator have only the capabilities exposed by that reviewed kit and its authorized Orchestrator connection.

### Separate Readiness Axes

- Choice: Present assistant, specification, agent-execution, and release readiness independently.
- Reason: A repository conflict may prevent autonomous execution while still allowing safe read-only project questions, and a deployment decision may block release without blocking local implementation.
- Consequence: No child may replace the four states with one readiness score.

## Risks

- The umbrella may accumulate child behavior and become another implementation specification. Keep all implementation ownership in the children.
- A release view may hide the earliest blocking child. Preserve capability-specific status and reasons.
- Similar terminology may conceal different trust boundaries. Require each child to expose its exact processing and mutation boundary.

## Open Questions

- None.
