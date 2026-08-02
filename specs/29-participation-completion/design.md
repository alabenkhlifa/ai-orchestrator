# Participation Completion Design

## Context

The legacy Slice 08 plan delivered its invitation, authorization, notification, and departure foundation before its remaining privacy outcomes were split into focused child specifications. Downstream specifications consume the final participation-governance capability and need one authoritative readiness decision rather than interpreting multiple task files independently.

## Proposed Approach

Add one coordination task that resolves the ready foundation and each focused continuation capability through the specification graph. Validate the named provider task, successful focused proof receipt, readiness write-back, and stable contract identity without rerunning provider task proofs.

After provider reconciliation, run the complete Slice 08 deterministic repository, browser, security, dependency, and production-build checks through slice scope. Record product, design, implementation, local-verification, and release readiness separately, and publish the governance capability only after the deterministic gate succeeds.

## Components Affected

- Cross-specification capability and proof-receipt reconciliation.
- Participation provider compatibility fixtures.
- Slice-scoped Mix, browser, security, dependency, assets, and release-build proof.
- Participation readiness and blocker reporting.
- Downstream governance capability publication.

## Data and Access Boundaries

- No application data entity is introduced. Completion records only specification capability identity, provider task state, proof receipt, compatibility result, and staged readiness.

Required boundaries:

- Provider specifications remain authoritative for their application code, data, lifecycle, and focused proof.
- Completion cannot mark a provider ready without its named completed task, matching receipt, and readiness write-back.
- Reconciliation does not authorize an additional provider task-proof run or mutate provider-owned data.
- Deployment evidence references remain protected and release-only; no secret or personal-data body enters the readiness record.

## Interfaces

- Provider registry interface: resolve each required capability to exactly one specification and task.
- Proof receipt interface: match provider task, proof scope, command identity, exit status, and readiness write-back.
- Compatibility interface: exercise deterministic contracts between the participation foundation and focused continuation providers.
- Readiness interface: report the earliest blocked stage and publish governance exactly once after the gate.

## Decisions and Tradeoffs

### One Final Coordination Provider

- Choice: Publish `capability:project-participation-governance` only from this completion specification.
- Reason: Downstream consumers need one stable readiness edge, while implementation authority remains distributed across focused providers.
- Consequence: Completion waits for every required provider but owns no duplicate application implementation.

### Reconcile Focused Proof Instead Of Repeating It

- Choice: Validate each provider's task receipt and readiness write-back, then run the complete gate once through slice scope.
- Reason: Repeating focused proofs during integration wastes time and weakens the distinction between provider ownership and reconciliation.
- Consequence: A missing or stale receipt blocks completion even if code appears present.

### Staged Readiness

- Choice: Record local-verification readiness independently from deployment release evidence.
- Reason: Vendor, region, transfer, live enforcement, notice, incident, and accountable-review facts cannot be established by deterministic local tests.
- Consequence: Governance implementation may be locally verified while release remains explicitly blocked.

## Risks

- A stale provider reference could publish governance for the wrong contract. Require exact capability, specification, task, receipt, and readiness identity.
- A full gate could be used to hide missing focused proof. Reject incomplete providers before running the slice gate.
- Release status could be overstated from local tests. Keep deployment evidence as a separate explicit gate.

## Open Questions

- None.
