# Local Worker Runtime Governance

## Status

Approved

Both product forks below were resolved by the accountable user on 2026-08-08: this bridge stays observation-only in its first slice (the worker's existing agent launch and credential resolution do not change, and spending-ceiling or quota-exhaustion pausing is not enforced against a local-worker run), and linking a personal AI connection stays optional per run rather than mandatory, so the already-verified `specs/33-local-worker-run-execution` flow keeps working unchanged when no connection is selected.

## Outcome

A local-worker development run can be attributed to one of the run initiator's own personal AI connections, with a pinned model and effort and a live runtime snapshot visible next to the run, using exactly the account, connection, session, and observation-projection contracts `specs/11-ai-runtime-governance` already delivers. A run initiator without a configured connection, or a Claude Code run before that agent has its own governance adapter, keeps running exactly as `specs/33-local-worker-run-execution` already proves, clearly labelled as ungoverned rather than silently treated as linked.

## Users

- The project participant who starts development on a ready feature and, when eligible connections exist, chooses or confirms which one funds the run.
- The run initiator and project owner, who see the governed run's pinned connection, model, effort, and observation trail with full account-level detail.
- Other current authorized project participants, who see only the run's safe project-scoped operational state.
- The individual account owner who linked the personal AI connection being spent by their own local-worker runs.

## In Scope

- Resolving the run initiator's eligible personal AI connections for the run's target device workspace and configured worker agent (Claude Code or Codex) before a run starts.
- Auto-pinning the one eligible connection when exactly one exists, or requiring an explicit choice when more than one exists, as part of the existing start-development action.
- Pinning an immutable `capability:ai-runtime-session` to the run before the worker is commanded to start, reused unchanged across that run's resume, retry, and reject-driven reattempts.
- Refusing to start a run when a selected connection fails to pin, instead of starting it silently ungoverned.
- Leaving a run with no eligible connection to start exactly as `specs/33-local-worker-run-execution` already proves, labelled ungoverned in its activity.
- A live local-worker runtime snapshot, computed on request rather than stored, that derives elapsed time and status from the worker's own current attempt lifecycle state without contacting the Codex App Server RPC, and that always reports token and cost facts as unknown.
- Combining that live snapshot with `capability:ai-runtime-observation`'s existing connection, model, and effort projection for a governed run, and applying the connection's most recently retrieved quota snapshot as informational context only.
- Showing the pinned connection label, model, effort, and live runtime snapshot to the run initiator and project owner (owner-exact) and a safe project-run projection to other current authorized participants, reusing `specs/11-ai-runtime-governance`'s existing projection contracts.
- GDPR purpose, minimization, access, retention, deletion, and rights coverage for the new run-to-session link and its computed snapshot.

## Out of Scope

- Changing how the worker authenticates or launches the coding-agent subprocess. Credential resolution stays exactly the approved `specs/33-local-worker-run-execution` rule: the operator's own existing local agent installation.
- Enforcing the spending ceiling or a quota-exhaustion pause against a local-worker run. The ceiling may still be required to pin an API-key connection's session, per `specs/11-ai-runtime-governance`'s existing rule, but no reservation is evaluated per turn and no local-worker run is paused or blocked by it in this slice.
- A Claude Code usage or quota adapter. Claude Code local-worker runs remain eligible for session pinning and lifecycle-based observation, but their quota and cost stay unknown until a future `specs/11-ai-runtime-governance` extension delivers that adapter.
- Any change to `specs/33-local-worker-run-execution`'s cancel, resume, retry, or reconcile authority, or to `specs/07-guided-specification-delivery`'s run-cancellation rule.
- Project-shared or project-funded API connections and budgets.
- Remote, cloud-hosted, or non-local worker governance.
- Resuming a paused session after quota reset, or an explicitly approved linked continuation on a different model. Both remain later `specs/11-ai-runtime-governance` workflow integrations.

## Primary Workflow

1. A project participant opens a ready feature to start development, exactly as `specs/07-guided-specification-delivery` already allows.
2. The product resolves the personal AI connections the participant's own account owns that are eligible for the run's target device workspace and the worker's configured agent. When exactly one is eligible, it is proposed as the default; when more than one is eligible, the participant must choose one; when none is eligible, the run proceeds ungoverned.
3. When the participant confirms an eligible connection, the product also resolves its live-proven model and effort choices and any opt-in or spending ceiling `specs/11-ai-runtime-governance` requires for that connection's authentication mode.
4. The product pins the immutable runtime session for this run before commanding the worker to start. A pin failure refuses the start with the same safe reason the connection would show anywhere else; it never starts the run ungoverned in place of the failed selection.
5. The worker executes the run exactly as `specs/33-local-worker-run-execution` already proves: unchanged agent launch, unchanged credential resolution, unchanged event and evidence contract.
6. Whenever a governed run's activity is viewed, the product computes a live runtime snapshot from the run's own current lifecycle facts and combines it with the pinned session's projection.
7. The run initiator and project owner see the pinned connection, model, effort, and live runtime snapshot next to the run's activity. Other current authorized participants see only the safe project-run view. An ungoverned run shows no runtime projection.
8. Resume, retry, and reject-driven reattempts on the same run reuse the same pinned session unchanged. A new run created after cancellation repeats step 2 with a fresh selection.

## Business Rules

- Linking a personal AI connection to a local-worker run is optional. A run with no eligible connection starts and completes exactly as the already-verified `specs/33-local-worker-run-execution` contract proves, and its activity is labelled ungoverned rather than implying a link that does not exist.
- Only a connection owned by the run's own initiator account may be resolved for that run; a project never shares one participant's personal connection with another's run.
- A connection is eligible for a run only when it is bound to the run's target device workspace's paired worker and is currently available; a connection bound to a different worker or account is never offered.
- When more than one eligible connection exists, the participant must explicitly choose one before the run starts; the product never guesses based on price, quota, or prior use.
- A runtime session is pinned once per run and reused unchanged by every attempt that run produces through resume, retry, or a reject-driven reattempt. A new run, created only after cancellation and a fresh start, always repeats connection selection.
- A selected connection that fails to pin (incompatible model, missing required spending ceiling, revoked, or unavailable) refuses the run start; the run never begins partially governed or silently ungoverned in its place.
- This slice does not change who may start, cancel, resume, or retry a run. `specs/07-guided-specification-delivery` and `specs/33-local-worker-run-execution` keep their approved authority unchanged.
- This slice does not change how or with which credentials the worker launches the coding-agent subprocess.
- A governed run's runtime snapshot reports only elapsed time and status derived from the worker's own current attempt lifecycle, computed live rather than stored, plus the connection's most recently retrieved quota snapshot shown as informational context. Token counts and cost are always reported unknown for this slice; neither is estimated, guessed, or inferred from agent output.
- A governed run's spending ceiling, when a pinned API-key connection requires one, is recorded at pin time but is not evaluated or enforced against this run's execution in this slice.
- The owner-exact projection of a governed run's connection, model, effort, and observation is visible only to the run initiator and the project owner. A current authorized participant who is neither sees only the safe project-run view `specs/11-ai-runtime-governance` already defines, and an unrelated party sees neither.
- The run-to-session link and its observation records are confidential project and personal data, follow the project's existing storage, retention, deletion, and rights rules, and are never reused for analytics, advertising, or model training.
- No repository content, absolute path, agent transcript, or provider credential may appear in a connection-selection request, a pinned session's consumer reference, or a computed runtime snapshot.

## Acceptance Criteria

- [AC-01] Given a participant starts development on a ready feature and exactly one personal AI connection is eligible for the run's target worker and configured agent, when they start, then that connection is proposed as the default without an extra required step; given more than one eligible connection exists, then the participant must explicitly choose one before the run starts.
- [AC-02] Given a participant confirms an eligible connection, model, and effort for a run, when the run starts, then an immutable runtime session is pinned to that run before the worker is commanded to start, reused unchanged by every later attempt the same run produces.
- [AC-03] Given a selected connection fails to pin for any reason, when the run is started, then the start is refused with a safe reason and no run begins in its place.
- [AC-04] Given no personal AI connection is eligible for a run's target worker and agent, when a participant starts development, then the run starts and completes exactly as `specs/33-local-worker-run-execution` already proves, and its activity is labelled ungoverned.
- [AC-05] Given a governed run at any point in its attempt lifecycle, when its runtime snapshot is computed, then it reports elapsed time and status derived only from the worker's own current attempt lifecycle state, the connection's most recently retrieved quota snapshot as informational context, and token and cost values as explicitly unknown.
- [AC-06] Given a governed run, when the run initiator or project owner requests its runtime state, then they see the pinned connection label, model, effort, and live runtime snapshot; when another current authorized participant requests it, they see only the safe project-run view; an ungoverned run shows no runtime projection to anyone.
- [AC-07] Given a run's connection-selection request, pinned session consumer reference, and computed runtime snapshot are inspected, when privacy and security verification runs, then none contains repository content, an absolute path, an agent transcript, or a provider credential, and existing `specs/11-ai-runtime-governance` retention, deletion, and rights controls cover every new record.
- [AC-08] Given a governed local-worker run and an ungoverned local-worker run both execute end to end on a real local repository, when the slice's verification gate runs, then the governed run's session, live runtime snapshot, and projections are all real and correct, the ungoverned run behaves identically to the unmodified `specs/33-local-worker-run-execution` baseline, and `capability:local-worker-runtime-governance` publishes only after both prove out.

## Open Questions

- None.
