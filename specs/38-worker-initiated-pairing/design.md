# Worker-Initiated Pairing Design

## Context

Pairing today runs in one direction only. `SddOrchestrator.Devices.Pairing.start_pairing/2` takes a `device_workspace_id`, inserts a `PairingAttempt` carrying that workspace, and returns a code shaped `"ATTEMPT_UUID.SECRET"`. That is an attempt id and a 43-character secret joined by a dot. The control plane keeps only a salted SHA-256 digest of the secret. `complete_pairing/2` decodes the attempt id out of the code, verifies the secret against the digest, and creates the `LocalWorker` with its own credential. `POST /worker_pairings` (`WorkerPairingController`, `specs/36` Task 3) already exposes completion to an unauthenticated caller, authorized by nothing but possession of the code.

Because the attempt id is the code's own first field and is a database primary key, two codes can never collide. That property is structural, not enforced, and this slice must not lose it.

The gap is the entry point. The dashboard is the only party that can obtain a code, and its `Open in App` deep link renders only at `/onboarding/local` with a project parameter (`local_onboarding_live.ex`, `handle_params` on the `project` param). That address needs a project, a project on this path needs a paired worker, and a paired worker needs a code. A first-time user cannot break that cycle. The pairing form's own placeholder text advertises a short human code, which the real format has never been.

The worker app already holds the pieces this slice needs: `PairingHTTPPosting` posts pairing requests, `PairingStatusChecker` reports whether the worker is paired, `AppDelegate.rebuildMenu` builds the menu bar from a `WorkerStatus`, and `DashboardURLProvider` resolves a control-plane address from the bundle before any pairing exists.

## Proposed Approach

Split the attempt's life into two moments that are today one.

Creation becomes anonymous and unbound. A new endpoint mints a `PairingAttempt` with no workspace and returns the code. The record grants nothing: every path that authorizes a worker requires a workspace, and this record has none.

Binding stays authorized and stops there. When the owner submits the code in the dashboard, one conditional update attaches their own device workspace to the attempt. An attempt can be bound once. Binding does not create the worker, because the dashboard is not the worker and does not know what it is.

Completion stays where it already is. The app then posts the same code to the existing `POST /worker_pairings`, reporting its own operating-system and protocol versions and receiving its own credential. That is the endpoint's existing job and the only place those facts are known, so nothing new has to learn them.

The app keeps a live code by replacing it before expiry, and learns it has been bound by trying to finish: an unbound attempt cannot be completed, so a refusal means "not yet" and a success means an owner has redeemed it. Both run on the app's own unpaired polling schedule, so the person never returns to the app to finish.

## Components Affected

- `SddOrchestrator.Devices.Pairing` — unbound creation, and a bind-and-complete path that replaces the workspace-scoped assumption in `complete_pairing/2`.
- `SddOrchestrator.Devices.PairingAttempt` — `device_workspace_id` becomes nullable until binding, with the two valid states expressed as constraints rather than convention.
- A new control-plane endpoint for anonymous code issuance, beside the existing `POST /worker_pairings`.
- Rate limiting and audit for that endpoint.
- `SddOrchestratorWeb.LocalOnboardingLive` — the pairing form redeems a real code instead of relaying to a stand-in, and its placeholder stops advertising a format the product never used.
- Worker app (`SDDOrchestratorWorkerCore`) — code acquisition, refresh scheduling, clipboard copy, and the menu-bar states that expose them.
- Retention — unredeemed unbound attempts are discarded once unusable.

## Data and Access Boundaries

- `PairingAttempt`: an existing record, extended. It holds the salted digest and salt of a single-use pairing secret, an expiry, and — only after an owner redeems it — the device workspace it was bound to and the worker it authorized. Before binding it names no person, no machine, and no workspace; its entire content is a random digest and a timestamp. It is created unbound by an anonymous caller, transitions to bound exactly once, and is discarded when it can no longer be used.
- `PairingIssuanceThrottle`: the counter that bounds how many attempts one unidentified caller may create in a window. It holds a coarse caller key and a count, never a request body, a code, or a stable device identifier, and it expires with its window.

Required boundaries:

- An unbound attempt authorizes nothing. Every worker-authorizing path requires a bound workspace, so possession of an unredeemed code grants no read or write anywhere.
- Only an authenticated owner acting on their own device workspace may bind an attempt, and only to that workspace.
- Binding is one-way and single-use, enforced in the database rather than by application ordering, so two concurrent redemptions cannot both succeed.
- The raw code exists in the response that mints it, in the clipboard, and in the redemption request. It is never stored, logged, or emitted in diagnostics; only its salted digest is persisted.
- Refusals for expired, canceled, already-redeemed, and never-existed codes are indistinguishable to the caller.
- `PairingIssuanceThrottle` is operational data with no personal content and no analytics use.

## Interfaces

- New: an anonymous request that mints one unbound attempt and returns its code once. It accepts no caller-supplied identity, workspace, project, or secret.
- Changed: `Devices.Pairing.start_pairing/2` keeps its workspace-scoped behavior for the existing dashboard-issued and deep-link paths, which continue to work unchanged.
- New: a bind operation taking a code and the redeeming owner's device workspace, attaching the attempt to it and returning nothing the browser must hold.
- Unchanged: `POST /worker_pairings` and its response contract, so `specs/36`'s deep-link pairing keeps working exactly as verified. It is also how a worker-initiated pairing finishes, so both origins complete through one endpoint.
- Unchanged: the code format above, so one redemption path accepts codes from either origin.

## Decisions and Tradeoffs

### The code is minted unbound and bound only at redemption

- Choice: An anonymous caller may create an attempt, but it carries no workspace until an authorized owner redeems it.
- Reason: An unpaired app has no workspace identity — establishing one is what pairing is for. Minting unbound is the only option that lets the app show a code without either inventing a workspace or letting an anonymous caller name someone else's.
- Consequence: A leaked, unredeemed code is worth nothing, which is the point. The cost is a nullable column with two valid states, and a schema constraint to keep the invalid third state unreachable.

### Binding and completion are separate steps, each done by the party that can

- Choice: Redeeming binds the attempt to the owner's workspace and stops. The app completes it afterwards through the existing `POST /worker_pairings` and receives its own credential.
- Reason: Only the app knows its operating-system and protocol versions, and only the app should hold its credential. A dashboard-created worker has neither: it is reported `:incompatible` by `WorkerDiscovery` because it can state no versions, and its credential is handed to a browser that has no use for it and no way to pass it on.
- Consequence: The worker appears a moment after the code is accepted rather than instantly, so the dashboard shows the pairing step completing rather than a worker already present. The dashboard also cannot offer a preview step that validates a code without binding it.
- Replaces an earlier decision that made binding and completion one transaction. That decision's reason — that an attempt bound but not completed is a workspace-attached credential with no holder — was wrong. It is exactly the normal state of today's dashboard-issued pairing, where `start_pairing/2` creates a bound attempt and the worker completes it later. The state has always existed and has always been safe, because the code is what completes it and only its holder has that.

### An unbound attempt still cannot be completed

- Choice: Nothing new guards `POST /worker_pairings` against an unbound attempt; the guards Task 1 already added do it.
- Reason: `complete_pairing/2` builds the worker with the attempt's workspace. For an unbound attempt that is `nil`, which `LocalWorker.create_changeset/2` rejects as a required field, and the check constraint independently forbids confirming an attempt that belongs to no workspace. Two separate mechanisms already refuse it.
- Consequence: The safety property survives splitting the steps, so exposing anonymous issuance did not widen what a code can do before an owner binds it.

### Collision-freedom stays structural

- Choice: The code keeps embedding the attempt's own primary key, and the control plane remains the sole minter.
- Reason: Two codes cannot collide when each carries a distinct primary key. Letting the worker choose its own secret would replace a property that cannot fail with one that has to be enforced, and would hand an unauthenticated client control of a credential's entropy.
- Consequence: The app cannot produce a code offline; it must reach the control plane first, and shows a clear unreachable state when it cannot.

### The app refreshes its shown code before expiry

- Choice: While unpaired, the app replaces the code as it nears expiry.
- Reason: A person who walks away and returns must not copy a code the dashboard will refuse — a failure they cannot diagnose and did not cause.
- Consequence: Idle unpaired apps generate periodic anonymous requests, which the rate limit must accommodate; this is why the limit is a design decision rather than an afterthought.

### Clicking the status line copies

- Choice: The menu's first item copies the full code and confirms it.
- Reason: The code is roughly eighty opaque characters — it cannot be read aloud or typed, so the clipboard is the only usable transfer. Putting it on the item the person already reads for status keeps discovery to one click without displacing `Open Dashboard` or `Quit`.
- Consequence: The menu-bar icon still opens the menu rather than copying directly, so copying is one click deeper than the icon itself.

### The deep link stays

- Choice: `Open in App` is kept for reconnecting a machine to an existing project.
- Reason: It is implemented, verified, and strictly shorter when a project already exists. This slice fills the case it structurally cannot serve.
- Consequence: Two pairing entry points exist, and both must keep working; the redemption path is shared so they cannot diverge.

### The app discovers binding by attempting completion

- Choice: While unpaired, the app periodically refreshes its code and attempts `POST /worker_pairings` with it. A refusal means nobody has bound it yet; a success means an owner has, and the app takes its credential in the same call.
- Reason: It needs no new endpoint and no new state to read. Completion is already the only thing the app must eventually do, so trying it is both the question and the answer. `complete_pairing/2` refusing an unbound attempt cleanly is what makes "not yet" an ordinary reply rather than an error.
- Consequence: An unpaired app makes a request per tick, which the issuance rate limit and this schedule have to stay consistent about. The loop stops as soon as the app is paired, so a paired app polls nothing.
- Recorded because assuming it was already true is what let this slice be called `Verified` while the app performed none of these calls.

### The app hands off rather than claiming a setup it cannot finish

- Choice: On a successful completion the app stops offering a code and says the dashboard has taken over. It does not report itself paired, connecting, or setting up.
- Reason: A worker-initiated pairing has no project, and the worker configuration requires one, so there is no configuration the app can store. Reporting `pairedSettingUp` describes a setup that will never complete, which is what the first implementation did and what left a real install stuck on that line forever.
- Consequence, stated plainly because it is a real limitation and not a detail: the credential this pairing issues is not retained by the app. The worker row exists and the dashboard sees it, which is enough for onboarding to continue, but that worker cannot connect or run anything. Giving it a project, a repository folder, and a coding agent is deferred, and doing so will need a credential this flow currently discards.
- Rejected: storing the credential now with an unset project. That needs a storage contract for a partially configured worker, which is a larger decision than this slice should make on its own.

## Risks

- A worker paired this way is authorized but unusable until it is configured, and nothing in this slice configures it. Reduced by saying so in the app rather than implying a working worker, and by naming the follow-on in the deferred boundary; detected by the dashboard showing a worker that never connects.
- An anonymous endpoint invites automated abuse. Reduced by rate limiting per coarse caller key, short expiry, and discarding unredeemed attempts; detected by auditing issuance volume without recording a caller identity.
- A person could paste a code into someone else's dashboard session. Reduced by binding only to the redeeming owner's own workspace, so the worst case is pairing a worker to a space the person controls, never to a stranger's.
- Nullable `device_workspace_id` invites code that forgets to check it. Reduced by a database constraint expressing the two valid states and by keeping every worker-authorizing path workspace-required.
- Storage growth from unredeemed attempts. Reduced by expiry-driven deletion, proven rather than assumed.
- The existing pairing form and its placeholder describe a format the product never had, so a person may believe they typed a wrong code. Corrected as part of the redemption surface.

## Open Questions

- None. Two engineering choices are settled during implementation and recorded here when made. Two engineering choices are settled during implementation and recorded here when made: the allowed issuance rate and window, and the refresh margin ahead of the ten-minute expiry. Neither changes the approved workflow, the data boundaries, or any acceptance criterion.
