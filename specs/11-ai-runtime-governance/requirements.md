# AI Runtime Governance

## Status

Approved

## Outcome

A user can run a support assistant or working agent through an explicitly selected personal AI connection, live provider-supported model and effort configuration, fail-closed quota and spending controls, and access-safe operational visibility without exposing provider credentials or silently changing the provider, model, or cost boundary.

## Users

- Individual users linking and paying for their own provider connection.
- Users starting support conversations or authorized working-agent runs.
- Project owners and run initiators observing and controlling project agent work.
- Authorized project participants viewing their project run's safe operational state.

## Primary Workflow

1. A user links a personal AI provider through an authenticated worker or official installed client, with the credential retained in the worker or operating-system keychain.
2. The authenticated worker adapter retrieves the live model catalog and current quota facts when the provider supports those operations.
3. If full catalog enumeration is unsupported, the product shows only the authenticated current or default model and its supported effort choices.
4. Before first execution, the user selects an eligible connection, compatible model, and supported effort for the conversation or run.
5. The runtime pins that configuration while allowing the same connection to serve other concurrently authorized conversations or runs.
6. During execution, the product shows each agent's elapsed time, token usage, estimated cost, applicable quota, and status while labelling provider facts and local estimates.
7. A quota or API spending ceiling pauses work with preserved state. Work does not silently fall back or continue into paid usage.
8. Later child integrations may resume after reset, create an explicitly approved linked continuation on another model, or stop work under the owning workflow's authority.

## In Scope

- A provider-neutral personal AI connection contract used by support assistants and working agents.
- One operational OpenAI Codex worker adapter for the first executable slice, using supported official-client account, model, and rate-limit interfaces.
- Worker-local or operating-system-keychain credential custody with opaque control-plane references only.
- Live model-catalog retrieval from an authenticated worker adapter using the provider API Models endpoint or official installed client.
- Safe limited behavior when a provider cannot enumerate a catalog.
- Compatible model and effort selection before the first conversation or run.
- Immutable per-conversation or per-run configuration pinning with concurrent reuse of the same connection.
- Connection-owned arbitrary general and model-specific quota buckets, reset times, and paid-continuation facts.
- Explicit opt-in for scarce, model-specific quota or paid continuation.
- No silent model or connection fallback and no silent paid continuation.
- Personal API run spending ceilings that pause at the configured limit.
- Live per-agent operational usage with elapsed time, tokens, estimated cost, applicable quota, and status.
- Clear labels separating provider-reported facts from estimates and unknown values.
- Connection-owner account-wide visibility and access-safe project-participant projections.
- A required personal provider connection with no hidden Orchestrator-funded fallback.
- GDPR purpose, minimization, access, retention, deletion, rights, processor, transfer, logging, and no-analytics controls for active-slice runtime data.

## Out of Scope

- Project-shared API connections, project permissions, project budgets, or project-funded per-run ceilings.
- Sharing a personal provider subscription with a project or participant.
- Provider billing, credit purchase, subscription management, or resale.
- Hardcoded model lists or plan-name inference.
- Slice 07 run-state, cancellation, pause, resume, stop, retry, or continuation changes.
- Support-assistant conversation storage or user-interface behavior beyond consuming the shared runtime capabilities.
- Automatic cross-model continuation, automatic fallback, or automatic paid continuation.
- Production provider adapters beyond the first OpenAI Codex adapter.

## Business Rules

- The runtime contract applies equally to support assistants and working agents.
- A personal AI connection is required. SDD Orchestrator supplies no hidden funded provider connection and must not start AI work without an eligible user-controlled connection.
- Personal AI connections default to the individual who linked them. A personal subscription is never made available as a shared project connection.
- A future project owner may configure an optional project-shared API connection with explicit participant permissions, a project budget, and a per-run ceiling.
- When eligible personal and project-shared connections both exist, the user must explicitly choose one before the first run. The runtime must not choose based on price, remaining quota, or prior use.
- Provider credentials, refresh tokens, API keys, and official-client authentication material remain inside the authenticated worker or operating-system keychain. They never enter control-plane, project, specification, comment, activity, evidence, analytics, support, log, backup, or export records.
- The control plane may retain only an opaque connection reference, provider kind, owning account reference, safe availability state, and the minimum configuration and observation data required by the approved workflow.
- Model catalog data comes live from the authenticated worker adapter through the provider API Models endpoint or official installed client. It is never hardcoded and never inferred from a provider plan name.
- Subscription quota must come from a supported deterministic client or provider interface, never from asking the model to describe its own usage. A future Claude Code adapter may use its supported usage or rate-limit surface, including `/usage` when that is the available account interface; output or schema drift produces `Unknown` rather than guessed quota.
- When catalog enumeration is unsupported, the adapter returns only the authenticated current or default model and effort capabilities it can prove. Missing models are not guessed.
- A selected model and effort must be compatible according to the authenticated adapter response. Unknown compatibility fails closed.
- The selected connection, model, effort, catalog provenance, and configuration version are pinned for the conversation or run. Later catalog changes do not silently change active work.
- One connection may be reused by multiple concurrent conversations or runs. Each remains independently pinned, observed, limited, paused, and stopped.
- Quota belongs to the connection and may contain any number of provider-defined general or model-specific buckets, reset times, remaining quantities, scopes, and paid-continuation facts.
- Missing quota, cost, credit, reset, or limit data is `Unknown`; it must not be displayed or evaluated as unlimited, zero, safe, or exhausted.
- Selecting a scarce model, consuming a model-specific quota, or enabling provider-paid continuation requires explicit user opt-in tied to that connection and model.
- The runtime must not silently fall back to another model, effort, or connection when a quota, compatibility, provider, or spending condition prevents continuation.
- The runtime must not silently continue into paid provider usage. Paid continuation starts only after explicit approval by the connection owner.
- A personal API run spending ceiling is a hard runtime boundary. Reaching it pauses work before further chargeable execution and preserves the latest recoverable state.
- Operational usage is shown per agent and includes elapsed time, token usage when available, estimated cost when calculable, applicable quota buckets, and current status.
- Provider-reported values and locally calculated estimates are labelled separately. An estimate must identify its basis and must not be presented as a provider invoice or exact account charge.
- Exact account-wide quotas, credits, and spend are visible only to the connection owner.
- A current authorized project participant may see the project's own run usage, the selected model and effort, and a safe availability state such as available, constrained, paused, or unknown. They cannot see unrelated account-wide quota, credits, spend, or another project's usage.
- Quota exhaustion and spending-ceiling events are resumable pause reasons, not terminal failures. The runtime preserves the pinned configuration, checkpoint reference, and observation history.
- Resume after quota reset and an explicitly approved linked continuation on a different model are later workflow integrations. Neither may overwrite the original run's configuration or history.
- Stop is terminal. Slice 07 integration must retain its approved rule that only the current run initiator or project owner may stop an active guided-delivery run.
- Runtime configuration, usage, quota, cost, and observation data is personal or confidential project data. It is processed only to provide the requested AI runtime, safety controls, support, and project delivery.
- Runtime data must not be reused for advertising, model training, unrelated product improvement, or product analytics. Operational logs are minimized governed data, not anonymous analytics.
- Personal connection removal ends new execution immediately, revokes the opaque reference, removes worker-local credentials through the owning adapter, and leaves governed historical run configuration and minimized usage only as long as required for project accountability, rights handling, or approved legal obligations.

## Acceptance Criteria

- [AC-01] Given a user links a personal provider, including the first operational OpenAI Codex adapter, when the connection becomes available, then credentials remain worker or keychain-local, the control plane receives only an opaque minimum reference, and no AI work can use an Orchestrator-funded fallback.
- [AC-02] Given an authenticated provider supports catalog enumeration, including the first operational Codex adapter, when models are requested, then the worker adapter returns the live provider or official-client catalog with compatibility provenance and no hardcoded or plan-inferred entry.
- [AC-03] Given catalog enumeration is unsupported or compatibility is unknown, when selection is presented, then only the proven current or default model and supported effort choices are selectable and unproven choices fail closed.
- [AC-04] Given a connection reports general, model-specific, reset, credit, or paid-continuation quota facts through a supported deterministic account interface, when quota is normalized, then every provider-defined bucket remains independently represented and missing facts remain unknown rather than unlimited.
- [AC-05] Given a scarce model, model-specific quota, fallback opportunity, or paid continuation is encountered, when execution is evaluated, then work proceeds only after the required explicit opt-in and never silently changes model, effort, connection, or cost boundary.
- [AC-06] Given a personal API run reaches its spending ceiling, when the next chargeable operation is evaluated, then execution pauses before exceeding the ceiling and preserves the recoverable runtime state.
- [AC-07] Given a user starts a support conversation or working-agent run, when execution begins, then one eligible connection, compatible model, supported effort, catalog provenance, and configuration version are pinned while the same connection remains reusable by other independently pinned work.
- [AC-08] Given eligible personal and project-shared connections both exist, when a user's first run is prepared, then the user explicitly selects the connection and no personal subscription becomes shared project capacity.
- [AC-09] Given one or more agents are active, when their operational state is viewed, then each agent shows elapsed time, tokens when available, estimated cost when calculable, applicable quota, and status with provider facts, estimates, and unknown values labelled distinctly.
- [AC-10] Given quota exhaustion or a spending ceiling pauses work, when runtime state is inspected, then the pinned configuration, latest recoverable checkpoint reference, usage, and pause reason remain available for an authorized later resume or linked continuation.
- [AC-11] Given an active guided-delivery agent is stopped, when authorization and lifecycle handling run, then only the current run initiator or project owner may stop it and the terminal outcome follows Slice 07 cancellation semantics without being represented as a resumable pause.
- [AC-12] Given a project owner configures shared AI capacity, when the connection is used, then it is an explicit API connection with participant permissions, project budget, and per-run ceiling, and it never exposes or shares a personal subscription.
- [AC-13] Given a connection owner and another authorized project participant view the same project run, when usage and availability are projected, then the owner may see exact account-wide quota, credits, and spend while the participant sees only project-run usage and a safe availability state.
- [AC-14] Given support-assistant and working-agent consumers use the runtime, when their pinned configurations are compared, then both follow the same connection, model, effort, compatibility, quota, fallback, and paid-continuation rules.
- [AC-15] Given connection, catalog, quota, configuration, usage, cost, observation, logs, caches, backups, deletion, and rights paths are inspected, when privacy and security verification runs, then credentials remain local, access is purpose-limited, retention is enforced, provider data is minimized, and no product analytics or secondary use exists.

## Open Questions

- None.
