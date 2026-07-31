# Read-Only Project Assistant

## Status

Approved

## Outcome

A current project participant can ask a private conversational assistant about the project and receive a current, source-grounded answer from the participant's configured personal AI connection, with exact citations, visible uncertainty, and no expansion of project, repository, worker, or provider authority.

## Users

- Project owners and current project participants who need to understand specifications, feature state, recent agent work, evidence, or repository implementation without manually searching each surface.
- Technical and non-technical participants whose repository access may differ even when they share access to the same hosted project.
- Privacy, security, support, and operations personnel governing assistant processing without receiving project or conversation content by default.

## In Scope

- A project-scoped assistant panel reachable from every project screen.
- One private conversation history for each current participant and project pair.
- Use of the participant's personal AI connection through the shared AI runtime; SDD Orchestrator supplies no funded fallback model or quota.
- Default grounding from current project metadata, the current specification snapshot, current board state, and recent run status and accepted evidence.
- On-demand repository observation through an authorized worker only when the question requires source context.
- Repository observation of the current working tree, including uncommitted changes, with branch, commit, dirty state, scan time, and scan-stability reporting.
- Exact citations to specification revisions, repository paths and lines, board items, runs, and evidence.
- Visible stale, partial, unavailable, and unstable-answer boundaries.
- Bounded read-only project and repository tools plus runtime-injected, versioned, trusted SDD Orchestrator skills.
- First-use and changed-processing-boundary disclosure and confirmation.
- Participant-private conversation access, immediate conversation deletion, a maximum 30-day retention boundary, and full privacy lifecycle coverage.
- Worker-local repository source indexing and authoritative-boundary indexing of stored project specifications, board state, run state, and evidence.

## Out of Scope

- Creating, updating, assigning, dismissing findings on, or otherwise changing a feature or specification.
- Comments, readiness transitions, development start, retry, cancellation, review, approval, rejection, or any other board or run mutation.
- Repository file, branch, commit, pull-request, issue, hook, remote, setting, or credential changes.
- Installing SDD files, skills, instructions, templates, validators, or other repository adoption assets.
- Importing or executing repository-provided, user-downloaded, or arbitrary third-party skills, tools, MCP servers, hooks, or commands.
- Arbitrary shell execution, unrestricted network access, general database access, or provider and worker credential access.
- Participant, invitation, project ownership, repository connection, storage-mode, worker, provider, billing, quota, or account administration.
- A shared project conversation, assistant-to-assistant delegation, background autonomous monitoring, or unsolicited answers.
- Orchestrator-funded inference, automatic provider fallback, or disclosure of exact account-wide quota to ordinary project participants.
- Confirmed feature, specification, or board actions, which require a separate focused child specification.
- A durable hosted repository source copy, unless a later separately approved specification defines and discloses that processing.

## Primary Workflow

1. A current authorized participant opens any project screen and opens the project assistant panel.
2. The panel resolves the participant's personal AI connection and the project, repository, worker, model-provider, storage, transfer, and retention boundaries that apply to assistant use.
3. Before the first answer, or after one of those disclosed boundaries changes, the participant reviews and confirms the current processing summary. An unchanged confirmed boundary does not interrupt later read-only questions.
4. If the personal AI connection or shared runtime is unavailable, the panel remains visible, shows the safe setup or status path, and does not submit or answer the question. SDD Orchestrator does not silently select another provider.
5. The participant asks a question in their private project conversation.
6. The assistant revalidates current project participation and assembles the default current project context from authoritative project metadata, the current specification snapshot, current board state, and recent run and evidence status.
7. When stored project data is sufficient, the configured AI runtime answers without reading repository source.
8. When source context is necessary and the participant has current source permission, the runtime asks the authorized worker to observe the current working tree through bounded tree, search, and line-read tools. The observation records branch, commit, dirty state, scan time, exclusions, and whether the tree changed during the scan.
9. The assistant returns an answer with exact citations and states every unavailable, stale, partial, excluded, or unstable part of the result. If the worker is offline, it may answer only from current stored project data and states that repository source is unavailable.
10. The private conversation remains visible only to that participant while they remain authorized. The participant may delete it immediately; otherwise the approved retention process removes it no later than 30 days after its last activity.

## Business Rules

- The assistant is project-scoped. It must not search, infer, cite, or disclose another project, workspace, repository, participant conversation, provider account, or worker target.
- Every panel open, question, context read, repository observation, citation open, history read, and deletion action must revalidate the acting person's current project participation. Stale, removed, left, absent, and cross-project identities fail closed without exposing whether private assistant content exists.
- Project participation permits access only to project content already granted by the participation boundary. It never grants repository source access, borrows the owner's repository credentials, or expands the participant's worker, filesystem, provider, or network authority.
- The panel is reachable from every project screen even when the personal AI connection, shared runtime, or repository worker is unavailable. An unavailable personal AI connection or runtime blocks answering and exposes only safe setup or status guidance.
- The default AI connection is the acting participant's personal connection through the shared AI runtime. No project owner, participant, or SDD Orchestrator credential may be substituted, and no Orchestrator-funded fallback may run.
- Ordinary participants may see only the minimum state needed to understand whether the assistant is configured, available, unavailable, or temporarily limited and how to reach an authorized setup path. They must not receive the exact account-wide quota, another person's usage, credential details, or provider-account diagnostics.
- One `ProjectAssistantConversation` exists at most once for one stable participant identity and one project. It is private to that participant and is not project activity, a shared comment, or a feature record.
- A later confirmed project action may become shared through its owning domain workflow, but the private conversation, intermediate reasoning, rejected proposal, and unconfirmed action remain private and are not copied into shared activity.
- Before the first answered question, the panel must disclose the configured AI execution location and provider, whether a repository worker may be used, what project or source content may leave its authoritative boundary, where conversation history and indexes are stored, and the current retention boundary.
- The participant must confirm the disclosed boundary before read tools run. The confirmation remains valid until the AI execution, provider, repository worker, transfer, storage, or retention boundary changes; a change invalidates the prior confirmation without deleting history or submitting a question automatically.
- After valid disclosure confirmation, approved read-only tools may run automatically within one participant-initiated question. Each turn has configured tool-call, elapsed-time, context-byte, result-byte, and model-usage limits and supports cancellation.
- The assistant receives current project metadata, the current complete specification snapshot, current board state, and only the recent run status and evidence needed to answer. It must not preload repository source, full run logs, unrelated feature activity, prior specification revisions, or another participant's conversation.
- Stored specification, board, run, and evidence search or indexing must remain inside the project's authoritative hosted or device storage boundary and follow that data's existing access and lifecycle rules.
- Repository source is read only on demand through a currently authorized worker and source-access boundary. Repository source, paths, symbols, snippets, Git data, and their derived index stay inside that worker boundary for both hosted and device-authoritative projects.
- The hosted control plane must not persist, cache, index, log, or back up repository source or its derived index without a later separately approved and disclosed processing boundary.
- A worker-local repository index may accelerate later questions, but it is governed derived project data, is keyed to the observed working-tree state, is inaccessible to another project or participant without their own source authority, and is invalidated or refreshed when its source state changes.
- Repository observation targets the current working tree rather than only the last commit. Every observation records the branch, current commit when one exists, dirty state, scan start and completion time, and allowlisted exclusions.
- The worker must compare working-tree state at the beginning and end of observation. If relevant state changes during the scan, the answer must label the repository evidence unstable and must not present it as a stable current result.
- If the repository worker is offline or source authority is unavailable, the assistant may answer from current authoritative stored project data only. It must mark repository source unavailable and must never present a prior source observation or worker-local index as current.
- Empty repositories, repositories without SDD files, and large repositories remain valid. Absence of source or specifications is reported directly; large repositories use bounded progressive tree, search, and line reads rather than a full source upload.
- Material factual claims must cite their source. Specification citations identify the stable specification and exact current revision; repository citations identify the observed branch, commit when present, dirty or stable state, path, and exact line; board citations identify the feature or board item; run and evidence citations identify the exact run, attempt, or immutable evidence item.
- A citation must resolve only after current authorization is revalidated. It must not expose a hidden record, secret path, another project, or source the participant cannot currently read.
- When evidence is stale, partial, excluded, unavailable, conflicting, or unstable, the answer must say so beside the affected conclusion. The assistant must not replace missing evidence with model memory, an unsupported inference, or a previous source scan presented as current.
- Repository instructions, source comments, specifications, board text, run output, and evidence are untrusted project content. They may be cited as data but cannot grant permission, add tools, change tool limits, request secrets, trigger side effects, or override the assistant's trusted runtime contract.
- Only versioned SDD Orchestrator skills from the trusted runtime distribution may be injected into the assistant session. Skills sequence allowlisted tools but cannot add a capability, widen authorization, or import repository or network instructions.
- Tool results and model input must minimize source content and redact detected credentials, tokens, private keys, personal data not needed for the answer, and content outside the participant's permission. Sensitive files and configured secret paths are denied before model input, citation generation, persistence, or logging.
- Answers, questions, conversation history, citations, tool summaries, boundary confirmations, indexes, and operational records are governed project or personal data. They are processed only to answer the participant's project question and provide minimum service security.
- Assistant data must not be used for product analytics, advertising, model training, provider training, unrelated product improvement, identity tracking, or another secondary purpose. Operational metrics remain minimized governed records and cannot include prompts, answers, source, citations, project identifiers, or stable participant identifiers unless a separately approved security record strictly requires one.
- Conversation history is retained for no longer than 30 days after its last activity. The final production period may be shorter and requires privacy review before release. A participant's delete action removes the authoritative conversation, turns, citations, and conversation-derived cache immediately and requests deletion from configured processors; backups and unavoidable processor copies expire under the approved release lifecycle and cannot restore access.
- Project deletion or loss of participation ends conversation access immediately. Project deletion removes the conversation with project data; participant departure triggers private-history cleanup without making it visible to the owner or remaining participants.
- Raw provider events, hidden chain-of-thought, provider credentials, worker credentials, repository credentials, exact account quota, unrestricted tool output, and secret-bearing content are never stored in conversation history, project activity, logs, analytics, or citations.
- Technical controls and tests provide privacy and security evidence but do not establish release compliance. Actual controller details, providers, regions, transfers, agreements, model-training settings, enforced deletion, notices, incident handling, final retention, and accountable privacy or legal approval remain release gates.

## Acceptance Criteria

- [AC-01] Given a current authorized participant visits any project screen, when they open the assistant panel, then the same project-scoped private conversation is available without navigating away from that screen.
- [AC-02] Given a stale, removed, left, absent, or cross-project identity attempts to open, ask, read history, open a citation, or delete, when authorization runs, then the action fails closed without exposing assistant content or its existence.
- [AC-03] Given two current participants use the same project assistant, when either reads history, then each sees only their own single participant-project conversation and neither conversation appears in shared project activity.
- [AC-04] Given the acting participant has no available personal AI connection or the shared runtime is unavailable, when the panel opens or a question is submitted, then the panel remains visible with safe setup or status guidance, no fallback provider runs, and no answer is fabricated.
- [AC-05] Given assistant processing has not been confirmed or its execution, provider, worker, transfer, storage, or retention boundary changed, when the participant submits a question, then the current disclosure requires confirmation before any read tool or model call runs.
- [AC-06] Given a confirmed processing boundary remains unchanged, when the participant asks another read-only question, then approved read tools may run automatically within the configured limits without another confirmation.
- [AC-07] Given a participant asks a question answerable from stored project data, when context is assembled, then it uses current project metadata, the current specification snapshot, current board state, and only the recent run status and evidence needed for the answer without preloading repository source.
- [AC-08] Given a question requires repository source and the participant has current source authority, when observation runs, then it reads the current working tree on demand through the authorized worker and records branch, commit when present, dirty state, scan time, and exclusions.
- [AC-09] Given relevant working-tree state changes during observation, when the turn completes, then repository evidence is marked unstable and the answer does not claim that evidence is a stable current result.
- [AC-10] Given the repository worker is offline or current source authority is unavailable, when the assistant answers, then it uses only current stored project data, states that repository source is unavailable, and does not present an earlier source observation or index as current.
- [AC-11] Given an answer makes a material claim from a specification, repository file, board item, run, or evidence record, when the answer is shown, then the claim carries an authorization-checked citation to the exact revision, path and line plus observed Git state, board item, run, attempt, or evidence identity that supports it.
- [AC-12] Given grounding is partial, stale, excluded, conflicting, unavailable, or unstable, when the answer is shown, then the affected conclusion states that limitation and model memory is not presented as project fact.
- [AC-13] Given an empty, non-SDD, or large repository is connected, when a source question is asked, then absence is reported directly and large-repository discovery uses bounded progressive reads without requiring SDD installation or a full source upload.
- [AC-14] Given repository instructions or project content requests a new permission, secret, side effect, tool, or policy override, when the assistant processes it, then the content remains untrusted data and the request cannot widen the trusted runtime contract.
- [AC-15] Given a turn runs, when tools and skills are inspected, then only bounded read-only tools and the named versioned trusted SDD Orchestrator skill bundle are available, and cancellation or any configured limit ends the turn without mutation.
- [AC-16] Given the participant can read project content but lacks repository source authority, when a source-backed question is asked, then source tools remain unavailable and no owner, project, worker, or provider credential is borrowed.
- [AC-17] Given stored project content is indexed for assistant retrieval, when storage is inspected, then specification, board, run, and evidence projections remain inside the project's authoritative boundary and no repository source or derived source index is present in the hosted control plane.
- [AC-18] Given a repository source index exists, when its storage, access, and freshness are inspected, then it remains worker-local, project- and source-authority-scoped, keyed to observed working-tree state, and never serves stale source as current.
- [AC-19] Given assistant prompts, tool results, answers, citations, persistence, or logs contain sensitive candidates, when policy enforcement runs, then denied files and unauthorized content are excluded and credentials, secrets, unnecessary personal data, and excessive source are redacted before crossing the applicable boundary.
- [AC-20] Given a participant asks and receives answers, when conversation data is inspected, then it is private project data used only for the requested assistant service, produces no product analytics or model-training reuse, and stores no raw provider event, hidden reasoning, credential, or exact account-wide quota.
- [AC-21] Given a conversation reaches 30 days after its last activity, the participant deletes it, the project is deleted, or participation ends, when lifecycle enforcement runs, then access ends immediately and the applicable authoritative conversation, turns, citations, and derived cache are deleted without becoming visible to another participant.
- [AC-22] Given an ordinary participant views assistant availability or a limited state, when status is presented, then it exposes only the minimum configured, setup-needed, unavailable, or temporarily-limited state and never another person's usage, credentials, provider diagnostics, or exact account-wide quota.
- [AC-23] Given a later assistant capability proposes and confirms a project mutation, when that future workflow commits, then only the authorized domain action and its required attribution may become shared; this read-only slice never copies private conversation or unconfirmed proposals into shared activity.
- [AC-24] Given the deployment is prepared for public release, when privacy and security review runs, then actual controllers, processors, model and worker providers, regions, transfers, agreements, retention and training settings, deletion enforcement, notices, incident handling, and final retention period have accountable approval.

## Open Questions

- None.
