# AI Runtime Governance

## Status

Approved

## Outcome

A user can link one or more labelled personal AI connections through an authorized paired local worker, inspect live provider-supported model, effort, and quota facts, and make a fail-closed pinned runtime configuration available to support-assistant and working-agent consumers without exposing provider credentials or silently changing the provider, model, or cost boundary.

## Users

- Individual users linking, labelling, selecting, and paying for their own provider connections.
- Users starting support conversations or authorized working-agent runs.
- Project owners and run initiators observing and controlling project agent work.
- Authorized project participants viewing their project run's safe operational state.

## Primary Workflow

1. A signed-in user authorizes one already paired local worker and creates a user-labelled personal AI connection bound to one worker-local Codex profile.
2. ChatGPT login or API-key entry occurs through the local worker and Codex client boundary. No credential crosses the control-plane or browser application boundary.
3. The worker retrieves the live authenticated model catalog and current quota facts through a compatible version of the official Codex App Server interface.
4. The account-level AI Connections screen shows safe connection availability, proven models and effort choices, and quota facts without provider email, account ID, plan detail, credential, or raw diagnostic text.
5. Before first execution, a consuming workflow supplies an eligible connection, compatible model, supported effort, required opt-ins, and any API-key spending ceiling.
6. The runtime pins that configuration while allowing the same connection to serve other concurrently authorized conversations or runs.
7. Before each API-key turn, the runtime atomically reserves a conservative maximum cost from a versioned official-price snapshot. It pauses before launch when the remaining ceiling cannot cover the reservation and reconciles the reservation against observed usage afterward.
8. Runtime observation contracts expose ordered usage and status facts to authorized consumers. Slice 07 and Slice 12 own their eventual per-agent presentation surfaces.
9. Later child integrations may resume after reset, create an explicitly approved linked continuation on another model, or stop work under the owning workflow's authority.

## In Scope

- A provider-neutral personal AI connection contract used by support assistants and working agents.
- Multiple account-owned personal connections, each bound to one authorized paired local worker, one worker-local Codex profile, and one account-scoped user label.
- One account-level AI Connections workflow for local-worker selection, ChatGPT or API-key setup, safe availability, live catalog and quota inspection, rename, and revocation.
- One authenticated personal-worker RPC transport that is separate from Slice 07's project-scoped run gateway.
- One operational OpenAI Codex worker adapter over local App Server standard input and output, using version-matched generated schemas and documented account, model, rate-limit, usage, and token-observation interfaces.
- Worker-local or operating-system-keychain credential custody with opaque control-plane references only.
- Live model-catalog retrieval from an authenticated worker adapter using the provider API Models endpoint or official installed client.
- Safe limited behavior when a provider cannot enumerate a catalog.
- Compatible model and effort selection before the first conversation or run.
- Immutable per-conversation or per-run configuration pinning with concurrent reuse of the same connection.
- Connection-owned arbitrary general and model-specific quota buckets, reset times, and paid-continuation facts.
- Explicit opt-in for scarce, model-specific quota or paid continuation.
- No silent model or connection fallback and no silent paid continuation.
- Personal API run spending ceilings enforced through conservative pre-turn reservation and observed-cost reconciliation.
- A versioned official-price snapshot and per-session cost ledger for strict API-key ceiling enforcement.
- Live per-agent operational usage with elapsed time, tokens, estimated cost, applicable quota, and status.
- Clear labels separating provider-reported facts from estimates and unknown values.
- Connection-owner account-wide and current-participant-safe runtime projections for later consumer-owned presentation.
- A required personal provider connection with no hidden Orchestrator-funded fallback.
- GDPR purpose, minimization, access, retention, deletion, rights, processor, transfer, logging, and no-analytics controls for active-slice runtime data.

## Out of Scope

- Remote, cloud-hosted, Linux, or Windows worker provider setup and credential custody.
- Project-shared API connections, project permissions, project budgets, or project-funded per-run ceilings.
- Sharing a personal provider subscription with a project or participant.
- Provider billing, credit purchase, subscription management, or resale.
- Hardcoded model lists or plan-name inference.
- Slice 07 run-state, cancellation, pause, resume, stop, retry, or continuation changes.
- Support-assistant conversation storage or user-interface behavior beyond consuming the shared runtime capabilities.
- Per-agent runtime presentation inside Slice 07 or Slice 12 user interfaces.
- Automatic cross-model continuation, automatic fallback, or automatic paid continuation.
- Production provider adapters beyond the first OpenAI Codex adapter.
- Officially free provider models under an API-key spending ceiling. A proven-free price is not yet distinguishable from an unknown one, so a zero unit price is refused. Support for free models is a later extension.

## Business Rules

- The runtime contract applies equally to support assistants and working agents.
- A personal AI connection is required. SDD Orchestrator supplies no hidden funded provider connection and must not start AI work without an eligible user-controlled connection.
- The first executable slice accepts only a currently authorized paired local worker. Remote or cloud worker provider setup requires a separate approved trust, transport, credential-custody, and deployment contract.
- One account may own multiple personal AI connections. Each connection belongs to exactly one account, paired worker, and worker-local Codex profile and has a trimmed case-insensitively unique label within that account.
- Repeating a link for the same account, worker, and worker-local profile is idempotent. A connection cannot be rebound to another account, worker, or profile; the user revokes it and creates a new connection instead.
- Personal AI connections default to the individual who linked them. A personal subscription is never made available as a shared project connection.
- A future project owner may configure an optional project-shared API connection with explicit participant permissions, a project budget, and a per-run ceiling.
- When eligible personal and project-shared connections both exist, the user must explicitly choose one before the first run. The runtime must not choose based on price, remaining quota, or prior use.
- Provider credentials, refresh tokens, API keys, and official-client authentication material remain inside the authenticated worker or operating-system keychain. They never enter control-plane, project, specification, comment, activity, evidence, analytics, support, log, backup, or export records.
- API-key entry occurs in the local worker-owned interface, never in an SDD Orchestrator web form or control-plane command. Managed ChatGPT browser or device-code login is started and completed by the worker-local Codex client.
- The control plane may retain only the user label, opaque connection reference, provider and authentication mode, owning account and worker references, safe availability state, and the minimum configuration and observation data required by the approved workflow.
- Provider email, raw provider account or workspace ID, plan detail, credential material, authentication tokens, and raw App Server errors remain worker-local and are never projected or persisted by the control plane.
- The Codex adapter uses local standard-input and standard-output transport only. It rejects an unapproved Codex version or generated-schema digest, unsupported or experimental authentication mode, unknown response shape, oversized value, credential-shaped content, timeout, or process failure with a typed unavailable result.
- The initial adapter may use documented managed ChatGPT browser or device-code login and API-key login. It must not use externally supplied ChatGPT tokens or another experimental authentication mode.
- Model catalog data comes live from the authenticated worker adapter through the provider API Models endpoint or official installed client. It is never hardcoded and never inferred from a provider plan name.
- Subscription quota must come from a supported deterministic client or provider interface, never from asking the model to describe its own usage. A future Claude Code adapter may use its supported usage or rate-limit surface, including `/usage` when that is the available account interface; output or schema drift produces `Unknown` rather than guessed quota.
- When catalog enumeration is unsupported, the adapter returns only the authenticated current or default model and effort capabilities it can prove. Missing models are not guessed.
- A selected model and effort must be compatible according to the authenticated adapter response. Unknown compatibility fails closed.
- The selected connection, model, effort, catalog provenance, and configuration version are pinned for the conversation or run. Later catalog changes do not silently change active work.
- One connection may be reused by multiple concurrent conversations or runs. Each remains independently pinned, observed, limited, paused, and stopped.
- Quota belongs to the connection and may contain any number of provider-defined general or model-specific buckets, reset times, remaining quantities, scopes, and paid-continuation facts.
- Missing quota, cost, credit, reset, or limit data is `Unknown`; it must not be displayed or evaluated as unlimited, zero, safe, or exhausted.
- ChatGPT rate-limit and token-activity methods do not imply API-key quota or billing facts. API-key account quota remains unknown unless a separately supported deterministic provider interface supplies it.
- Selecting a scarce model, consuming a model-specific quota, or enabling provider-paid continuation requires explicit user opt-in tied to that connection and model.
- The runtime must not silently fall back to another model, effort, or connection when a quota, compatibility, provider, or spending condition prevents continuation.
- The runtime must not silently continue into paid provider usage. Paid continuation starts only after explicit approval by the connection owner.
- A personal API run spending ceiling is a strict non-exceeding runtime boundary. Before every chargeable turn, the runtime reserves the conservative maximum cost derived from the pinned model, bounded request configuration, and a current versioned official-price snapshot. Missing or stale pricing fails closed. The reservation is atomically reconciled against observed usage, and work pauses before a new turn whenever the remaining ceiling cannot cover its reservation.
- Operational usage contracts expose per-agent elapsed time, token usage when available, estimated cost when calculable, applicable quota buckets, and current status. The consuming Slice 07 or Slice 12 interface owns where and how that projection is shown.
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

- [AC-01] Given a user links one or more personal providers through an authorized paired local worker, including the first operational OpenAI Codex adapter, when a connection becomes available, then each labelled connection remains account, worker, and worker-profile scoped, credentials remain worker or keychain-local, the control plane receives only the approved minimum reference, and no AI work can use an Orchestrator-funded fallback.
- [AC-02] Given an authenticated provider supports catalog enumeration, including the first operational Codex adapter, when models are requested, then the worker adapter returns the live provider or official-client catalog with compatibility provenance and no hardcoded or plan-inferred entry.
- [AC-03] Given catalog enumeration is unsupported or compatibility is unknown, when selection is presented, then only the proven current or default model and supported effort choices are selectable and unproven choices fail closed.
- [AC-04] Given a connection reports general, model-specific, reset, credit, or paid-continuation quota facts through a supported deterministic account interface, when quota is normalized, then every provider-defined bucket remains independently represented and missing facts remain unknown rather than unlimited.
- [AC-05] Given a scarce model, model-specific quota, fallback opportunity, or paid continuation is encountered, when execution is evaluated, then work proceeds only after the required explicit opt-in and never silently changes model, effort, connection, or cost boundary.
- [AC-06] Given a personal API run has a spending ceiling, when the next chargeable turn is evaluated, then an atomic conservative reservation from a current versioned official-price snapshot either fits inside the remaining ceiling or pauses execution before launch; completed usage reconciles the reservation without permitting concurrent turns to over-allocate the ceiling.
- [AC-07] Given a user starts a support conversation or working-agent run, when execution begins, then one eligible connection, compatible model, supported effort, catalog provenance, and configuration version are pinned while the same connection remains reusable by other independently pinned work.
- [AC-08] Given eligible personal and project-shared connections both exist, when a user's first run is prepared, then the user explicitly selects the connection and no personal subscription becomes shared project capacity.
- [AC-09] Given one or more agents are active, when an authorized consumer requests their operational state, then each ordered projection contains elapsed time, tokens when available, estimated cost when calculable, applicable quota, and status with provider facts, estimates, and unknown values labelled distinctly.
- [AC-10] Given quota exhaustion or a spending ceiling pauses work, when runtime state is inspected, then the pinned configuration, latest recoverable checkpoint reference, usage, and pause reason remain available for an authorized later resume or linked continuation.
- [AC-11] Given an active guided-delivery agent is stopped, when authorization and lifecycle handling run, then only the current run initiator or project owner may stop it and the terminal outcome follows Slice 07 cancellation semantics without being represented as a resumable pause.
- [AC-12] Given a project owner configures shared AI capacity, when the connection is used, then it is an explicit API connection with participant permissions, project budget, and per-run ceiling, and it never exposes or shares a personal subscription.
- [AC-13] Given a connection owner and another current authorized project participant request the same project run's runtime projection, then the owner-exact projection may contain account-wide quota, credits, and spend while the participant-safe projection contains only project-run usage and a safe availability state; Slice 07 and Slice 12 remain the owners of their presentation surfaces.
- [AC-14] Given support-assistant and working-agent consumers use the runtime, when their pinned configurations are compared, then both follow the same connection, model, effort, compatibility, quota, fallback, and paid-continuation rules.
- [AC-15] Given connection, catalog, quota, configuration, cost-ledger, usage, observation, logs, caches, backups, deletion, and rights paths are inspected, when privacy and security verification runs, then credentials remain local, access is purpose-limited, retention is enforced, provider data is minimized, and no product analytics or secondary use exists.
- [AC-16] Given a paired local worker opens the personal AI RPC transport, when it authenticates, negotiates capabilities, reconnects, or returns a response, then every request is account and device-workspace scoped, bounded, correlated, replay-safe, and isolated from Slice 07 project-run commands.
- [AC-17] Given a signed-in user opens AI Connections, when they link, label, inspect, rename, or revoke a connection, then the workflow uses only an authorized paired local worker, keeps secret entry and raw provider identity local, shows safe typed availability and corrective actions, and remains usable on supported desktop and mobile layouts.

## Open Questions

- None.
