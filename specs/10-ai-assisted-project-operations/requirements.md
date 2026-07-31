# AI-Assisted Project Operations

## Status

Approved

## Outcome

Users can adopt SDD in empty or mature repositories, ask a grounded private project assistant for help, and run support or working agents through one coherent user-controlled AI runtime, while focused child specifications own each independently executable capability.

## Users

- Project owners configuring how AI may operate for a project.
- Project participants starting, observing, or controlling authorized agent work.
- Users working with a support assistant outside a project delivery run.
- Connection owners responsible for provider credentials, quotas, credits, and API spending.

## Primary Workflow

1. A user connects an eligible personal AI provider through the approved worker-local credential boundary.
2. A project participant may ask the private project assistant for current, cited, permission-bounded answers.
3. A project owner may adopt managed SDD for a mature repository or initialize an empty repository without being forced to install permanent repository files.
4. A support conversation or project run chooses an available connection, compatible model, and supported effort level before first execution.
5. The runtime pins that choice and exposes live status and usage while quota, paid-continuation, and spending controls prevent silent boundary changes.
6. Authorized users continue through the assistant, adoption, or working-agent lifecycle owned by the applicable child specification.

## In Scope

- Coordination of personal and project-shared AI connection behavior.
- One shared runtime-session contract for support assistants and working agents.
- One shared runtime-observation contract for status, usage, quota, and cost presentation.
- Coordination with the focused read-only project-assistant capability.
- Coordination with the SDD-adoption umbrella for mature-repository profiling, optional permanent integration, and empty-repository initialization.
- Consistent connection, model, effort, quota, spending, fallback, pause, resume, stop, and visibility rules across child specifications.
- Capability dependencies and integration boundaries for guided delivery and later AI-assisted project workflows.
- GDPR data protection and lifecycle coordination for provider-account, connection, runtime, usage, cost, and quota data.

## Out of Scope

- Implementing provider adapters, credentials, model catalogs, quota normalization, runtime sessions, or operational views in this umbrella.
- Implementing project-assistant conversations, repository observation, citations, or privacy lifecycle in this umbrella.
- Implementing repository assessment, permanent kit integration, or empty-repository initialization in this umbrella.
- Implementing project-shared API connections, permissions, budgets, or per-run ceilings in this umbrella.
- Changing Slice 07 run, cancellation, authorization, or persistence behavior in this specification.
- Provider billing, subscription management, credit purchase, or resale.
- An Orchestrator-funded fallback connection.

## Business Rules

- This specification coordinates focused child specifications and does not own an implementation data model, adapter, page, worker command, or runtime transition.
- Support assistants and working agents must consume the same runtime-session and runtime-observation capabilities rather than defining incompatible connection, model, effort, quota, cost, or status meanings.
- The project assistant must remain project-scoped, private, source-grounded, read-only in its first slice, and bounded by current project and repository permissions.
- SDD adoption must support managed runtime operation without mandatory repository mutation, keep permanent kit installation optional, and preserve the shared project-specification store as the sole specification authority.
- A personal AI connection is the default connection type and remains owned by the individual who linked it.
- A project owner may later offer an optional project-shared API connection under explicit project permissions, a project budget, and a per-run ceiling.
- Personal subscriptions are never shared with a project or another participant.
- When both an eligible personal connection and a project-shared connection are available, the user must explicitly choose the connection before the first run.
- Provider credentials remain inside the approved worker or operating-system keychain boundary and never enter control-plane, project, specification, comment, activity, evidence, analytics, or export records.
- Model availability comes from a live authenticated worker adapter using the provider API Models endpoint or the official installed client. A child specification must not hardcode models or infer model access from a subscription name or plan.
- A provider that cannot enumerate its catalog may expose only its authenticated current or default model and supported effort choices; missing catalog data must not be expanded by guesswork.
- Model-specific scarcity, quota, or paid continuation requires explicit user consent. No child workflow may silently fall back to another model or connection or silently continue into paid usage.
- Provider quota belongs to the selected connection. Exact account-wide quotas, credits, and spend remain visible only to the connection owner.
- Authorized project participants may see their project run's usage and a safe availability result, but not the connection owner's unrelated account-wide provider facts.
- The runtime must distinguish provider-reported facts from local estimates and must represent missing quota or cost data as unknown, never unlimited or zero.
- Pause is resumable and stop is terminal. A guided-delivery integration must preserve Slice 07's existing rule that only the current run initiator or project owner may stop an active run.
- Slice 07 must be changed through `update-spec` before it consumes pause, stop, continuation, runtime-session, or runtime-observation behavior defined by a child specification.
- No support assistant or working agent may start without an eligible user-controlled provider connection. There is no hidden Orchestrator-funded fallback.

## Acceptance Criteria

- [AC-01] Given the runtime, project assistant, and SDD-adoption children are available, when their contracts are inspected, then the assistant and working agents consume the shared runtime capabilities, adoption remains optional and source-of-truth safe, and each workflow retains its own authorization, data, and lifecycle rules.
- [AC-02] Given personal and future project-shared connection workflows are specified, when their ownership and funding boundaries are compared, then personal subscriptions remain individual, shared project use is limited to an explicit API connection with project controls, and no hidden Orchestrator-funded fallback exists.
- [AC-03] Given a child capability would change Slice 07 pause, stop, continuation, configuration, or visibility behavior, when integration is planned, then an approved `update-spec` records the dependency and preserves the existing initiator-or-owner stop authority before implementation begins.

## Open Questions

- None.
