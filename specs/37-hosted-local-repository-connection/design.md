# Hosted Local Repository Connection Design

## Context

`specs/06-project-portability` already delivered every durable part of a hosted project's link to a local worker: `HostedLocalRepositoryBinding` (Task 26) holds the minimized routing, `LocalRepositoryValidation` (Task 21) is the shared exact worker-proof boundary, and `HostedLocalRepositoryReconnection` (Task 27) composes them.

What is missing is a way in. `HostedLocalRepositoryReconnection.connect/6` gates on `RepositoryReconnection.required/2`, which requires a `PackageProvenance` row for the project — that is, the project must have been restored from a backup package. A hosted project created normally has no such row, so `required/2` refuses and the binding can never be created. `HostedLocalRepositoryReconnection.connect/6` has no caller anywhere in `lib/` outside its own file, and no web module anywhere references `connection_state/3`, `HostedLocalRepositoryBindings`, or `HostedLocalRepositoryReconnection`, so neither the first connection nor the restore reconnection has a user-facing entry point today.

The consequence is concrete and was proved on a real machine: `specs/36-local-worker-native-distribution` Task 12 ran the real signed worker against a real hosted project and its gateway credential exchange was correctly refused with `403`, because `WorkerGatewayCredentialController` requires a binding that nothing could create. That proof had to construct the binding directly through `HostedLocalRepositoryBindings.put_validated_binding/6` and read the dashboard side through `connection_state/3` instead of a page, both documented as deliberate substitutions. `specs/06`'s own restore page already tells the user to "use the normal flow to reconnect", naming a flow that does not exist.

## Proposed Approach

Add the missing entry: a first-connection action for a normal hosted local-repository project, and the project-page surface that starts it and shows its result.

The authority model is unchanged. Connection still requires the owning `PersonalWorkspace` for the project and a separately authorized `DeviceWorkspace` worker for the repository proof, and still ends in the same `HostedLocalRepositoryBindings.put_validated_binding/6` transaction. The only thing replaced is the entry gate: instead of `RepositoryReconnection.required/2`'s package-provenance requirement, a first-connection gate authorizes the owner's own hosted project when its repository provider is local and it already holds a portable repository identity. Everything downstream — exact match, atomic replacement, idempotent retry, disconnect, revocation cascade, derived unavailability, and field minimization — is consumed unchanged from `specs/06`.

Worker selection is explicit by default because the binding boundary already requires an explicitly selected device workspace and worker. The picker lists the active paired workers for the current device workspace through `specs/02-local-project-onboarding`'s existing pairing surface, and collapses to the single available worker when there is exactly one, so the common single-machine case adds no step it cannot answer.

The project page becomes the one place this lives: it shows the connection state derived by `HostedLocalRepositoryBindings.connection_state/3`, offers the connect action when there is none, and offers disconnect and connect-a-different-machine when there is.

## Components Affected

- Hosted project page: worker connection state, the connect action, machine selection, disconnect, and machine replacement.
- Hosted local-repository connection boundary: the first-connection authority gate and its composition of the existing validation and binding transactions.
- Paired-worker presentation for the owner's current device workspace.
- Delivery gateway credential exchange, as a consumer only: it starts succeeding for these projects because the binding it already requires can now exist.

## Data and Access Boundaries

- This slice introduces no new stored record. It creates, replaces, and removes `HostedLocalRepositoryBinding` rows through `specs/06-project-portability`'s existing transaction, whose schema, one-row-per-project constraint, minimization rules, and deletion cascades stay authoritative there and are not redefined here.

Required boundaries:

- Only the personal workspace that owns the project may connect, disconnect, or replace its machine. A foreign or unknown project resolves as not found rather than reporting its existence.
- Only a worker currently authorized for the owner's device workspace, active and reachable, may be selected. Worker authorization is never derived from project ownership.
- The worker receives only the project-held portable repository identity, never a path, remote URL, filename, Git history, or source.
- The stored routing stays the approved three fields — project, worker, last successful validation time. No path, credential, device label, compatibility metadata, or repository content is stored or rendered.
- A failed attempt is whole: no binding is created, replaced, or removed, and the repository is not touched.

## Interfaces

- First-connection interface: authorize the owner's hosted local-repository project, take an explicitly selected worker, run the existing exact worker proof, and create or replace exactly one binding.
- Paired-machine interface: list the active paired workers available for selection, and report the no-worker-paired case distinctly from a failed connection.
- Connection-state interface: report connected, temporarily unavailable, or not connected for a hosted local-repository project without disclosing worker or device data.
- Disconnect interface: remove the routing idempotently, leaving project, specifications, and repository unchanged.
- Consumed unchanged: `specs/06-project-portability`'s `LocalRepositoryValidation`, `HostedLocalRepositoryBindings.put_validated_binding/6`, `connection_state/3`, and `disconnect/2`; `specs/02-local-project-onboarding`'s pairing authorization and worker reachability policy; `specs/33-local-worker-run-execution`'s gateway credential exchange.

## Decisions and Tradeoffs

### First Connection Is A Separate Gate, Not A Relaxed Restore Gate

- Choice: Add a distinct first-connection authority gate for a normal hosted local-repository project and leave `RepositoryReconnection.required/2` and `HostedLocalRepositoryReconnection` exactly as they are. Both entries converge on the same `LocalRepositoryValidation` proof and the same `put_validated_binding/6` transaction.
- Reason: The restore gate's package-provenance requirement is not an accident to be loosened; it is what makes restore-time reconnection provably about a restored project. Weakening it would silently widen a `specs/06` contract this slice does not own, and would make one function answer two different authority questions.
- Consequence: Two entry points exist for the same binding, so the shared exact-match, replacement, and minimization rules must stay in the shared boundary rather than being duplicated in either entry. That is already how `specs/06` is built.

### Explicit Machine Selection, Collapsed When There Is Only One

- Choice: The owner explicitly selects which paired machine to connect. When exactly one active paired worker is available, that worker is used without presenting a choice.
- Reason: The binding boundary already requires an explicitly selected device workspace and worker, so an automatic pick would contradict a recorded authority boundary. Presenting a one-item choice asks the owner a question with no alternative answer.
- Consequence: A second machine paired between listing and confirming could make the collapsed case race the explicit case. The selection is therefore confirmed against the worker actually chosen at submit time, not against the count observed when the page rendered.

### The Project Page Is The Only Entry

- Choice: Connecting, showing state, disconnecting, and switching machines all live on the hosted project's own page. Hosted onboarding is not extended to connect at creation time.
- Reason: Every already-created hosted local-repository project would otherwise stay permanently unconnectable, including projects restored from a backup whose restore page already points at a "normal flow" that must exist somewhere. One surface also means one place where connection state is visible, which is what `specs/36`'s proof had to work around.
- Consequence: A project is created unconnected and connected as a second, explicit step. That is a visible extra step at creation time, accepted because it keeps one entry rather than two states of the same action.

### Connection State Is Read, Never Cached

- Choice: The page derives connection state on read through `HostedLocalRepositoryBindings.connection_state/3` rather than storing a status field on the project.
- Reason: Reachability is already derived from the worker's own `last_seen_at` against `specs/02-local-project-onboarding`'s staleness window. A second stored copy would be a second thing that can be wrong, and it is exactly the kind of stale duplicate the compatibility-window defect in that specification already demonstrated.
- Consequence: The page reflects a worker as temporarily unavailable only as promptly as the underlying liveness refresh allows, which `specs/02-local-project-onboarding` Task 11 owns.

## Risks

- Two entry points to one binding could drift apart. Keep every rule in the shared `specs/06` boundary and prove both entries against the same exact-match, replacement, and refusal behavior.
- A first-connection gate is a new authorization surface on hosted project data. Prove ownership scoping, cross-workspace denial, and invalid-provider refusal explicitly rather than assuming the reused transaction covers them.
- An owner may read "not connected" as project loss. Present it as a machine link that can be established or moved, never as a missing or broken project.
- The single-worker collapse could bind a machine the owner did not intend if their worker set changed mid-flow. Confirm against the worker chosen at submit time.
- Connection state accuracy depends on worker liveness, which is refreshed by `specs/02-local-project-onboarding` Task 11. Until that lands, a genuinely connected worker can read as temporarily unavailable; this slice must not compensate by inventing its own liveness source.

## Open Questions

- None.
