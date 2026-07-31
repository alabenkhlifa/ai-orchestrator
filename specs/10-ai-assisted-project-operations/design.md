# AI-Assisted Project Operations Design

## Context

AI-assisted project operations span provider connections, model discovery, quota and spending controls, private grounded project questions, repository adoption, empty-repository initialization, guided feature delivery, live runtime visibility, and agent lifecycle actions. These outcomes have independent trust boundaries and verification paths. Keeping them in one implementation slice would mix provider-account security, private conversation data, repository mutation, worker adapters, project funding, and Slice 07 orchestration changes.

## Proposed Approach

Use this specification as a coordination-only umbrella. The runtime-governance child owns personal connection, catalog, quota, pinned-session, and observation foundations. The project-assistant child owns private grounded read-only questions. The nested SDD-adoption umbrella coordinates mature-repository profiling, optional kit integration, and empty-repository initialization. Later focused specifications own project-shared API funding, confirmed assistant mutations, and guided-delivery runtime control.

The umbrella records invariant behavior, capability ownership, and sequencing. It defines no persistence model and duplicates no child implementation task. A coordination verification task runs only after the child runtime capabilities are ready and confirms that every later consumer uses those contracts without redefining their authority or lifecycle.

## Components Affected

- `specs/11-ai-runtime-governance/` as the shared runtime child.
- `specs/12-project-assistant/` as the private read-only assistant child.
- `specs/13-sdd-adoption/` as the nested repository-adoption umbrella.
- A future project-shared AI connection and budget child specification.
- A future confirmed assistant-action child specification.
- `specs/07-guided-specification-delivery/` through a future `update-spec` workflow.
- Cross-specification capability validation and release coordination.

## Data and Access Boundaries

- Personal provider credentials and account-wide provider facts remain inside the connection owner's approved worker-local boundary.
- Project participants receive only project-run usage and a safe availability result authorized by the owning project workflow.
- Private assistant conversations remain visible only to their participant and project, while repository source observation remains inside the acting participant's authorized worker boundary.
- Adoption profiles, kit records, and initialization records follow their child storage boundaries and never create a second authoritative specification store.
- Shared project API funding, permissions, budgets, and ceilings belong to a later focused child and cannot redefine personal connection ownership.
- Guided-delivery run state, stop authority, cancellation, branch, workspace, and continuation remain owned by Slice 07 until an approved `update-spec` changes that agreement.
- This umbrella stores no provider credential, connection, catalog, quota, runtime, usage, cost, or lifecycle record.

## Interfaces

- `capability:ai-runtime-session` supplies the selected connection, model, effort, and immutable per-conversation or per-run configuration reference.
- `capability:ai-runtime-observation` supplies provider-labelled facts, local estimates, usage, quota, cost, elapsed time, and current runtime status with access-safe projections.
- `capability:ai-runtime-governance` supplies the approved privacy, lifecycle, security, and no-secondary-use runtime boundary.
- `capability:read-only-project-assistant` supplies private cited project questions without mutations or permission expansion.
- `capability:sdd-adoption-coordination` supplies the reconciled mature, permanent-kit, and empty-repository adoption contract.
- A future project-shared funding capability will extend eligible connection choices without changing the personal runtime-session contract.
- Slice 07 will require an explicit `update-spec` before consuming either runtime capability or adding quota pause, resume, stop, or linked continuation behavior.

## Decisions and Tradeoffs

### Coordination Umbrella With Focused Children

- Choice: Keep this specification coordination-only and give independently executable runtime, assistant, adoption, project-funding, and delivery integrations their own specifications.
- Reason: Provider credentials, private conversations, repository mutation, project budgets, and guided-delivery run transitions have separate actors, trust boundaries, and verification gates.
- Consequence: The complete product outcome is delivered through capability edges and coordinated release checks rather than one implementation slice.

### Shared Runtime Vocabulary

- Choice: Require support assistants and working agents to consume the same runtime-session and runtime-observation contracts.
- Reason: Connection, model, quota, usage, cost, and status must mean the same thing wherever the user encounters AI work.
- Consequence: Consumer workflows may add authorization or presentation rules but cannot redefine runtime authority or provider facts.

### Existing Workflow Authority Remains Intact

- Choice: Treat Slice 07 as an external lifecycle owner and require `update-spec` before runtime pause, stop, or continuation integration.
- Reason: A new umbrella cannot silently replace approved cancellation, run, branch, workspace, or authorization behavior.
- Consequence: The runtime child may expose provider-neutral states and commands, but Slice 07 integration remains deferred until its agreement is updated.

## Risks

- A consumer may copy runtime fields and create a second source of truth. Enforce capability consumption and reject duplicate connection, catalog, quota, or observation authority in specification review.
- An assistant or adoption child may create another specification or source authority. Require the shared store and reject repository synchronization or copied project specifications.
- Project funding may accidentally expose personal subscription or account-wide quota data. Keep shared API funding in a separate child with explicit ownership and projection tests.
- Pause and stop terminology may drift from Slice 07 cancellation semantics. Require `update-spec` before implementation and verify the initiator-or-owner authority remains intact.
- An umbrella may become a hidden implementation backlog. Keep one coordination task only and route every executable surface to a focused child or nested child.

## Open Questions

- None.
