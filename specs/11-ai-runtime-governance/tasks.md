# AI Runtime Governance Tasks

## Status

In Progress

Tasks 7, 8, 1, 9, 2, 3, 10, 4, and 13 are complete: the personal-worker AI RPC transport, version-checked Codex App Server adapter, account-owned personal AI connection foundation, account-level AI Connections workflow, live model catalog with compatible effort validation, live quota and token-activity normalization, explicit quota and paid-use policy, immutable provider-neutral runtime-session pinning, and personal-connection cleanup with credential-revocation reconciliation are delivered on `slice/11-ai-runtime-governance`. Tasks 4 and 13 were delivered in parallel under the recorded intra-slice ownership partition below. Tasks 11 and 16 are now executable, and repository-wide verification remains serialized until the parallel Slice 14 work is reconciled. One slice-gate blocker is recorded in the progress log: the Slice 09 specification-governance table assertion produces a false positive introduced by Task 2's migration and needs an owning task before the verification gate can pass. Remote and cloud worker setup, project-shared funding, consumer-owned per-agent presentation, and Slice 07 lifecycle integration are deferred to focused follow-up specifications.

## Active Slice

Deliver an account-level AI Connections workflow plus a provider-neutral runtime foundation through one authorized paired local worker and one version-checked OpenAI Codex App Server adapter: register multiple labelled credential-local personal connections, retrieve proven model and quota facts, pin one compatible runtime configuration, enforce explicit scarcity and strict API-key spending boundaries, and publish access-safe observation contracts for consumer-owned presentation.

## Cross-Specification Dependencies

Requires:

- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 7`.
- `capability:project-participation-boundary` — provider `specs/08-project-participation#Task 4` — required before `Task 5`.

Provides:

- `capability:ai-runtime-session` — ready after `Task 11`.
- `capability:ai-runtime-observation` — ready after `Task 5`.
- `capability:ai-runtime-governance` — ready after `Task 6`.

## Task Size Gate

- Every task is `Size: Standard`, owns one independently provable transport, adapter, domain invariant, workflow, policy, ledger, projection, lifecycle control, or review outcome, and is expected to produce one focused task-boundary commit.
- No task owns more than three active acceptance criteria or two data entities.
- Provider-specific production adapters, shared project funding, and workflow lifecycle integration are separate split signals and remain outside this active slice.
- No task-size exception is used.

## Implementation Boundary

Included:

- A separate account and device-workspace-scoped personal-worker AI RPC transport over the existing paired-local-worker authorization capability.
- One version-checked OpenAI Codex App Server adapter over local standard input and output using allowlisted documented account, login, model, rate-limit, usage, and token-observation methods.
- Multiple labelled opaque personal connections bound immutably to one account, paired worker, and worker-local Codex profile.
- Account-level AI Connections linking, inspection, rename, availability, corrective-action, and revocation UX with worker-local secret entry.
- Provider-neutral live model catalog and compatibility adapter with enumeration-unsupported behavior.
- Open ChatGPT quota-bucket normalization, explicit scarcity and paid-use choices, and strict API-key spending reservation and reconciliation.
- Immutable support or working-agent runtime-session configuration with concurrent connection reuse.
- Ordered per-agent usage, cost estimate, quota, and status contracts with owner-exact and participant-safe projections for later consumer-owned presentation.
- Active-slice privacy, lifecycle, security, retention, rights, logging, and no-analytics controls.

Excluded:

- Remote, cloud-hosted, Linux, and Windows worker provider setup or credential custody.
- Production provider adapters beyond the first OpenAI Codex adapter.
- Project-shared connections, permissions, project budgets, and project-funded per-run ceilings.
- Slice 07 manifests, commands, run transitions, pause, resume, stop, retry, cancellation, or continuation changes.
- Support-assistant conversation persistence or full consumer UI.
- Per-agent runtime presentation in Slice 07 or Slice 12.
- Provider billing, subscription, credit purchase, or resale.

Deferred after this slice:

- Shared project API connection, participant permission, project budget, and per-run ceiling workflow.
- Explicit personal-versus-shared connection choice when both are eligible.
- Slice 07 `update-spec` and implementation for runtime-session manifest binding, quota and spending pause, resume after reset, initiator-or-owner stop, and linked continuation on an approved different model.
- Support-assistant conversation and runtime-control consumer UI.
- Remote or cloud worker provider connection setup and deployment.
- Production adapters for each approved provider and official client.
- Claude Code catalog and quota discovery through officially supported client interfaces, with versioned `/usage` parsing only when no structured supported surface exists.

Release gates:

- Actual supported Codex version and generated-schema digest, signed local-worker packaging, OAuth or API-key terms, processors, regions, transfer safeguards, retention and training-use settings, current official price-source configuration, notices, incident handling, credential-revocation proof, enforced deletion and cache expiry, live adapter smoke tests, and final accountable privacy, security, and legal review.

Traceability:

- Deferred criteria: AC-08, AC-10, AC-11, AC-12
- Release criteria: none.
- Deferred entities: entity:SharedProjectAIConnection, entity:ProjectAIBudget, entity:RuntimeContinuation
- Release entities: none.

## Parallel Implementation Ownership

- Implementation is partitioned by ownership between `specs/11-ai-runtime-governance#Task 7` and `specs/14-repository-execution-profile#Task 1` (Task 14.1).
- `specs/11-ai-runtime-governance#Task 7` exclusively owns the personal AI worker transport, including its socket, channel, and any Endpoint registration.
- `specs/14-repository-execution-profile#Task 1` exclusively owns repository-assessment persistence and UI, including its migration, hosted and device-authoritative storage contracts, route and project navigation, assessment LiveView, and focused browser test.
- Repository-wide verification is serialized after both task-scoped changes are reconciled. Each parallel task runs only its focused proof and must not modify the other task's owned surfaces.
- Implementation is additionally partitioned by ownership between `Task 4` and `Task 13`, which share one working tree and are separated by disjoint paths, distinct test partitions, and distinct build paths.
- `Task 4` exclusively owns `AIRuntimeSession`, its runtime-session boundary module and migration, its focused test, and `test/support/ai_runtime_fixtures.ex`. It consumes `PersonalConnections.resolve_for_consumer/3`, `ModelCatalogs.validate_selection/5`, and `QuotaPolicy.evaluate/3` as read-only callers and does not modify them.
- `Task 13` exclusively owns `PersonalAIConnection`, `PersonalConnections`, the personal connection adapter and its RPC adapter, the revocation reconciliation module and its migration, `test/support/personal_connection_adapter_double.ex`, the existing personal-connections test, and the `PersonalAIConnection` entries in the privacy rights and retention modules. It does not modify `test/support/ai_runtime_fixtures.ex` or any runtime-session surface.
- Neither parallel task modifies `AIConnectionsLive`, the personal-worker transport, the Codex App Server adapter, the catalog surfaces, or the quota surfaces.

## Tasks

- [x] Task 7 — Establish the authenticated personal-worker AI RPC transport.
  - Size: Standard
  - Depends on: none
  - Purpose: Carry bounded account-level provider operations through one already authorized paired local worker without broadening the Slice 07 run gateway.
  - Owned surfaces: Personal-worker channel and request envelope, account and device-workspace authorization, negotiated AI capability names and protocol version, request identifier and idempotency key, response correlation, timeout, replay refusal, reconnect, bounded payloads, typed transport failure, project-run command exclusion, fixtures, and worker double.
  - Owns: AC-16
  - Proof: Focused authentication, account, device workspace, capability, request, correlation, idempotency, timeout, reconnect, replay, size, malformed payload, cross-workspace, cross-account, project-command denial, and worker-double tests pass.
  - Delivered: `PersonalAIWorkerSocket` (pairing-credential authentication of active paired workers only) and `PersonalAIWorkerChannel` on the workspace-scoped `personal_ai:` topic with join-time workspace re-authorization; `AIRuntime.PersonalWorkerProtocol` owning `personal-ai/1`, the connection, catalog, quota, and observation capability allowlist, strict request and response field allowlists, payload limits, and the Slice 07 command denylist; `AIRuntime.PersonalWorkerRPC` with a unique per-worker connection registry, correlated account-scoped bounded requests, typed transport failures, idempotent replay-safe responses, and deterministic reconnect replacement. The Slice 07 run gateway is untouched.

- [x] Task 8 — Implement the version-checked Codex App Server adapter.
  - Size: Standard
  - Depends on: Task 7
  - Purpose: Give the paired worker one fail-closed official-client boundary without making an experimental protocol shape an implicit domain contract.
  - Owned surfaces: Worker-supervised local App Server process, standard-input and standard-output JSON-RPC, initialization, Codex version and generated-schema-digest compatibility registry, documented method allowlist, managed ChatGPT browser and device-code login, API-key login, external-token and WebSocket denial, typed errors, timeout, cancellation, crash and restart, stdout validation, stderr suppression and redaction, credential-shaped-content rejection, fixtures, and deterministic process double.
  - Owns: none (worker adapter foundation)
  - Proof: Focused version, schema digest, initialization, method allowlist, ChatGPT login, device-code login, API-key login, external-token denial, WebSocket denial, malformed and oversized response, credential-shaped output, raw-error exclusion, timeout, crash, restart, and deterministic-adapter tests pass.
  - Delivered: `AIRuntime.CodexAppServer` owns a linked worker-local stdio adapter with JSONL buffering, the required `initialize` then `initialized` handshake, strict request and notification method allowlists, managed ChatGPT browser and device-code login, worker-local API-key login, external-token and non-stdio denial, bounded correlation, local cancellation, typed timeout and process failures, crash reinitialization, strict stdout shapes and sizes, raw-error normalization, credential-shaped-content rejection, and stderr suppression. `CodexAppServer.Compatibility` admits only configured installed-version and generated-schema-digest pairs; the production pair remains release-gated. `CodexAppServer.StdioProcess` is replaceable by the deterministic `CodexAppServerProcessDouble` used by the focused fixture-backed proof.

- [x] Task 1 — Establish account-owned personal AI connections.
  - Size: Standard
  - Depends on: Task 7, Task 8
  - Purpose: Give support and working-agent consumers stable personal connection references without moving credentials or raw provider identity into the control plane.
  - Owned surfaces: `PersonalAIConnection`, migration and constraints, account and paired-worker ownership, opaque worker-profile reference, provider and authentication mode, trimmed account-scoped case-insensitive label uniqueness, multiple connections, idempotent same-profile link, immutable binding, safe availability, requested and acknowledged revocation states, unavailable or incompatible worker result, no-funded-fallback enforcement, strict allowlist, fixtures, and deterministic adapter double.
  - Owns: AC-01, entity:PersonalAIConnection
  - Proof: Focused account, worker, profile, label, multiple-connection, same-profile idempotency, immutable binding, ChatGPT and API-key mode, availability, incompatibility, revocation-state, credential absence, provider email, account, workspace and plan absence, no fallback, support-consumer, working-agent-consumer, and adapter-contract tests pass.
  - Delivered: `PersonalAIConnection` and its migration persist one minimized account-owned binding to an active paired worker and opaque worker-local profile with expression-indexed trimmed case-insensitive labels, globally unique worker-profile ownership, constrained provider, authentication, availability and revocation vocabularies, and a database trigger that freezes account, worker, profile, provider and authentication bindings. `PersonalConnections` re-authorizes the active account and worker, validates exact bounded adapter results, links the same binding idempotently, refuses cross-account profile sharing and binding changes, resolves only explicit eligible support-assistant or working-agent selections without a funded fallback or worker-profile disclosure, and records requested and acknowledged revocation states for Task 13's later credential-removal reconciliation. `PersonalConnectionAdapter.RPC` carries only the `connection/1` link contract through the completed personal-worker transport; the deterministic adapter/RPC double and focused fixtures keep provider identity, credentials, plan details and raw errors outside the control plane.

- [x] Task 9 — Deliver the account-level AI Connections workflow.
  - Size: Standard
  - Depends on: Task 1
  - Purpose: Let a signed-in user manage labelled personal connections while all secret entry and raw provider identity stays in the paired worker.
  - Owned surfaces: `AIConnectionsLive`, authenticated route and navigation entry, paired-worker selection, missing, unavailable and incompatible worker guidance, user label create and rename, local managed-login and API-key-entry handoff, pending and completed link states, safe availability, live catalog and quota panels, revoke confirmation and result, provider-identity non-rendering, keyboard, focus, accessibility, desktop and mobile layout, fixtures, and browser setup.
  - Owns: AC-17
  - Proof: Focused LiveView and desktop and mobile browser tests cover link, label, duplicate label, multiple connections, worker selection, missing, unavailable, incompatible, ChatGPT handoff, API-key local-entry handoff, pending, success, failure, rename, inspect, revoke, secret-field absence, raw-account absence, keyboard, focus, accessibility, and responsive behavior.
  - Delivered: Authenticated `AIConnectionsLive` at `/ai-connections` with a Projects navigation entry, current-device worker discovery, negotiated `personal-ai/1` and `connection/1` readiness checks, workspace re-authorization before link, labelled ChatGPT and API-key worker-local handoffs, pending and typed result states, account-scoped rename, immediate revocation request, safe availability, actionable worker recovery, explicit unknown catalog and quota panels, and responsive keyboard-accessible presentation. The compile-gated browser harness drives the real personal-worker RPC with exact safe adapter results; no secret field, raw worker reference, provider account identity, plan detail, credential, or raw adapter error is rendered.

- [x] Task 2 — Deliver live model catalog and compatible effort selection.
  - Size: Standard
  - Depends on: Task 1, Task 8, Task 9
  - Purpose: Present only models and effort choices proven by the authenticated worker-local Codex profile.
  - Owned surfaces: `ModelCatalogSnapshot`, provider-neutral catalog adapter, Codex `model/list` integration, live refresh, current and default designation, supported reasoning-effort choices, model and effort compatibility, enumeration-unsupported result, unknown-compatibility denial, provenance, expiry metadata, AI Connections projection, input and output validation, fixtures, and deterministic adapter double.
  - Owns: AC-02, AC-03, entity:ModelCatalogSnapshot
  - Proof: Focused live enumeration, official-client, no-hardcode, no-plan-inference, current, default, effort, compatible, unknown, unsupported, stale, malformed, oversized, provenance, safe-settings projection, and deterministic adapter tests pass.
  - Delivered: `ModelCatalogSnapshot` and its migration persist one short-lived, minimized, account-and-connection-scoped projection of authenticated model, reasoning-effort, current/default, provenance, retrieval, and expiry facts. `ModelCatalogAdapter` enforces an exact provider-neutral contract; its `RPC` adapter uses only the authenticated `catalog/1` personal-worker capability, and its Codex adapter pages the verified `model/list` interface with `includeHidden: false`, rejects generated-schema drift, repeated cursors, oversized or credential-shaped content, and derives provenance from the App Server's verified Codex-version and schema-digest pair. `ModelCatalogs` invalidates prior evidence before refresh, re-authorizes the account and connection before persistence or selection, revalidates stored provenance on every projection, and fails closed for stale, unknown, unsupported, malformed, incompatible, or unproven model-effort selections. `AIConnectionsLive` refreshes and renders only safe authenticated model and effort facts with current/default, source, retrieval, and expiry labels and clears prior rendered evidence when a later refresh fails. Quota, runtime-session persistence, execution-time compatibility revalidation, and lifecycle enforcement remain owned by Tasks 3, 4, and 16.

- [x] Task 3 — Normalize live quota and token-activity facts.
  - Size: Standard
  - Depends on: Task 2
  - Purpose: Preserve every supported ChatGPT quota bucket and unknown field without inventing API-key billing facts.
  - Owned surfaces: `QuotaSnapshot`, Codex `account/rateLimits/read`, `account/rateLimits/updated`, and `account/usage/read` integrations, sparse-update merge or refetch, arbitrary general and model-specific buckets, reset and paid-continuation facts, token-activity summary, source time, ChatGPT versus API-key source distinction, explicit unknowns, AI Connections projection, fixtures, and deterministic quota adapter.
  - Owns: AC-04, entity:QuotaSnapshot
  - Proof: Focused multi-bucket, sparse update, refetch, general, model-specific, reset, credit, paid continuation, token activity, API-key unknown, missing, malformed, oversized, stale, provenance, safe-settings projection, and deterministic adapter tests pass.
  - Delivered: `QuotaSnapshot` and its migration persist one minimized current snapshot under a composite account-and-connection ownership constraint. `QuotaAdapter` validates a bounded provider-neutral result, keeps API-key quota and billing explicitly unknown, binds each fact to a supported source method, and preserves arbitrary general, explicitly model-specific, or provider-defined buckets without inferring model scope or paid continuation. Its Codex adapter uses the verified `account/rateLimits/read` and `account/usage/read` methods, treats sparse `account/rateLimits/updated` notifications only as full-refetch triggers bound to one immutable worker profile and App Server process, reconciles historical and mirrored bucket shapes, and strips plan, provider identity, raw error, and credential-shaped content. `Quotas` invalidates prior evidence before refresh, serializes each connection through a PostgreSQL session advisory lock, re-authorizes before persistence, and returns only unexpired owner-exact projections. `AIConnectionsLive` renders safe quota, reset, credit, paid-continuation, token-activity, provenance, expiry, and explicit-unknown states. Supported native-worker packaging, process startup, and the live signed-version smoke test remain release-gated.

- [x] Task 10 — Enforce explicit quota and paid-use choices.
  - Size: Standard
  - Depends on: Task 3
  - Purpose: Refuse scarce, model-specific, fallback, or provider-paid execution unless the connection owner made the required bounded choice.
  - Owned surfaces: Quota applicability evaluator, scarce-model opt-in, model-specific-bucket opt-in, provider-paid-continuation approval, connection and model binding, expiry and revocation, no silent model, effort or connection fallback, no silent paid use, unknown-capacity refusal, normalized pause decision, fixtures, and deterministic policy adapter.
  - Owns: AC-05
  - Proof: Focused general, model-specific, scarce, paid, unknown, missing, opt-in, expiry, revocation, connection mismatch, model mismatch, no-fallback, no-paid-use, pause, and deterministic-policy tests pass.
  - Delivered: `QuotaPolicy` re-authorizes the active connection owner before and after evaluation, requires one exact connection, model and effort selection, and validates bounded owner choices tied to that connection, model, applicable bucket, cost boundary and validity window. `QuotaPolicyAdapter.Default` applies general buckets to every model, applies model-specific buckets only to their exact model, refuses provider-defined or missing applicability, unknown scarcity and capacity, stale or missing ChatGPT quota, and exhausted quota without the exact paid-continuation approval. The normalized result can only preserve the selection and return `proceed`, `proceed_to_cost_reservation` for API-key work, or a typed resumable `pause`; it has no fallback surface. The adapter contract independently re-runs the authoritative deterministic decision before accepting a double's output, while API-key quota remains unknown and cannot bypass Task 11's strict cost-reservation boundary.

- [x] Task 4 — Pin provider-neutral runtime sessions.
  - Size: Standard
  - Depends on: Task 2, Task 10
  - Purpose: Bind support conversations and working-agent runs to one reproducible configuration without preventing concurrent connection reuse.
  - Owned surfaces: `AIRuntimeSession`, migration and constraints, support and working-agent consumer kinds, connection eligibility, model and effort compatibility revalidation, catalog provenance, immutable configuration version, explicit opt-in references, API-key spending ceiling, concurrent reuse, stale catalog refusal, idempotent creation, fixtures, and consumer contract.
  - Owns: AC-07, AC-14, entity:AIRuntimeSession
  - Proof: Focused support, working agent, connection, model, effort, provenance, version, opt-in, ceiling, immutable pin, concurrent reuse, stale, incompatible, unknown, idempotent, and consumer-contract tests pass.
  - Delivered: `AIRuntimeSession` and its migration persist one minimized immutable pinned configuration per consumer reference, with a `(account_id, consumer_kind, consumer_ref)` uniqueness key and a database trigger that freezes all eighteen pinned columns on update. `RuntimeSessions.pin_session/3` locks the account and connection rows, re-runs `PersonalConnections.resolve_for_consumer/3` inside the transaction so connection eligibility keeps its single authority, revalidates the model and effort through `ModelCatalogs.validate_selection/5`, and pins only the opt-in choices `QuotaPolicy.evaluate/3` reported as in force. Both consumer kinds run the identical connection, model, effort, compatibility, quota, fallback, and paid-continuation rule set. Catalog provenance is copied as frozen evidence rather than foreign-keyed, so a later catalog refresh cannot alter or invalidate an active pin. An API-key session requires a positive ceiling and ISO-4217 currency; a ChatGPT session must carry neither. Re-pinning the same consumer with an identical chosen configuration returns the existing session, while a different configuration fails closed as `configuration_conflict`. Cost reservation, capability readiness, retention, and rights remain owned by Tasks 11 and 14.

- [ ] Task 11 — Enforce strict API-key cost reservations and publish runtime-session readiness.
  - Size: Standard
  - Depends on: Task 4
  - Purpose: Guarantee that concurrent API-key turns cannot allocate more than the session's approved non-exceeding ceiling.
  - Owned surfaces: `RuntimeCostLedger`, migration and constraints, versioned official-price snapshot configuration, pinned model price lookup, bounded input and maximum-output basis, conservative maximum calculation, atomic reservation, idempotency key, concurrent allocation, observed token reconciliation, reservation release, remaining capacity, stale or missing price refusal, insufficient-capacity pause, abandoned-reservation recovery, fixtures, `capability:ai-runtime-session` provider, and readiness write-back.
  - Owns: AC-06, entity:RuntimeCostLedger
  - Proof: Focused current, stale, missing and changed price, bounded maximum, below, exact and insufficient capacity, atomic reservation, idempotency, concurrency, reconciliation, release, abandoned recovery, no-over-allocation, pause, preserved session, API-key-only application, capability-contract, and readiness tests pass.

- [ ] Task 12 — Ingest ordered runtime observations.
  - Size: Standard
  - Depends on: Task 11
  - Purpose: Preserve useful runtime facts and estimates with explicit provenance without claiming the consumer's presentation surface.
  - Owned surfaces: `AgentRuntimeObservation`, migration and constraints, Codex thread token-usage and rate-limit notifications, local elapsed time, estimated cost and calculation basis, applicable quota references, available, constrained, paused and unknown statuses, provider-fact, worker-observed, local-estimate and unknown source labels, ordered append, idempotency, stale-event refusal, fixtures, and deterministic observation adapter.
  - Owns: AC-09, entity:AgentRuntimeObservation
  - Proof: Focused ordering, idempotency, stale event, elapsed time, token, cost basis, quota, status, provider fact, worker observation, estimate, unknown, support, working-agent, malformed, oversized, and deterministic-adapter tests pass.

- [ ] Task 5 — Publish access-safe runtime-observation projections.
  - Size: Standard
  - Depends on: Task 12
  - Purpose: Give future consumers owner-exact and current-participant-safe views without exposing unrelated account or project facts.
  - Owned surfaces: Owner-exact runtime projection, current-participant safe project projection, connection-owner authorization, `capability:project-participation-boundary` consumption, project and run scoping, exact account-wide quota, credit and spend owner fields, participant-safe selected model, effort, project usage and availability fields, forbidden-field allowlist, stale and removed participant denial, cross-project denial, support-consumer projection, fixtures, `capability:ai-runtime-observation` provider, and readiness write-back.
  - Owns: AC-13
  - Proof: Focused owner, participant, safe field, forbidden-field absence, stale, removed, cross-project, cross-account, support, working-agent, exact-versus-safe, capability-contract, and readiness tests pass without adding Slice 07 or Slice 12 UI.

- [x] Task 13 — Enforce personal-connection cleanup and credential-revocation reconciliation.
  - Size: Standard
  - Depends on: Task 1, Task 9
  - Purpose: End new execution immediately and prove worker-local credentials are removed without retaining raw revocation diagnostics.
  - Owned surfaces: Immediate control-plane revocation, new-session denial, worker-local credential-removal request, bounded acknowledgement, unavailable-worker pending state, retry and reconciliation, terminal opaque-reference deletion schedule, account erasure, service termination, idempotency, fixtures, and rights integration for `PersonalAIConnection`.
  - Owns: none (connection lifecycle mechanism)
  - Proof: Focused immediate denial, acknowledgement, pending, retry, worker unavailable, idempotency, account erasure, service termination, schedule, credential and raw-error absence, and rights tests pass.
  - Delivered: `request_revocation/3` now commits the `requested` transition before contacting the worker, so `resolve_for_consumer/3` denies new support-assistant and working-agent execution immediately and independently of any device reachability. `PersonalConnectionAdapter` gained a `revoke/4` callback carried over the existing authenticated `connection/1` capability; its acknowledgement has an exact two-key shape whose echoed worker-profile reference must equal the addressed one, and every typed error, unknown error, extra field, mismatch, exception, and throw collapses to the typed vocabulary so no credential, provider identity, or raw adapter error can be persisted. `PersonalConnectionRevocations` owns pending retention, idempotent retry, reconciliation, terminal deletion scheduling, and `terminate_service/1`; the migration adds only typed attempt counts, timestamps, a constrained failure-reason vocabulary, a `removed`/`absent` result, and a deletion schedule, with a check constraint making `acknowledged` the only state that may carry a result and a schedule. `Privacy.Retention.prune_all/1` reconciles before its delete pass so the already-supervised pruner drives retries, and `Privacy.Rights` requests worker-local removal before erasing an account, reporting only counts and typed outstanding reasons. An unreachable worker leaves the connection pending indefinitely rather than falsely claiming a credential was destroyed.

- [ ] Task 16 — Enforce model-catalog and quota-snapshot expiry.
  - Size: Standard
  - Depends on: Task 2, Task 3
  - Purpose: Prevent withdrawn models or old account facts from becoming durable entitlements.
  - Owned surfaces: Configured short catalog and quota lifetimes, current versus expired selection, refresh-before-session rule, terminal connection cleanup, idempotent supervised pruning, lock, restart and reconciliation, fixtures, and rights integration for `ModelCatalogSnapshot` and `QuotaSnapshot`.
  - Owns: none (snapshot lifecycle mechanism)
  - Proof: Focused catalog and quota expiry boundaries, refresh, selection refusal, connection cleanup, idempotency, lock, restart, reconciliation, and rights tests pass.

- [ ] Task 14 — Enforce runtime-session and cost-ledger lifecycle and rights controls.
  - Size: Standard
  - Depends on: Task 4, Task 11
  - Purpose: Retain pinned accountability and cost decisions only for their approved purpose and lifetime.
  - Owned surfaces: Active and terminal `AIRuntimeSession` and `RuntimeCostLedger` retention, connection removal behavior, project and conversation deletion handoff, verified access, correction limits, erasure, restriction, objection and portability behavior, derived-copy propagation, processor deletion request, encrypted-backup handling, idempotent cleanup, fixtures, and rights integration.
  - Owns: none (session and ledger lifecycle mechanism)
  - Proof: Focused active, terminal, connection removal, project deletion, conversation deletion, access, correction, erasure, restriction, objection, portability, derived copy, processor, backup, idempotency, and cleanup tests pass.

- [ ] Task 17 — Enforce runtime-observation lifecycle and rights controls.
  - Size: Standard
  - Depends on: Task 5, Task 12
  - Purpose: Remove operational observations when their bounded safety and accountability purpose ends.
  - Owned surfaces: `AgentRuntimeObservation` retention schedule, owner and participant access loss, project and conversation deletion handoff, verified access, correction limits, erasure, restriction, objection and portability behavior, cache and index deletion, derived-copy and processor propagation, encrypted-backup handling, idempotent pruning, fixtures, and rights integration.
  - Owns: none (observation lifecycle mechanism)
  - Proof: Focused retention boundary, owner, participant removal, project deletion, conversation deletion, access, correction, erasure, restriction, objection, portability, cache, index, derived copy, processor, backup, idempotency, and pruning tests pass.

- [ ] Task 15 — Enforce minimized runtime operations and prohibited-use controls.
  - Size: Standard
  - Depends on: Task 13, Task 14, Task 16, Task 17
  - Purpose: Keep diagnostics, processors, transfers, backups, and operational handling inside the approved service and security purposes.
  - Owned surfaces: Active processing inventory and field-purpose map, contract-necessity and service-security bases, least-privilege support access, processor and transfer inventory, structured content-free operational log allowlist, 30-day log expiry, credential and raw-account redaction, backup exclusion or expiry, no product analytics, no advertising, no model training, no unrelated improvement, no secondary use, fixtures, and negative scans.
  - Owns: none (operational privacy and security mechanism)
  - Proof: Focused inventory, purpose, basis, support access, processor, transfer, structured log, expiry, credential, raw account, content, backup, analytics, advertising, training, improvement, secondary-use, and negative-scan tests pass.

- [ ] Task 6 — Complete the active-slice privacy and security review.
  - Size: Standard
  - Depends on: Task 15
  - Purpose: Confirm the complete runtime foundation satisfies its approved contract before publishing governance readiness.
  - Owned surfaces: Consolidated connection, worker RPC, App Server, catalog, quota, session, cost-ledger and observation data-flow review, lifecycle and rights coverage, credential-locality review, account and participant access review, processor and transfer review, price-source safety review, log, cache and backup review, no-analytics and no-secondary-use review, required local privacy and security approval, release-gate classification, `capability:ai-runtime-governance` provider, and readiness write-back.
  - Owns: AC-15
  - Proof: Focused cross-task privacy, security, lifecycle, rights, access, credential, App Server, price, logging, processor, transfer, analytics, secondary-use, secret-scan, capability-contract, and required-review checks pass before governance readiness is recorded.

## Verification Gate

- [ ] Active-slice acceptance criteria pass and deferred criteria remain unimplemented.
- [ ] Every active acceptance criterion and data entity has one primary task owner.
- [ ] Personal-worker RPC tests prove account and device-workspace authorization, bounded correlation, replay safety, reconnect behavior, and complete isolation from Slice 07 project-run commands.
- [ ] Codex App Server tests prove standard-input and standard-output transport, accepted version and generated-schema digest, documented-method allowlisting, unsupported-version refusal, experimental-auth refusal, raw-error exclusion, crash recovery, and credential-shaped-content rejection.
- [ ] AI Connections desktop and mobile browser scenarios prove multiple labelled connections, paired-worker guidance, local login and secret-entry handoffs, live safe catalog and quota inspection, rename, revocation, keyboard, focus, accessibility, responsive layout, and raw provider identity and credential absence.
- [ ] Personal credentials remain worker or keychain-local and forbidden-field scans find no credential, provider email, raw provider account or workspace value, plan detail, or raw provider error in control-plane records, commands, logs, backups, exports, or UI.
- [ ] Catalog tests prove live authenticated source provenance, no hardcoded or plan-inferred models, limited unsupported behavior, compatibility enforcement, and expiry.
- [ ] Quota tests prove arbitrary ChatGPT buckets, sparse-update handling, API-key unknown behavior, explicit scarcity and paid-use consent, and no silent fallback.
- [ ] API-key cost-ledger tests prove current versioned pricing, conservative bounded reservation, atomic concurrent allocation, reconciliation, stale and missing price refusal, and pause before a turn can exceed the approved ceiling.
- [ ] Runtime-session tests prove immutable pinning for both consumer kinds, idempotency, and concurrent connection reuse.
- [ ] Observation tests prove ordered per-agent status, fact-versus-estimate labels, owner-exact access, participant-safe projection, cross-project denial, and no Slice 07 or Slice 12 presentation ownership.
- [ ] A live OpenAI Codex smoke test on one explicitly supported Codex version proves managed ChatGPT or API-key connection availability, model and effort discovery, applicable ChatGPT quota discovery, token observation, and strict safe projection without exposing credentials or asking the model to self-report usage.
- [ ] Privacy, security, retention, deletion, rights, processor, transfer, no-analytics, and no-secondary-use checks pass locally.
- [ ] `python3 .agents/scripts/test_validate_spec.py` passes.
- [ ] `python3 .agents/scripts/validate_spec.py specs/11-ai-runtime-governance` passes.
- [ ] `python3 .agents/scripts/validate_spec.py --all specs` passes.
- [ ] `git diff --check` passes.
- [ ] Production adapter and deployment-dependent evidence remains in the release gate.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
