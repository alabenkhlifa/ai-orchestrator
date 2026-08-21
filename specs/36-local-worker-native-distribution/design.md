# Local Worker Native Distribution Design

## Context

`specs/33-local-worker-run-execution` delivered and verified the worker's actual execution behavior — pairing exchange, gateway dial, run execution, evidence upload — as a developer-run process started from this repository's toolchain (`mix worker.pair`, `mix worker.start`). `specs/02-local-project-onboarding` already committed to the target packaging shape ("macOS Worker Packaging": a Developer ID–signed, notarized `.app` in a `.dmg`, updated through a signed appcast) and built a `:device_worker_stub` dev/test stand-in so the graphical pairing UI is exercisable without a real signed binary. Both specs list "signed native worker packaging and installation" as an identical release-gate item. This slice builds that packaging and, because the accountable owner now has Apple Developer credentials, performs the real signing and notarization as part of its own verification rather than deferring it again.

## Proposed Approach

Wrap the existing worker release in a minimal native macOS shell rather than reimplementing any execution logic. The shell owns exactly four things: process lifecycle (launch the embedded `mix release` build, supervise it, stop it on Quit), the menu-bar status UI, the custom-URL-scheme pairing handoff, and the update check/apply flow. It never reimplements pairing, gateway, or run-execution logic — those stay owned by `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` and are only invoked, over the network where the shell is a genuinely separate process from the control plane, or observed.

`specs/02-local-project-onboarding`'s `Pairing.complete_pairing/2` has so far only ever been called in-process — by the developer-run `mix worker.pair` task (which starts the whole control-plane application, including its database, alongside the worker: viable only because that task and the control plane share one repository checkout) and by `LocalOnboardingLive` through the `:device_worker_stub` dev/test stand-in. A packaged worker distributed to an operator's Mac is a genuinely separate process with no local database and no access to the control plane's, so this slice adds the network-facing endpoint that lets it complete pairing remotely, calling that same existing function unchanged — the same pattern `specs/33-local-worker-run-execution` already used for its own post-pairing gateway-credential exchange.

Pairing-code entry itself is still deep-link-only: the dashboard's existing pairing screen gains an "Open in App" action using a registered custom URL scheme, so the app needs no manual-entry UI at all — it hands the code to the new network endpoint instead of a local function call. The appcast is a public, unauthenticated, versioned feed; the app's periodic check sends nothing beyond the app version and the coarse OS descriptors `specs/02-local-project-onboarding`'s outbound connection contract already approves.

The credential the pairing exchange yields is not by itself enough to start the worker runtime: `specs/33-local-worker-run-execution`'s `Configuration` also requires a repository path and a coding-agent executable, today only ever supplied as CLI flags (`mix worker.pair --workspace-root ... --agent-executable ...`). A real non-technical operator cannot type either, so pairing is followed by a distinct post-pairing setup step — a native folder picker for the repository and an auto-detected coding-agent executable with manual fallback — before the complete configuration is stored and the worker runtime starts under the app's already-running process.

## Components Affected

- A new native macOS shell (menu-bar app) wrapping the existing worker release.
- Build tooling: `.app` assembly, `.dmg` packaging, code signing, notarization/stapling.
- A new network-facing pairing-completion endpoint on the control plane, consuming `specs/02-local-project-onboarding`'s existing `Pairing` context unchanged.
- Post-pairing setup: a native folder picker and coding-agent auto-detection that finish populating and store `specs/33-local-worker-run-execution`'s `Configuration`, then start the worker runtime.
- The signed appcast feed and the shell's periodic update check and apply flow.
- `specs/02-local-project-onboarding`'s existing pairing-code screen, extended (not redefined) with the deep-link action and an install-guidance fallback.
- The custom URL-scheme registration consumed by that dashboard screen.

## Data and Access Boundaries

- `WorkerAppRelease`: one published, signed, notarized worker build — semantic version, minimum supported macOS version, a signature/notarization reference, and publish time. Public release metadata; not personal data.

Required boundaries:

- The periodic appcast check is unauthenticated and public. It carries only the app version and the coarse OS descriptors (`os_family`, `os_major`) `specs/02-local-project-onboarding`'s Minimum Outbound Connection Contract already approves for outbound worker metadata — never a device, workspace, project, or credential identifier. It introduces no new personal-data field: the fields it sends are the same coarse compatibility descriptors that contract already treats as non-identifying.
- The URL-scheme pairing payload carries only the single-use pairing code `specs/02-local-project-onboarding`'s pairing contract already defines, plus the project identifier the new project-scoped device-setup entry point always has in context. Activation is local OS inter-process communication, not a network transmission.
- Post-pairing setup writes the same `Configuration` entity `specs/33-local-worker-run-execution` already defines and stores worker-locally; no new entity or field is introduced, and that entity's schema, storage location, and ownership are unchanged. The selected repository path never leaves the device — it is written only to the local `Configuration` file, matching `specs/02-local-project-onboarding`'s existing "source stays local" boundary.
- The new pairing-completion endpoint accepts and returns nothing beyond what `Pairing.complete_pairing/2` already accepts and returns today; it introduces no new personal-data field and no new authorization mechanism beyond the single-use code itself, matching the existing local-call contract exactly. A refusal never discloses which specific reason applied (expired, already-used, unknown, or malformed), matching this project's established non-disclosure convention for authorization refusals (for example `specs/33-local-worker-run-execution` AC-02).
- Code-signing and notarization credentials (Apple Developer Team ID, signing certificate, notary API key) are build-time secrets held outside the repository and outside any committed configuration; they are never embedded in the shipped binary, logged, or included in a proof receipt.
- The stored worker credential's custody (worker-local keychain, `specs/33-local-worker-run-execution` AC-03) is unchanged by this slice. Packaging and the update-apply flow must preserve that credential across an in-place reinstall, never duplicate or relocate it.

## Interfaces

- App-bundle build interface: assembles the existing worker release into a signed `.app` with the approved bundle identity.
- DMG packaging interface: produces the drag-to-Applications disk image from the signed `.app`.
- Notarization interface: submits the `.dmg`, polls for the notary ticket, and staples it.
- Menu-bar status interface: renders not-paired, pairing, connected, disconnected, and update-available states; exposes Open Dashboard and Quit.
- Pairing-completion interface: a network-facing endpoint that accepts a single-use pairing code and calls `Pairing.complete_pairing/2` unchanged, returning the issued credential and worker identity or a generic refusal.
- URL-scheme pairing interface: receives and validates a pairing payload, submits it to the pairing-completion interface, and reports a typed outcome.
- Post-pairing setup interface: native folder selection for the repository workspace, coding-agent auto-detection with manual fallback, and finalized `Configuration` storage and worker-runtime start.
- Dashboard deep-link interface: renders the "Open in App" action and the install-guidance fallback on the existing pairing screen without changing that screen's own contract.
- Appcast interface: publishes and fetches the signed release feed.
- Update-apply interface: downloads, verifies, and installs a newer signed build, deferring while a run is active on that worker.

## Decisions and Tradeoffs

### Network-Facing Pairing-Completion Endpoint, Owned By This Slice

- Choice: Add a new, unauthenticated-except-by-code network endpoint that calls `specs/02-local-project-onboarding`'s existing `Pairing.complete_pairing/2` unchanged, rather than assuming the packaged app can reach that function some other way.
- Reason: Preflight found that pairing completion has only ever been called in-process — by the developer-run `mix worker.pair` task (which starts the whole control-plane application, including its database, alongside the worker) and by the dashboard's own dev/test worker stand-in. A packaged worker on an operator's Mac is a genuinely separate process with no local database and must never be given one, so it needs a real network path. `specs/33-local-worker-run-execution` already established the precedent for this shape: it built its own network-facing endpoint (`worker_gateway_credential_controller.ex`) consuming `specs/02-local-project-onboarding`'s existing authorization functions rather than requiring that slice to have pre-built one. This does not redefine `specs/02-local-project-onboarding`'s pairing schema, interface, or lifecycle — it only adds a transport that calls it.
- Consequence: This slice owns a new Phoenix controller action and its focused proof, in addition to the native-side URL-scheme handler. The endpoint accepts and returns exactly what the existing local call already does and refuses generically (no reason disclosure) on any failure, matching this project's established authorization-refusal convention.

### Native Folder Picker And Auto-Detected Coding Agent For Post-Pairing Setup

- Choice: Once the deep-link pairing exchange yields a credential, present a native folder picker for the repository workspace, then attempt to auto-detect a supported coding-agent executable (checking common install paths and `which`), falling back to a manual path field only when detection finds none, before finalizing and storing the complete `Configuration` and starting the worker runtime under the app's already-running process.
- Reason: `specs/33-local-worker-run-execution`'s `Configuration` requires `workspace_root`, `agent_adapter`, and `agent_executable` as non-nil fields, and today those are supplied only as CLI flags — a real non-technical operator cannot type a filesystem path or locate an executable. Neither `specs/02-local-project-onboarding` nor `specs/33-local-worker-run-execution` resolved how a graphical flow collects these; both explicitly deferred "the non-developer pairing flow" to this slice. This finally implements the native folder-picker capability `specs/02-local-project-onboarding`'s own design already flagged as release-gated pending a real native worker. Confirmed with the accountable owner rather than assumed, since the alternative (deferring workspace/agent setup out of this slice entirely) was a real, materially different option.
- Consequence: The URL-scheme pairing handoff (owning the credential exchange itself) is a separate task from this setup step, since storing a complete `Configuration` needs information pairing alone doesn't provide. `Configuration`'s existing schema, storage location, and ownership are unchanged — this only adds the graphical mechanism that populates it. Auto-detection can fail on a nonstandard install; the manual fallback path must stay genuinely usable, not a dead end.

### Project-Scoped Device-Setup Entry Point, Added By This Slice

- Choice: Add a device-setup action on the existing per-project dashboard (`DeviceProjectDashboardLive`) that carries this project's identifier into `specs/02-local-project-onboarding`'s pairing screen, rather than assuming that screen already has a project in context. The "Open in App" deep-link action renders only from this new entry point; `specs/02-local-project-onboarding`'s other, already-approved generic entry points are unchanged and never render it.
- Reason: Pairing is workspace-scoped, not project-scoped (`specs/02-local-project-onboarding`'s own design: "Pairing grants one workspace access to one worker"), and preflight found no existing UI path from an already-created project to a pairing action that knows which project it is. `specs/33-local-worker-run-execution`'s own primary workflow assumes exactly this path ("a project owner opens the project's device setup"), so it must exist for this slice's outcome to be reachable at all.
- Consequence: This slice's Task 6 owns a small dashboard addition in addition to the deep-link action itself. Because the deep link is only ever rendered from this one project-scoped entry point, it always carries a project identifier — Task 4's URL-payload parser, already built, correctly treats a missing one as malformed rather than needing to tolerate an absent value.

### Real Signing And Notarization In This Slice

- Choice: Perform real Developer ID signing and Apple notarization as part of this slice's own tasks and verification, not the release gate.
- Reason: The accountable owner has the required Apple Developer Program credentials now, so deferring signing again would just repeat the placeholder both `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` already carry.
- Consequence: The tasks that perform signing and notarization require those credentials to be present in the build environment; if they are not available in a given implementation session, those tasks become environment-blocked rather than a design defect, per this project's established environment-blocker handling. What remains release-gated is a live install proof on a machine other than the development machine and production hosting for the artifacts, not the signing mechanism itself.

### The Entitlement Set Includes JIT Execution, Not Networking Alone

- Choice: Sign with exactly two entitlements — `com.apple.security.network.client` and `com.apple.security.cs.allow-jit` — not networking alone as originally scoped.
- Reason: Implementation found that the embedded BEAM VM's JIT compiler cannot allocate executable+writable memory under Hardened Runtime without `allow-jit`; the process aborts on launch (confirmed by a real crash, `beam/jit/beam_jit_main.cpp:pick_allocator(): Internal error: jit: Failed to allocate executable+writable memory`, reproduced independently). This is not a design preference to weigh — the worker cannot run at all without it, and `specs/33-local-worker-run-execution` already established BEAM as the runtime this slice packages, unchanged. `allow-jit` is Apple's own purpose-built entitlement for exactly this case (any JIT-compiling language runtime — the JVM, Node.js, PyPy, and others all require it under Hardened Runtime); it grants only the ability to allocate W^X memory for the app's own process, not a broader capability, and does not on its own weaken the sandbox against any other class of attack. Two narrower entitlements considered and rejected as insufficient during investigation: `allow-unsigned-executable-memory` and `disable-library-validation` were not needed once `allow-jit` was added.
- Consequence: AC-09's "no entitlement beyond outbound networking" is corrected to "beyond outbound networking and the embedded runtime's own JIT execution." The notarization-rejection risk this slice already accepted for hardened runtime in general (see the decision above) extends to this one additional, standard entitlement; nothing else changes about the minimal-entitlement posture.

### Minimal Native Shell Wrapping The Existing Elixir Release

- Choice: Use a small native macOS shell (Swift/AppKit) whose only jobs are process lifecycle, the menu-bar UI, the URL-scheme handoff, and the update flow; it launches and supervises the existing worker runtime rather than reimplementing any worker behavior. That runtime ships as a new, separate `:worker` `mix release` target — no `releases:` key or `rel/` overlay exists in this repository today, so this slice creates one — booted through a runtime mode gate (an env var an overlay sets for that release only) so its `SddOrchestrator.Application.start/2` path starts only `SddOrchestrator.Worker.Supervisor` and never starts `SddOrchestratorWeb.Endpoint`, `SddOrchestrator.Repo`, or any other control-plane process. Mix releases include or exclude whole OTP applications, not individual modules within `:sdd_orchestrator` itself, so the release still contains the compiled control-plane code on disk; what this decision guarantees is that the worker process never starts it, never opens a database connection, and never binds a port — not that the control-plane source is absent from the binary. A full compile-time separation would need splitting the control plane and the worker into distinct OTP applications, which is a larger, separate undertaking outside this slice.
- Reason: `specs/33-local-worker-run-execution`'s worker runtime is already implemented and `Verified`; re-deriving pairing, gateway, or run-execution logic natively would duplicate an already-proven contract and risk drift between two implementations of the same behavior. Never starting the control-plane processes is the achievable least-privilege boundary for this slice, distinct from — and in addition to — the credential-custody boundary `specs/33-local-worker-run-execution` already established.
- Consequence: The build environment needs both the existing Elixir/mix toolchain and a Swift/Xcode toolchain. `Mix.Tasks.Worker.Pair`'s and `Mix.Tasks.Worker.Start`'s existing behavior for the developer-run, same-checkout form factor is unchanged; the new release target is an additional, separate build product for distribution, not a replacement for those tasks. The shell must treat the embedded release as an opaque child process it starts, stops, and observes for status — never a component it reimplements. Full compile-time exclusion of control-plane code from the distributed binary is a candidate future hardening step, not required by this slice's accepted outcome.

### Menu-Bar-Only Native Surface

- Choice: The app runs as a menu-bar (agent) app with `LSUIElement` set: no Dock icon, no app-switcher entry, no separate window.
- Reason: This matches the established non-technical, no-terminal expectation from `specs/02-local-project-onboarding` while giving the operator a lightweight way to see status and stop the worker without the dashboard open — the same pattern as other background utility apps.
- Consequence: All native UI (status, Open Dashboard, Quit, update prompt) must fit in a menu-bar popover; there is no window-based settings surface to fall back on for this slice.

### Deep-Link-Only Pairing

- Choice: Pairing-code entry happens exclusively through a custom-URL-scheme handoff from the dashboard's existing pairing screen; the app has no manual "enter code" UI.
- Reason: The dashboard already generates and displays the pairing code; a redundant native entry form adds a second surface to build, secure, and keep consistent with the existing single-use/expiry rules for no product benefit when the operator's browser and worker run on the same machine, which pairing already requires.
- Consequence: Pairing depends on the dashboard being opened in a browser on the same machine as the installed worker. If a later slice's evidence shows this is insufficient (for example, the browser and worker legitimately run on different machines), adding a manual fallback is a scoped follow-up, not a redefinition of this slice's contract.

### No Launch-At-Login

- Choice: The app never registers a login item or `LaunchAgent`; the operator starts it manually.
- Reason: Keeps this slice's footprint minimal — no persistent background registration to install, explain, or let the operator disable — and avoids a product decision about always-on background execution that was not asked for.
- Consequence: The worker is reachable only while the operator has explicitly launched the app. Quit fully stops it: there is no separate "minimize to background at boot" behavior to design or code-sign around.

### Prompted, Signature-Verified Auto-Update With Active-Run Deferral

- Choice: The app checks a signed appcast on a periodic background schedule, verifies any candidate update's signature before showing it, and only installs after the operator confirms — immediately if idle, deferred until the run reaches a terminal state if a run is active on that worker.
- Reason: `specs/02-local-project-onboarding` already committed to "a signed in-app update check (appcast)" without specifying auto-apply behavior; silently replacing a running worker mid-attempt could corrupt or interrupt a real run `specs/33-local-worker-run-execution` is executing.
- Consequence: The update-apply flow must reuse the same active-run check Quit uses, and an offered update can sit pending until the operator confirms and, if needed, until the run finishes.

### Public, Unauthenticated Appcast

- Choice: The appcast is a public, unauthenticated static feed; the periodic check is a plain fetch carrying only the app version and coarse OS descriptors.
- Reason: This is the standard shape for a software-update feed and avoids inventing a new authenticated data flow or a new personal-data category for a background version check.
- Consequence: The appcast's integrity depends entirely on its own signature scheme (verified before any update is offered or installed), not on transport authentication.

## Risks

- Apple may reject notarization for policy reasons unrelated to code correctness (for example, entitlement review). Keep the entitlement set minimal — outbound networking only — to reduce rejection risk.
- Another app could register the same custom URL scheme. macOS resolves scheme conflicts by installation recency or a user prompt, which this slice cannot fully control; keep the pairing payload single-use and short-lived, exactly as the existing pairing contract already requires, so a hijacked open cannot replay an old code.
- An update applied mid-run despite the defer rule could corrupt run state. Gate the install action itself on the same run-state check Quit uses, not merely a UI warning that the operator can dismiss.
- Losing custody of the signing certificate or notary credentials blocks future releases entirely; their ongoing operational custody is outside this slice's boundary.
- Signing and notarization tasks require the accountable owner's Apple Developer credentials in the build environment; if unavailable in a given implementation session, treat those tasks as environment-blocked rather than reworking their design.
- Coding-agent auto-detection may find no installed agent, or find a version incompatible with what the worker runtime expects; the manual-entry fallback and the agent adapter's own existing installed-version check (`specs/33-local-worker-run-execution` AC-09/AC-10) are the mitigation, not silent acceptance of an unverified path.
- Exposing pairing completion over the network for the first time is a new public attack surface. The pairing secret itself is already a 32-byte cryptographically random value compared in constant time (`specs/02-local-project-onboarding`'s `Pairing` implementation), so brute-forcing it within its short expiry is not practical; this slice does not need to strengthen that entropy, only avoid weakening it (no reason disclosure on refusal, no logging of raw codes).
- No production code path in this repository lets an existing, normal hosted project connect to a worker for the first time (see requirements.md's Out of Scope). Concretely, this means the deep-link pairing flow this slice builds — regardless of which dashboard renders the "Open in App" action, accountless or hosted — always produces a worker that pairs and runs post-pairing setup successfully, but whose `GatewayConnection` can never complete its own project-scoped gateway-credential exchange for a normal project, so it never reaches the run-execution-connected state `SddOrchestrator.Worker.ConnectionStatus` reports. Task 12's own proof works around this by constructing a `HostedLocalRepositoryBinding` directly (the same production function, `HostedLocalRepositoryBindings.put_validated_binding/6`, this project's own test suite already uses to prove `WorkerGatewayCredentialController`) rather than through a UI action, since no such UI exists yet anywhere to trigger. Reaching that binding function also required a second real project-scoped id: `LocalOnboardingLive`'s `?project=` deep-link resolution only ever looks up an accountless `Devices.DeviceProject` (`Devices.get_project/1`), never a hosted `Projects.Project`, so Task 12's proof drove the real deep-link/pairing UI through an accountless device-project id and gave the paired hosted project that exact same id (a real accountless project and a real hosted project sharing one UUID) so the worker's own genuine, unmodified pairing payload naturally satisfied the binding's real foreign key. This is a real, external prerequisite gap, not a defect in this slice's own delivered code; closing it is out of this slice's boundary (see requirements.md's Out of Scope).
- `GatewayConnection` (`specs/33-local-worker-run-execution`) never calls `Devices.Pairing.mark_seen/1` on its own outbound transport — only the accountless dev/test LiveView stand-in flow does. Discovered during Task 12's proof: a genuinely paired and connected worker's `last_seen_at` goes stale roughly 90 seconds after its last LiveView-driven refresh, so `HostedLocalRepositoryBindings.connection_state/3` (and any future dashboard reading through it) reports `:temporarily_unavailable` for a worker that is, in reality, still live-connected. The state-derivation logic itself is correct (confirmed by calling `mark_seen/1` directly and observing the state immediately flip to `:connected`); the missing piece is a periodic real heartbeat call from the real connection process. This is a `specs/33-local-worker-run-execution` gap, out of this slice's boundary.

## Open Questions

- None.
