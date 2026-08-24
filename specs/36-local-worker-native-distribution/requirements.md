# Local Worker Native Distribution

## Status

Approved

Every product decision is resolved. Real Developer ID signing and Apple notarization are part of this slice's own verification rather than release-gated, because the accountable owner has the required Apple Developer credentials now. The app's only native surface is a menu-bar status item; pairing-code entry happens exclusively through a dashboard-issued deep link, never typed into the app; the app never registers itself to launch at login; and a detected update is downloaded and signature-verified but never installed without the operator's confirmation, deferred while a run is active on that worker.

## Outcome

A device operator who is not comfortable running a terminal command can still get a working local worker. They download a Developer ID–signed, notarized `.dmg`, install it with the standard macOS drag-to-Applications gesture, launch it to see a menu-bar status item, and complete pairing entirely by clicking one action on the dashboard's existing pairing screen — no typed code, no terminal. The packaged app runs the same worker runtime `specs/33-local-worker-run-execution` already delivers and verified, so once paired it dials out, executes runs, and reports status exactly as that slice already proved. The app also checks a signed update feed on its own schedule and offers new versions without ever installing one silently or mid-run. This closes the "signed native worker packaging and installation" item both `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` already list as release-gated.

## Users

- The device operator who installs and runs the worker on the machine that holds the repository. Unlike `specs/33-local-worker-run-execution`'s operator, this person is not assumed to be comfortable with a terminal command; this slice exists to remove that assumption.
- The project owner or participant who opens the project's device setup, generates the pairing code, and clicks the dashboard's "Open in App" action to hand it to the installed app.

## In Scope

- Building a signed, notarized macOS `.app` that wraps the existing worker runtime, with no Dock icon or app-switcher entry.
- Packaging that `.app` into a drag-to-Applications `.dmg`.
- A menu-bar status item showing not-paired, pairing, connected, disconnected, and update-available states, with Open Dashboard and Quit actions.
- A custom URL-scheme handoff that lets the app complete pairing from a single click on the dashboard's existing pairing screen.
- Post-pairing setup: a native folder picker for the repository workspace and auto-detected coding-agent executable with manual fallback, finishing worker configuration without any manual path entry.
- Extending that dashboard pairing screen with the "Open in App" action and install-guidance fallback when the scheme cannot be resolved.
- Real Developer ID code signing and Apple notarization of the shipped artifact.
- A periodic, signed appcast check; downloading and signature-verifying a newer version; and a confirm-before-install update flow that defers while a run is active on that worker and preserves the stored pairing credential across the upgrade.

## Out of Scope

- Launch-at-login or any other automatic start at boot or login.
- Manual pairing-code entry inside the app; pairing works only through the dashboard's deep-link handoff.
- Windows and Linux worker packaging.
- Production hosting, domain, and CDN for the `.dmg` download and the appcast feed.
- Any change to the worker runtime's execution behavior that `specs/33-local-worker-run-execution` already approved.
- Revoking or rotating a pairing credential from the menu bar; that remains the dashboard's existing capability.
- Crash reporting, telemetry, or diagnostics beyond the status states this slice defines.
- Running more than one installed worker instance on one machine.
- Building the capability that lets an existing, normal hosted project connect to a worker for the first time (creating its `HostedLocalRepositoryBinding`, the record `specs/33-local-worker-run-execution`'s gateway-credential exchange requires to ever reach a connected run-execution state). Implementation preflight for Task 12 found this does not exist anywhere in the product today: the only function that creates that binding is `specs/06-project-portability`'s restore-from-backup flow, and it has no other real caller anywhere in `lib/`. This slice depends on that capability existing to demonstrate a fully organic, UI-only "Connected" journey, but does not provide it — building it is a separate, slice-sized specification's job, not this one. Owner assigned on 2026-08-24: `specs/37-hosted-local-repository-connection#Task 6`, a new specification that adds the missing first-connection entry from the hosted project's own page and consumes `specs/06-project-portability`'s existing validation and binding transaction unchanged.
- Keeping a paired worker's `last_seen_at` fresh while it is genuinely connected. Task 12's proof found only the accountless dev/test LiveView stand-in flow ever calls `Devices.Pairing.mark_seen/1` today; a genuinely connected real worker goes stale roughly 90 seconds after its last LiveView-driven refresh, so `HostedLocalRepositoryBindings.connection_state/3` reports it `:temporarily_unavailable` even while it is still live-connected. This slice depends on that liveness existing to keep a genuinely connected worker showing connected indefinitely, but does not provide it. Owner corrected on 2026-08-24 from `specs/33-local-worker-run-execution` to `specs/02-local-project-onboarding#Task 11`: `specs/33`'s own Implementation Boundary excludes `Devices.Pairing` and excludes changing the worker socket and channel, so it cannot own a fix that must reach `mark_seen/1`, and the failing case is a connected but *idle* worker that emits no run heartbeat at all. `specs/02` owns `LocalWorker.last_seen_at`, its staleness window, and the reachability policy that reads them, and had already recorded the real outbound transport as release-gated; it now closes this through the Registry-Derived Worker Liveness decision in its `design.md`.

## Primary Workflow

1. The operator downloads the signed `.dmg`, drags the app to Applications, and launches it. The menu bar shows "Not paired."
2. The project owner opens the project's device setup in the dashboard, generates a pairing code, and clicks "Open in App."
3. The operating system activates the installed app through its registered URL scheme, carrying the single-use pairing code and the project's identifier.
4. The app obtains the issued credential and worker identity from the control plane's pairing-completion endpoint; the menu bar shows "Paired, setting up…"
5. The app presents a native folder picker for the repository workspace and attempts to auto-detect a supported coding-agent executable, falling back to a manual path field only when detection finds none. Once both are resolved, the app stores the complete worker configuration and starts the worker runtime without requiring a relaunch; the menu bar shows "Connected" once the gateway dials in, and the dashboard shows the worker reachable.
6. The worker behaves exactly as `specs/33-local-worker-run-execution` already verified: it executes an approved run when a participant starts one.
7. The operator can quit from the menu bar at any time; if no run is active this stops the worker immediately, and the dashboard shows it unavailable. If a run is active, the app warns before stopping.
8. On its own schedule, the app checks the signed appcast. If a newer version is published, it downloads and verifies it, then shows an update-available prompt rather than installing it.
9. The operator confirms the update. If no run is active, it installs and relaunches on the new version with the same stored credential. If a run is active, the install is deferred until that run reaches a terminal state.

## Business Rules

- The shipped `.app` and `.dmg` are Developer ID–signed and notarized; an unsigned or ad-hoc build is never distributed to an operator.
- The app's only persistent native UI is the menu-bar status item: no Dock icon, no app-switcher entry, no standing application window. Standard system dialogs (the Quit confirmation, the post-pairing folder picker) are not a standing window and do not violate this rule.
- Pairing-code entry happens exclusively through the dashboard's deep-link handoff; the app never accepts a manually typed code.
- The app completes pairing over the network against the control plane's pairing-completion endpoint, authenticated by nothing beyond the single-use code itself; it never requires or assumes local database access. A refusal (expired, already-used, unknown, or malformed code) is generic and does not disclose which specific reason applied.
- After pairing yields a credential, the app never asks the operator to type a filesystem path: the repository is chosen through a native folder picker, and the coding-agent executable is auto-detected, with manual entry offered only when auto-detection finds none.
- The app never registers itself to start automatically at login or boot.
- Quitting stops the worker process without revoking its stored credential. Quitting while a run is active on that worker warns the operator before stopping it.
- The app checks for updates on a periodic background schedule, verifies an offered update's signature before showing it, and never installs an update without the operator's explicit confirmation.
- A confirmed update installs immediately when no run is active, and is deferred until the run reaches a terminal state when one is active on that worker.
- Installing an update preserves the existing stored pairing credential unchanged.
- The periodic update check sends only the app version and the coarse OS descriptors `specs/02-local-project-onboarding`'s outbound connection contract already approves; no device, workspace, project, or credential identifier is included.

## Acceptance Criteria

- [AC-01] Given the built `.app`, when its bundle metadata is inspected, then it declares the approved bundle identifier, a semantic version, `specs/02-local-project-onboarding`'s approved minimum macOS version, and no Dock icon or app-switcher entry.
- [AC-02] Given the signed `.app`, when packaged, then the resulting `.dmg` mounts on a supported macOS version and presents the app plus an Applications shortcut for a standard drag-to-install.
- [AC-03] Given the app launches with no stored worker credential, when the menu bar is opened, then it shows "Not paired" and offers only Open Dashboard and Quit.
- [AC-04] Given the app is running with no run active, when the operator chooses Quit, then the worker process stops immediately, the dashboard's connection status transitions to unavailable, and the stored pairing credential is left intact for the next launch.
- [AC-05] Given a run is active on this worker, when the operator chooses Quit, then the app warns before stopping the process rather than stopping it immediately.
- [AC-06] Given a project's device-setup entry point, when the operator clicks "Open in App," then the installed app is activated through its registered URL scheme carrying the current single-use pairing code and that project's identifier, and a machine with no installed app shows install guidance instead of a silent failure.
- [AC-07] Given the app receives a valid, unexpired, unused pairing payload through its URL scheme, when pairing completes, then the app obtains the issued credential and worker identity from the pairing-completion endpoint, proceeds to post-pairing setup, and the menu bar shows "Paired, setting up…"
- [AC-08] Given the app receives an expired, already-used, or malformed pairing payload through its URL scheme, when pairing is attempted, then the app reports the specific failure in the menu bar without storing a credential and without crashing.
- [AC-09] Given the configured Developer ID signing identity, when the release build runs, then the `.app` and every embedded executable are deep-signed with the hardened runtime enabled and no entitlement beyond outbound networking and the embedded runtime's own JIT execution.
- [AC-10] Given the signed `.dmg`, when submitted for Apple notarization, then the returned ticket is stapled to the artifact and a Gatekeeper assessment accepts it with no warning.
- [AC-11] Given the app is running, when its periodic background schedule elapses, then it fetches the signed appcast, verifies any entry's signature before trusting it, and takes no action when no newer version is published.
- [AC-12] Given the appcast reports a newer, signature-valid version, when the app detects it, then it downloads and verifies the update and shows a menu-bar prompt rather than installing it automatically.
- [AC-13] Given an offered update and no run active on this worker, when the operator confirms it, then the update installs, the app relaunches on the new version, and the stored pairing credential survives the upgrade unchanged.
- [AC-14] Given an offered update and a run active on this worker, when the operator confirms it, then the install is deferred until the run reaches a terminal state rather than interrupting it.
- [AC-15] Given the periodic update check runs, when it contacts the appcast, then only the app version and the coarse OS descriptors already approved for outbound worker metadata are sent, with no device, workspace, project, or credential identifier included.
- [AC-16] Given the slice's own signed, stapled `.dmg`, when the operator mounts it, drags the app to Applications, launches it, pairs through the dashboard's deep link, and later quits, then every transition — not paired, connected, unavailable — is visible in both the menu bar and the dashboard, with no terminal command used at any step.
- [AC-17] Given a valid, unexpired, unused pairing code, when the control plane's network-facing pairing-completion endpoint receives it, then it completes the same pairing exchange `specs/02-local-project-onboarding`'s pairing contract already defines and returns the issued worker credential and identity, authenticated by nothing beyond that single-use code.
- [AC-18] Given an expired, already-used, unknown, or malformed pairing code, when that endpoint receives it, then the request is refused with a generic failure that does not disclose which specific reason applied, and no credential is issued.
- [AC-19] Given pairing has yielded a credential, when the app begins post-pairing setup, then it presents a native folder picker for the repository workspace, with no manual path entry required.
- [AC-20] Given a repository folder has been selected, when the app resolves the coding agent, then it attempts to auto-detect a supported coding-agent executable and offers manual path entry only when auto-detection finds none.
- [AC-21] Given a repository folder and a coding-agent executable are both resolved, when setup finishes, then the complete worker configuration is stored worker-locally and the worker runtime starts under the app's already-running process without requiring a relaunch.

## Open Questions

- None.
