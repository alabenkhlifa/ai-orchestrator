# Read-Only Project Assistant Design

## Context

SDD Orchestrator already owns current project identity and storage, current participant authorization, immutable specification revisions, the feature board, agent-run state, and accepted evidence. The shared AI runtime is specified separately so project features can use a participant's personal AI connection without reading provider credentials or inventing their own provider lifecycle.

The existing guided-delivery workflow helps a user structure one feature and drives approved work through readiness, execution, evidence, and review. It does not define a general project conversation, repository question answering, private assistant history, or a source-observation tool boundary. Repository SDD adoption is also a different concern: this assistant must work for empty, non-SDD, and large repositories without writing instructions or skills into them.

This feature therefore adds one read-only project assistant. It consumes the existing project domains and runtime capabilities without becoming a second specification store, board, run store, repository connection, provider configuration, or worker authority.

## Proposed Approach

Mount one assistant panel in the shared project layout so it is reachable from every project screen. Resolve one private `ProjectAssistantConversation` for the acting participant and project after current participation succeeds. Store the conversation through the project's authoritative hosted or device adapter and never project it into shared activity.

Before the first answered question, build a versioned processing summary from the acting participant's personal AI connection, the shared runtime, the source-observation worker when available, authoritative storage, transfer behavior, and retention policy. Require a matching `AssistantBoundaryConfirmation`. A changed execution, provider, worker, transfer, storage, or retention boundary invalidates the confirmation. An unavailable personal connection or runtime leaves the panel mounted with a safe setup or status result and prevents execution; no fallback provider is selected.

For each participant-initiated question, create one bounded `ProjectAssistantTurn` and revalidate current participation. Assemble the minimum default context through project metadata, the current `SpecificationStore` snapshot, read-only guided-delivery queries for board state, and recent run and accepted-evidence status. A destination-local `ProjectContextProjection` may accelerate those reads but remains inside the existing authoritative project boundary.

Let the shared AI runtime plan and execute only versioned read tools from a trusted SDD Orchestrator skill bundle. Consume its observation capability only for the access-safe available, constrained, paused, or unknown runtime state shown to the participant; exact owner quota and provider diagnostics remain outside this feature. When stored project context is sufficient, answer without a repository observation. When source is necessary, the assistant's repository-observation adapter must revalidate the acting participant's source authority and run bounded tree, text-search, and line-read operations inside the authorized worker. The worker observes the current working tree, including uncommitted changes, captures branch, current commit when present, dirty state, exclusions, and scan times, and compares beginning and ending state. A changed tree produces an unstable `RepositoryObservation`.

Keep a `RepositorySourceIndex` entirely inside the worker boundary for both hosted and device projects. It is keyed to project, repository authority, branch, commit, and working-tree state and is invalidated when that state changes. The hosted control plane stores no source index, raw file, bulk scan result, or tool payload. It may retain the minimum answer and exact path-and-line citation needed for the private conversation under the confirmed assistant processing boundary for at most the conversation lifetime.

Validate every material answer claim through typed `ProjectAssistantCitation` records. A citation identifies an exact specification revision, board item, run, attempt, evidence item, or observed repository path and line with Git and stability metadata. The answer composer must state partial, stale, excluded, unavailable, conflicting, or unstable grounding beside the affected conclusion. Repository instructions and every other content source are data, not authority; tool availability and authorization remain outside the model.

Delete authoritative conversation data immediately on the participant's action and no later than 30 days after last activity. End access immediately on participation loss or project deletion and invoke the applicable lifecycle. Extend the project processing inventory, verified rights handling, processor deletion, redaction, backup expiry, and release privacy profile without creating analytics or model-training reuse.

## Components Affected

- Shared project layout and project-scoped assistant panel on desktop and mobile.
- Project-assistant conversation, turn, citation, disclosure, deletion, and availability domain.
- Existing project-participation authorization and revocation boundary.
- Existing project-specification current-snapshot boundary.
- Existing guided-delivery read queries for board, recent run, and accepted evidence.
- Shared AI-runtime session and repository-observation capabilities.
- Acting-participant repository source-authorization adapter.
- Authoritative hosted and device project-storage adapters.
- Destination-local stored-project context projection.
- Worker-local repository tree, search, line-read, and source-index boundary.
- Trusted skill-bundle registry, read-tool broker, turn budgets, cancellation, and answer grounding.
- Privacy inventory, retention pruner, rights workflow, processor cleanup, redaction, security logging, and release profile.

## Data and Access Boundaries

- `ProjectAssistantConversation`: the one private conversation for one stable participant identity and one project, with authoritative destination, last-activity time, lifecycle state, and no shared-project projection.
- `ProjectAssistantTurn`: one participant question and grounded answer lifecycle with normalized availability, bounded runtime state, context-version references, answer, uncertainty markers, cancellation or failure outcome, and no raw provider event or hidden reasoning.
- `ProjectAssistantCitation`: one typed authorization-checked link from an answer claim to an exact specification revision, board item, run, attempt, evidence item, or repository working-tree path and line with observed Git and stability metadata.
- `AssistantBoundaryConfirmation`: the participant, project, disclosed-boundary digest and version, confirmation time, and invalidation state needed to prove first-use or changed-boundary confirmation without storing credentials or provider-account details.
- `ProjectContextProjection`: a destination-local, replaceable search projection over only authorized current project metadata, current specification content, current board state, recent run state, and accepted evidence already held in that authoritative project boundary.
- `RepositoryObservation`: one bounded source-read result with acting participant, authorized worker and repository target references, branch, commit when present, dirty state, start and completion times, exclusions, before-and-after state digests, stability result, and only the minimum cited excerpts returned to the turn.
- `RepositorySourceIndex`: a worker-local, replaceable, derived index keyed to project, repository authority, branch, commit, working-tree state, and index version, with no hosted control-plane copy.
- `AssistantProcessingRecord`: the existing processing inventory and deployment privacy profile extended with assistant purposes, fields, access, retention, deletion, rights, processors, regions, transfers, model-training setting, and accountable release review.

Required boundaries:

- Every assistant conversation, turn, citation, boundary confirmation, project-context projection, and repository observation belongs to one project. Every participant-owned record also belongs to one stable acting participant identity.
- The current project-participation boundary is checked before panel presentation, conversation lookup, turn submission, every stored-project read, citation resolution, history read, and deletion. Authorization is not cached across actions.
- Conversation privacy is narrower than project-content access. The owner, another participant, an assignee, a reviewer, and operations personnel cannot read another participant's assistant conversation merely because they can read the project.
- Project participation does not confer repository authority. Source observation checks the acting participant's current repository or worker authority and never substitutes an owner, project, application, provider, or worker credential.
- The project assistant consumes `capability:project-specification-store` for current specification reads and `capability:guided-specification-delivery` only through read-only board, run, and evidence queries. It cannot append a specification revision or invoke a delivery command.
- The project assistant consumes `capability:ai-runtime-session` for the participant's personal AI session and `capability:ai-runtime-observation` for the existing access-safe runtime status and usage projection. Repository working-tree observation is a separate read adapter owned by this specification. The assistant does not define provider credentials, account quota, worker provisioning, or another runtime session store.
- The runtime session receives the minimum context for one turn. Repository source is omitted unless the runtime explicitly requests an approved source tool for the question.
- Tool policy is enforced by the control plane and worker, not by prompt text. A trusted skill can select only already-authorized tools and cannot change project, participant, source, worker, filesystem, provider, network, or budget scope.
- Repository instructions, source files, specifications, board text, run output, and evidence are untrusted tool results. They never become runtime policy and cannot authorize another tool call.
- Stored-project projections stay at the project's authoritative destination. Hosted projects may use a hosted projection; device-authoritative projects use the device store and do not create a hosted project-content copy.
- Repository source indexes stay inside the authorized worker for both storage modes. The hosted control plane receives only bounded normalized observation metadata, the answer, and the minimum cited path, line, and excerpt permitted by the confirmed assistant boundary; it receives no bulk source, index, raw search result, or unrestricted tool payload.
- A repository observation snapshots state before and after the scan. A mismatch marks the observation unstable and prevents a stable-current claim. Worker loss or source denial prevents any older observation or index from being labeled current.
- Conversation and citation reads reauthorize their underlying project or source. A stored citation does not preserve access after participation or source permission ends.
- Sensitive paths are denied before reads. Tool results pass secret, credential, unnecessary-personal-data, and source-minimization filters before model input, answer composition, persistence, logging, or citation presentation.
- The ordinary participant availability view exposes a normalized state and safe setup path, never exact account quota, credentials, another person's usage, or provider diagnostics.
- Authoritative conversation data expires no later than 30 days after last activity and is removed immediately on participant deletion. Project deletion and participation loss end access immediately and schedule or perform the stricter approved cleanup.
- Raw provider events, hidden reasoning, unrestricted source tool results, credentials, and exact account quota are not stored. Security records use internal correlation and fixed outcome classes without prompts, answers, citations, paths, source, stable project identity, or stable participant identity unless a separately approved incident record strictly requires one.

## Interfaces

- Project-panel interface: mount the assistant on every authorized project screen, restore the acting participant's one private conversation, show normalized runtime and worker availability, preserve the underlying screen, and expose ask, cancel, citation-open, and delete actions without mutation controls.
- Conversation-store interface: create or retrieve one participant-project conversation, append one bounded turn and its citations atomically, list private history, record cancellation or fixed failure outcomes, update last activity, and delete through the hosted or device authoritative adapter.
- Participant interface: consume current owner or participant authorization and revocation state for every action without exposing participant email or changing participation.
- Specification-context interface: read a consistent current `SpecificationStore` snapshot and carry exact stable specification and revision identities into context and citations without loading prior revisions.
- Guided-delivery context interface: read the current board, named feature state, recent run status, and accepted evidence through project-authorized queries; expose no assignment, comment, readiness, start, retry, cancel, review, or lifecycle command.
- AI-runtime session interface: resolve the acting participant's personal connection, start one bounded read-only turn, inject the exact trusted skill-bundle version and tool manifest, stream or return normalized answer state, support cancellation, and persist no raw provider event.
- AI-runtime observation interface: consume only the provider capability's current-participant-safe available, constrained, paused, or unknown projection for assistant availability; keep owner-exact quota, account diagnostics, and another participant's usage outside the project panel.
- Repository-observation interface: authorize the acting participant and repository target, report worker availability, observe the current working tree, run bounded tree, search, and line-read operations, build or consult only a worker-local index, and return normalized provenance, stability, exclusion, and minimum excerpt results.
- Source-authorization interface: answer whether the acting participant may observe this repository through this worker now, without returning credentials, paths outside the target, another participant's grants, or account diagnostics.
- Processing-disclosure interface: build a versioned summary of execution, provider, worker, transfer, storage, index, and retention behavior; require a matching confirmation before first execution and after a material change.
- Project-context projection interface: index only authoritative current project metadata, specifications, board state, recent run state, and accepted evidence at the selected project destination; rebuild idempotently and delete with source records.
- Read-tool broker interface: expose only project-summary, specification-current, board-current, recent-run, evidence-current, repository-state, repository-tree, repository-search, and repository-lines operations with project, participant, source, byte, result, call-count, and elapsed-time enforcement.
- Trusted-skill interface: select a signed or equivalently integrity-pinned SDD Orchestrator skill version compatible with the read-tool manifest; reject unknown, repository-provided, downloaded, changed, or permission-expanding instructions.
- Grounding interface: bind answer claims to typed citations, verify each citation against the exact context version or repository observation, add visible uncertainty markers, reject inaccessible or fabricated citations, and minimize cited excerpts.
- Lifecycle interface: enforce immediate user deletion, rolling maximum retention, participation and project cleanup, processor deletion, backup expiry, rights handling, and content-free cleanup proof.
- Availability interface: distinguish personal-connection unavailable, shared-runtime unavailable, source worker unavailable, source permission denied, temporary limit, canceled, and failed without exposing quota or credentials and without treating source unavailability as stored-project unavailability.

## Decisions and Tradeoffs

### Read-Only First Release

- Choice: Limit this specification to grounded questions and answers and put confirmed mutations in a separate child specification.
- Reason: Reading project and repository context is independently useful and has a materially smaller authorization, audit, failure, and lifecycle boundary than creating or transitioning durable work.
- Consequence: The assistant may explain a next action but exposes no create, update, assign, comment, dismiss, start, cancel, retry, approve, reject, or generic state-change tool.

### Runtime Injection Instead Of Repository Installation

- Choice: Inject an integrity-pinned SDD Orchestrator skill bundle and read-tool manifest into each runtime session without copying them into the repository.
- Reason: Empty and established repositories should receive the same assistant behavior without accepting external files, conflicting with local instructions, or treating repository adoption as a prerequisite.
- Consequence: Repository instructions can improve answer context but remain untrusted data. Optional repository SDD adoption requires its own consent and change workflow.

### Personal AI Connection With No Funded Fallback

- Choice: Use the acting participant's personal AI connection through the shared runtime and block answering when it is unavailable.
- Reason: This preserves provider choice, cost ownership, and credential isolation without silently billing SDD Orchestrator or borrowing another participant's account.
- Consequence: The panel must make setup and temporary unavailability understandable while hiding exact account-wide quota and provider diagnostics from ordinary participants.

### Stored Context First And Source On Demand

- Choice: Load current project metadata, specification snapshot, board state, and recent run or evidence status by default, then request repository source only when needed.
- Reason: Most project questions can be grounded with less source disclosure, latency, model context, and worker dependency.
- Consequence: A worker-offline turn can still answer from current stored project data but must state that source is unavailable and cannot use a prior source scan as current.

### Current Working Tree With Stability Detection

- Choice: Observe the current working tree, including uncommitted changes, and compare state at scan start and completion.
- Reason: A committed revision alone may omit the work the user is currently asking about.
- Consequence: Repository citations need branch, commit, dirty state, scan time, and line provenance. Concurrent change produces an explicit unstable answer rather than an invisible mixed snapshot.

### Separate Destination-Local And Worker-Local Indexes

- Choice: Permit an authoritative-boundary projection for stored project data and a separate worker-local index for source, with no hosted source index.
- Reason: Fast retrieval is useful, but repository source and derived structure must not become a durable hosted copy merely to answer questions.
- Consequence: Source questions may be slower after worker restart or state change. A later hosted-source feature requires a separately approved disclosure and lifecycle.

### Private Participant Conversation

- Choice: Keep one conversation per participant and project outside shared activity.
- Reason: Questions, misunderstandings, and intermediate exploration need not disclose personal working context to every collaborator.
- Consequence: Other participants cannot reuse that history. A later confirmed domain action may be shared, but its owning workflow must record only the final authorized action and required attribution.

### Exact Typed Grounding

- Choice: Require typed citations and visible uncertainty for material project claims.
- Reason: A fluent answer is not proof that the model observed the current project, working tree, or accepted evidence.
- Consequence: The assistant must sometimes answer that evidence is unavailable or unstable instead of giving a complete-looking response.

### Maximum Thirty-Day Conversation Retention

- Choice: Delete inactive conversation history no later than 30 days and support immediate participant deletion, while leaving the final shorter production period to release review.
- Reason: Private questions and source-grounded answers can contain sensitive project and personal context and should not become indefinite project memory.
- Consequence: Users cannot rely on assistant chat as durable project documentation. Important decisions belong in a separately confirmed specification, feature, comment, or other authoritative workflow.

### No Assistant Analytics Or Training Reuse

- Choice: Create no product-analytics pipeline and prohibit model-training and secondary reuse.
- Reason: Prompts, answers, repository context, and usage patterns are linkable project data, not anonymous product telemetry.
- Consequence: Operational improvement relies on content-free service and security outcomes plus explicit user reports rather than conversation mining.

## Risks

- Model answers may sound current without current evidence. Require typed citations, context versions, working-tree provenance, and visible uncertainty.
- Repository content may attempt prompt injection or tool escalation. Keep policy outside the model, treat every content source as untrusted, and prove that hostile instructions cannot change the tool manifest.
- A participant may gain source through another person's credential. Reauthorize the acting participant at the source boundary and prohibit credential substitution.
- Concurrent edits may combine incompatible repository states. Compare before-and-after state and label the observation unstable.
- A source index may become a hidden hosted repository copy. Keep it worker-local, inspect storage and backup paths, and run negative hosted-content scans.
- Prompts, answers, citations, tool output, or logs may expose secrets or excessive source. Deny sensitive paths, minimize fields, scan for secrets, redact before each boundary, and test negative persistence.
- Private conversations may leak through shared activity, support access, notifications, or citations. Use a separate private store and authorization path with no shared projector.
- Exact quota or provider diagnostics may reveal account information. Normalize availability states and keep quota and credentials inside the AI-runtime owner boundary.
- Thirty-day deletion may not reach processors or backups. Require idempotent cleanup, reconciliation evidence, release-specific provider contracts, and backup expiry proof.
- The panel may disappear when dependencies fail. Mount it independently from runtime and worker availability and prove each degraded state on desktop and mobile.

## Open Questions

- None.
