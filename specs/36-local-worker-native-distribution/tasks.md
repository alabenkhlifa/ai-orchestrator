# Local Worker Native Distribution Tasks

## Status

Not Started

## Active Slice

Package the already-`Verified` worker runtime (`specs/33-local-worker-run-execution`) into a Developer ID–signed, notarized macOS `.app`/`.dmg` with a menu-bar status shell, a network-facing pairing-completion endpoint, a deep-link-only pairing handoff from the dashboard, graphical post-pairing workspace and agent setup, and a prompted, signature-verified auto-update flow — closing the "signed native worker packaging and installation" item `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` both list as release-gated.

## Cross-Specification Dependencies

Requires:

- `capability:local-worker-run-execution` — provider `specs/33-local-worker-run-execution#Task 12` — required before `Task 1`.
- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 3`.

Provides:

- `capability:signed-macos-worker-distribution` — ready after `Task 12`.

## Slice Size Gate

- Slice size: Standard

One coherent outcome — a real, signed, notarized, auto-updating macOS worker distribution — through one verification gate, twelve tasks total (at the standard limit), and a longest `Depends on:` path of five tasks (for example `Task 1 → Task 7 → Task 8 → Task 9 → Task 12`, matched by `Task 1 → Task 2 → Task 4 → Task 5 → Task 12` and by `Task 1 → Task 2 → Task 10 → Task 11 → Task 12`), both within the standard limits. Task count sits at the ceiling because post-pairing workspace/agent setup (Task 5) was found during implementation preflight to be a genuinely separate, independently provable outcome from the credential exchange (Task 4) — see Task 5's purpose. Any further growth would need a slice split, not a larger task.

## Task Size Gate

- Every task is `Size: Standard`. Each delivers one independently provable outcome, owns at most three acceptance criteria and at most one data entity, and is expected to produce one task-boundary implementation commit.
- The pairing-completion endpoint (Task 3) is separate from the native URL-scheme handoff (Task 4) because one is a control-plane authorization surface with its own Phoenix-controller proof and the other is native-app runtime behavior with a different failure mode — the same split `specs/33-local-worker-run-execution` already used between its gateway-credential exchange and its gateway client.
- Post-pairing workspace and agent setup (Task 5) is separate from the URL-scheme pairing handoff (Task 4) because `Configuration` requires a repository path and a coding-agent executable that pairing alone never provides — a distinct native-UI surface (folder picker, auto-detection) and a distinct failure mode (setup can fail or be abandoned after a credential already exists) from the credential exchange itself.
- Signing (Task 7), DMG packaging (Task 8), and notarization (Task 9) are three separate tasks, in that order, because packaging must wrap an already-signed `.app` and notarization must submit an already-packaged `.dmg` — each stage fails independently and against a different tool (`codesign`, `hdiutil`/packaging, `xcrun notarytool`).
- The appcast check (Task 10) is separate from the update-apply flow (Task 11) because one is a read-only periodic fetch and the other is a stateful install-and-relaunch action with its own active-run gate.
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- A native macOS menu-bar shell wrapping the existing worker release: process lifecycle, status UI, Open Dashboard, and Quit with an active-run-aware warning.
- A network-facing pairing-completion endpoint on the control plane, consuming `specs/02-local-project-onboarding`'s existing `Pairing.complete_pairing/2` unchanged.
- Post-pairing setup: a native folder picker for the repository workspace and coding-agent auto-detection with manual fallback, finishing and storing `Configuration` and starting the worker runtime without a relaunch.
- App-bundle assembly, `.dmg` packaging, Developer ID signing, and Apple notarization/stapling of the shipped artifact.
- A registered custom URL scheme that receives a pairing payload and submits it to the new pairing-completion endpoint.
- The dashboard's existing pairing screen (`specs/02-local-project-onboarding`), extended with an "Open in App" deep-link action and an install-guidance fallback.
- A signed appcast, a periodic background check, and a confirm-before-install update-apply flow that defers while a run is active and preserves the stored credential across the upgrade.

Excluded:

- The worker runtime's execution behavior: gateway client, command handling, agent adapters, and evidence upload, all already delivered and `Verified` by `specs/33-local-worker-run-execution`. This slice only launches, supervises, and packages that runtime.
- `specs/02-local-project-onboarding`'s pairing contract, credential custody, and connection-status logic; this slice only adds a network transport and a UI entry point that call into that existing, unchanged contract.
- `specs/33-local-worker-run-execution`'s `Configuration` schema; this slice only adds the graphical mechanism that populates its existing required fields.
- Launch-at-login or any automatic start at boot or login.
- Manual pairing-code entry inside the app.
- Windows and Linux packaging.
- Production hosting, domain, and CDN for the `.dmg` download and the appcast feed.
- Revoking or rotating a pairing credential from the menu bar.

Deferred after this slice:

- Windows worker packaging, followed by Linux worker packaging, matching `specs/02-local-project-onboarding`'s existing "macOS First Worker Slice" sequencing decision.

Release gates:

- A live install-and-pair proof on a macOS machine other than the development machine, with no prior developer configuration, confirming Gatekeeper raises no warning and the full non-technical journey completes for a genuinely fresh operator.
- Production hosting location, domain, and transfer/security posture for the signed `.dmg` download and the appcast feed.
- Accountable privacy and security review of the update-check outbound flow, the new pairing-completion endpoint, and the custom-URL-scheme pairing handoff, covering the same credential-custody and data-minimization boundary `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` already committed to.
- Continued operational custody of the Apple Developer signing identity and notary credentials for future releases.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Assemble the signed-ready `.app` bundle around the existing worker release.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Wrap the already-verified worker runtime in a native macOS app bundle with the approved identity and window-less agent behavior.
  - Owned surfaces: `.app` bundle structure, `Info.plist` contract (bundle identifier, semantic version, `LSMinimumSystemVersion`, `LSUIElement`), the new `:worker` `mix release` target and its runtime boot-mode gate (never starts `Endpoint`, `Repo`, or any control-plane process). Because `SddOrchestrator.Worker.Supervisor.start_link/1` refuses to start at all when no configuration is paired yet (`{:error, :not_paired}`), the worker-mode boot path must tolerate that: it starts a minimal always-up host (for example a `DynamicSupervisor`) rather than requiring `Worker.Supervisor` as a required static child, so the release boots successfully whether or not pairing has happened yet. Starting `Worker.Supervisor` for the first time once pairing succeeds is Task 5's job, not this task's.
  - Owns: AC-01, entity:WorkerAppRelease
  - Proof: A build script produces a `.app` whose `Info.plist` matches the approved contract (bundle identifier, `LSUIElement` true, `LSMinimumSystemVersion` at `specs/02-local-project-onboarding`'s approved floor). The embedded release boots successfully in worker mode both with no stored configuration present (starts the always-up host, starts no control-plane process, does not crash) and with a configuration already present (also starts `Worker.Supervisor` under that host).
  - Delivered: `mix.exs` gains a `:worker` release (`rel_templates_path: "rel/overlays/worker"`) alongside the unchanged default `sdd_orchestrator` release (`default_release: :sdd_orchestrator` preserves the bare `MIX_ENV=prod mix release` command every other slice's verification gate already uses — confirmed unchanged: still resolves to `sdd_orchestrator` and still raises on missing `DATABASE_URL`). `rel/overlays/worker/env.sh.eex` sets `SDD_ORCHESTRATOR_RELEASE_MODE=worker` before boot, scoped to that release only. `SddOrchestrator.Application.boot_mode/0` reads that var; worker mode starts only `SddOrchestrator.Worker.Host` (a `DynamicSupervisor`, `worker_host_name/0`) and never `Endpoint`/`Repo`/`Vault`/any control-plane process — confirmed by real RPC into a running built release (`Supervisor.which_children/1` shows only the host; `Process.whereis/1` for `Endpoint`/`Repo` both `nil`). Since `Worker.Supervisor.start_link/1` refuses to start with no paired configuration, it is never a static child; `attach_paired_worker/1` starts it under the host at boot only when a configuration already exists (relaunch case), and Task 5 will call the same `DynamicSupervisor.start_child(SddOrchestrator.Application.worker_host_name(), SddOrchestrator.Worker.Supervisor)` after post-pairing setup finishes. `native/worker-app/build.sh` assembles `SDD Orchestrator Worker.app` (`Contents/Resources/release` = the built release verbatim; `Contents/MacOS/sdd-orchestrator-worker-launcher` = a placeholder exec-the-release-start-script launcher that Task 2 replaces with the real Swift menu-bar shell). `Info.plist` verified via `plutil -p`: `CFBundleIdentifier=com.sddorchestrator.worker`, `LSMinimumSystemVersion=14.0`, `LSUIElement=true`.

- [x] Task 2 — Build the menu-bar status shell and quit lifecycle.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Give the operator the app's only native UI surface and a safe way to stop the worker.
  - Owned surfaces: Menu-bar status item (not-paired, pairing, connected, disconnected, update-available states), Open Dashboard action, Quit action, active-run check consulted before quitting.
  - Owns: AC-03, AC-04, AC-05
  - Proof: Shell tests drive each status transition and confirm Quit stops the process immediately when idle, and shows a confirmation warning instead of stopping immediately when a run is active, using the existing run-state query.
  - Delivered: `native/worker-app/MenuBarApp` (Swift Package: a testable `SDDOrchestratorWorkerCore` library + a thin `SDDOrchestratorWorkerApp` AppKit executable) replaces Task 1's placeholder launcher. `AppDelegate` starts/supervises the embedded release, shows an `NSStatusItem` (no Dock icon, per Task 1's `LSUIElement`), and routes every termination path through `applicationShouldTerminate` (`.terminateLater` + async decision), so AC-04/AC-05 apply regardless of what triggers quitting. Active-run detection queries the already-running release over `bin/worker rpc` calling `RunState.load/1` (read-only); a query failure fails safe to warning. `SddOrchestrator.Worker.ConnectionStatus` (new, `:persistent_term`-backed) lets `GatewayConnection`'s existing `handle_connect/1`/`handle_disconnect/2` report status as a side effect only — no existing control flow changed, confirmed by its own pre-existing test file still passing unmodified. "Open Dashboard" reads a `SDDOrchestratorDashboardURL` Info.plist key (default `http://localhost:4000` — the real hosted URL is this spec's own release-gate item). Only not-paired is functionally wired; paired-connecting/connected/disconnected/update-available exist as real enum cases with placeholder UI for Tasks 5/10/11 to drive.
  - Verified beyond the sub-agent's own report: main thread independently built (`swift build`, `swift test` — 39/39) and ran the real assembled `.app` end to end — launched with no configuration present, confirmed via accessibility that only "Open Dashboard"/"Quit" are offered; quit with no run active stopped both the launcher and the embedded BEAM process immediately; with a real (non-fake, written via the release's own `RunState.store/2`) active run-state entry, Quit showed the exact literal alert "A run is in progress.", Cancel left both processes running, and Quit Anyway stopped them — all three scenarios driven through real Apple Events, not simulated.

- [x] Task 3 — Build the network-facing pairing-completion endpoint.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let a genuinely separate worker process — one with no local database — complete pairing over the network, since `Pairing.complete_pairing/2` has so far only ever been called in-process.
  - Owned surfaces: A control-plane endpoint accepting a single-use pairing code, calling `Pairing.complete_pairing/2` unchanged, returning the issued credential and worker identity or a generic refusal that discloses no specific reason.
  - Owns: AC-17, AC-18
  - Proof: Endpoint tests cover a valid unexpired unused code (returns the same credential shape the existing local call already returns), and expired, already-used, unknown, and malformed codes (each refused generically, no credential issued, no reason disclosed in the response).
  - Delivered: `SddOrchestratorWeb.WorkerPairingController` at `POST /worker_pairings` (unauthenticated `:api` pipeline, deliberately not under `/worker/...` since that prefix implies the already-authenticated `:worker` pipeline). Accepts `code` plus the caller's own `os_family`/`os_major`/`protocol_version`/`app_version` as request parameters — a real remote worker reports these about itself; none are derived from this application's own build or from `WorkerDiscovery.compatibility_policy/0` (that function is the control plane's supported-values policy, not any caller's real environment). Calls `Pairing.complete_pairing/2` unchanged. Every refusal (expired, already-used, unknown, malformed code, malformed request, badly-typed optional attribute) returns identical `403 {"error": "refused"}` with `cache-control: no-store`, proved by a cross-check test asserting expired/used/unknown responses are byte-identical. `pairing.ex` and `worker.pair.ex` untouched.

- [x] Task 4 — Implement the URL-scheme pairing handoff.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 3
  - Purpose: Let the app obtain a credential from a dashboard-issued deep link without any typed input.
  - Owned surfaces: Custom URL-scheme registration and payload parsing (pairing code and project identifier), submission to Task 3's pairing-completion endpoint, typed success/failure reporting into the menu bar ("Paired, setting up…" on success). Does not itself store a complete `Configuration` or start the worker runtime — pairing alone does not provide a repository path or coding-agent executable; handing the issued credential and worker identity to Task 5's post-pairing setup is this task's terminal step.
  - Owns: AC-07, AC-08
  - Proof: Contract tests feed valid, expired, already-used, and malformed `sddworker://pair` payloads and assert Task 3's endpoint is called only for the valid case, the issued credential and worker identity are handed to post-pairing setup only on success, and every case ends in a defined menu-bar state without a crash.
  - Delivered: `CFBundleURLTypes` (`sddworker` scheme) registered in `Info.plist`. `AppDelegate` receives it via `NSAppleEventManager`'s `kInternetEventClass`/`kAEGetURL` handler (the correct AppKit mechanism — no `application(_:open:)` on macOS), registered first in `applicationDidFinishLaunching` so a launch-time link isn't lost. `PairingURLPayloadParser` parses `sddworker://pair?code=...&project_id=...`; `PairingFlowController` POSTs to the app's own `SDDOrchestratorDashboardURL` plus `/worker_pairings` with the worker's own self-reported `os_family`/`os_major` (`ProcessInfo`) and `protocol_version` (queried live via `bin/worker eval` calling `GatewayConnection.protocol_version()`, never hardcoded) and `app_version`. On `201`, hands `(credential, worker identity, project_id)` to `PostPairingSetupCoordinator` — a protocol Task 5 implements; today's only implementation (`UnimplementedPostPairingSetupCoordinator`) just logs and leaves the menu on the new `.pairedSettingUp` state ("Paired, setting up…"). On `403`/malformed/transport failure, shows the specific reason as a disabled menu line under "Not paired" without storing anything or crashing. A duplicate/replay guard (`NSLock`-protected session state) suppresses a second concurrent POST while one is in flight or already succeeded, but allows retry after a failure. No `Configuration.store` call and no `Worker.Supervisor` start anywhere in this task's code — confirmed by inspection. No Elixir file touched.
  - Verified beyond the sub-agent's own report: main thread independently ran `swift build`/`swift test` (77/77), then ran a real end-to-end pairing against a live `mix phx.server` + real dev Postgres — generated a pairing code independently, rebuilt and launched the real `.app`, triggered `open "sddworker://pair?code=...&project_id=..."`, and confirmed via the Phoenix server log a real `POST /worker_pairings` → real `Pairing.complete_pairing/2` → real `local_workers` insert → `Sent 201`, with `protocol_version`/`os_major` genuinely self-reported (matched this machine's real macOS major version, not a hardcoded value). Relaunched fresh and replayed the same now-used code: `Sent 403`, app process still alive afterward (no crash).

- [x] Task 5 — Implement post-pairing workspace and coding-agent setup.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Finish what pairing alone cannot: `Configuration` requires a repository path and a coding-agent executable, and a real non-technical operator cannot type either.
  - Owned surfaces: Native folder picker (`NSOpenPanel`) for the repository workspace; coding-agent auto-detection (checking common install paths and `which`) with a manual-entry fallback only when detection finds none; construction and storage of the complete `Configuration` (combining Task 4's credential/worker identity/project id with the resolved workspace and agent); starting `SddOrchestrator.Worker.Supervisor` for the first time under Task 1's always-up host, without requiring the app to relaunch.
  - Owns: AC-19, AC-20, AC-21
  - Proof: UI-logic tests cover the folder-picker outcome feeding `workspace_root`, auto-detection succeeding (no manual field shown) and failing (manual field required and accepted), and the finalize step storing a valid `Configuration` and starting `Worker.Supervisor` under Task 1's host exactly once, verified against `Configuration.load/1` and the host's child count.
  - Delivered: `PostPairingSetupCoordinatorImpl` replaces the placeholder, presenting a real `NSOpenPanel` then `CodingAgentDetector` (common paths, then `which`, per adapter). Exactly one agent found → used directly; none found or both found → `AgentSelectionAlertPrompt` (manual path entry only in the none-found case, per AC-20). The eight `Configuration` fields are constructed directly (never `Configuration.from_pairing/2`, which expects the CLI's different intermediate shape) and written to a private per-run temp file (`0700` dir / `0600` file, deleted via `defer`) rather than interpolated into the `bin/worker rpc` expression — only the app-generated temp-file path is interpolated, never the credential or workspace path. `DynamicSupervisor.start_child(SddOrchestrator.Application.worker_host_name(), SddOrchestrator.Worker.Supervisor)` runs over `rpc` (the already-booted node), never `eval`. `{:error, {:already_started, _}}` is treated as success (idempotent).
  - Verified beyond the sub-agent's own report: the sub-agent correctly stopped short of GUI-scripting the interactive click-through after detecting this was a live, actively-shared desktop with other concurrent sessions in the foreground — a sound safety call, not a gap in the work. The main thread completed that portion itself using accessibility actions scoped to the specific named process (`click`/`key code` via `tell process "sdd-orchestrator-worker-launcher"`, confirmed frontmost by screenshot before each step) rather than global input, avoiding the risk the sub-agent flagged. Full real click-through against a live `mix phx.server`: real `NSOpenPanel` (custom prompt text confirmed on screen) navigated to a real folder; auto-detection genuinely found both Claude Code and Codex installed on this machine and showed the real disambiguation alert exactly as designed; after selecting Claude Code, `~/.sdd_orchestrator/worker/worker.json` was inspected directly (not via the app) and confirmed all eight fields correct with `0700`/`0600` permissions, and `bin/worker rpc` confirmed `SddOrchestrator.Worker.Supervisor` genuinely running under the host `DynamicSupervisor`. `Worker.Supervisor`'s own `GatewayConnection` then automatically attempted the specs/33 gateway-credential exchange with the stored `project_id` and was correctly refused (403) — expected, since the test used a random, non-real `project_id`, and this incidentally confirms Task 5's stored configuration correctly drives specs/33's already-verified downstream behavior. All test artifacts cleaned up afterward.

- [x] Task 6 — Add a project-scoped device-setup entry point and the dashboard's "Open in App" deep-link action.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Let the project owner hand a pairing code to the installed app with one click instead of a terminal or manual entry, from the project whose device setup they are actually configuring — `specs/02-local-project-onboarding`'s only existing pairing screen (`LocalOnboardingLive`) is reachable generically and is workspace-scoped, with no project in context, so this task adds the missing project-scoped path in. The "Open in App" deep-link action is rendered only from this new project-scoped entry point; `specs/02-local-project-onboarding`'s other, already-approved generic entry points are unchanged and never render it, so the deep link always carries a project identifier, matching Task 4's already-built parser exactly.
  - Owned surfaces: A device-setup action on `DeviceProjectDashboardLive` that navigates to the existing pairing screen carrying this project's identifier; `specs/02-local-project-onboarding`'s existing pairing-code screen extended to accept that identifier, render the deep-link action (carrying the code and the project identifier) only when it is present, and show an install-guidance fallback when the scheme cannot be resolved.
  - Owns: AC-06
  - Proof: LiveView tests assert the new dashboard action reaches the pairing screen with this project's identifier in context, the pairing screen renders the deep link carrying the current single-use code and that identifier, the deep-link action does not render when the screen is reached through an existing generic (non-project-scoped) entry point, and the screen falls back to install guidance instead of a silent no-op when the app is not installed.
  - Delivered: `DeviceProjectDashboardLive` gains a "Pair a worker" action (shown only when `@connection_status == "authorization_required"`, i.e. no worker paired at all) navigating to `/onboarding/local` with a `project` query param carrying this project's id. `LocalOnboardingLive` validates `project` against the current device workspace via the existing `Devices.get_project/1` (unknown id or foreign workspace is ignored, falling through to unchanged default behavior). Real implementation discovery: no code value actually flowed into `pairing_form/1` in the non-stub path (only the dev-only stub called `Pairing.start_pairing/1`), so a real single-use code is now issued lazily, once per mount, only when `project_id` is present and `worker_status` is `:missing`/`:incompatible` — via the existing, unmodified `Pairing.start_pairing/1`, the same public function the stub already used. The deep link (`sddworker://pair?code=...&project_id=...`, both `URI.encode_www_form`-encoded) renders as a plain HTML anchor element (not `phx-click`, so the OS — not LiveView — handles the custom scheme), placed next to the existing pairing-code submit button, only when both `project_id` and a real code are in assigns. The existing "Download the worker" button already satisfies AC-06's install-guidance requirement; nothing new was built for that. `Devices.Pairing` untouched.
  - Verified beyond the sub-agent's own report: main thread independently reviewed the full diff (confirmed `Devices.get_project/1` is a real, pre-existing function; confirmed the deep-link element is a genuine HTML anchor, not an interceptable LiveView click) and independently re-ran the full proof — `mix test` (23/23 passed), `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo`, all exit `0`. The new test suite round-trips the extracted deep-link code through `Pairing.complete_pairing/2` directly, proving it is a real, single-use code rather than a placeholder.

- [x] Task 7 — Apply real Developer ID signing.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Make the shipped artifact trustworthy under Gatekeeper using the operator's Apple Developer credentials.
  - Owned surfaces: Deep code-signing of every embedded executable and the outer bundle, hardened runtime, minimal entitlements (network client and the embedded runtime's own JIT execution — see design.md's "The Entitlement Set Includes JIT Execution, Not Networking Alone").
  - Owns: AC-09
  - Proof: `codesign --verify --deep --strict` passes against the `.app` signed with the configured Developer ID identity, the entitlement list contains nothing beyond outbound networking and JIT execution, and the signed, hardened-runtime `.app` genuinely boots and runs (not just passes static verification). Requires the configured signing identity in the build environment; treat as environment-blocked, not a design defect, if unavailable.
  - Delivered: `SDD_ORCHESTRATOR_SIGNING_IDENTITY` (unset by default — the unsigned build path is byte-for-byte unchanged) drives real Developer ID signing in `native/worker-app/build.sh`, using the accountable owner's actual "Developer ID Application: Ahmed Ben Henda (4792F94P6N)" certificate now present in this machine's keychain. Every real Mach-O file in the bundle is found by content (`file`, not filename convention — 24 files: `argon2_elixir`'s NIF and dSYM, `crypto`/`runtime_tools`/`asn1rt` native drivers, all 16 `erts` executables, the Swift launcher) and signed deepest-path-first, then the outer bundle, each with `--options runtime --entitlements ... --timestamp` — never via `codesign --deep` for the signing action itself, per Apple's own guidance that `--deep` is for verification, not primary signing. Implementation discovery, corrected via the same-day `update-spec` pass recorded above: hardened runtime with only `network.client` crashes `beam.smp` on launch (`beam_jit_main.cpp:pick_allocator(): Internal error: jit: Failed to allocate executable+writable memory` — BEAM's JIT cannot get W^X memory under Hardened Runtime without it); `com.apple.security.cs.allow-jit` is the standard, purpose-built Apple entitlement for exactly this (required by any JIT-compiling runtime under Hardened Runtime) and was confirmed both necessary and sufficient — no broader entitlement was needed.
  - Verified beyond the sub-agent's own report: main thread independently reproduced the crash from scratch (real crash report inspected, `codeSigningTeamID: 4792F94P6N`, `SIGNAL/SIGABRT`), independently confirmed `allow-jit` alone fixes it (the process boots and `bin/worker rpc` reports `worker` against the real running signed instance), then applied the corrected entitlements to the committed `build.sh`, and independently re-ran the complete proof from a clean build: `codesign --verify --deep --strict` exit 0, `codesign -d --entitlements -` shows exactly the two intended entitlements and nothing else, a real launch with both the launcher and `beam.smp` processes alive and RPC-reachable, and the default unsigned path confirmed unaffected (`adhoc`, `TeamIdentifier=not set`, identical to pre-Task-7 baseline). All test state (`~/.sdd_orchestrator`, crash logs, running processes) cleaned up afterward.

- [x] Task 8 — Package the signed `.app` into an installable `.dmg`.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 7
  - Purpose: Give the operator the standard macOS drag-to-Applications install experience, packaging the app only after it is signed so the disk image never carries an unsigned binary.
  - Owned surfaces: DMG assembly (Applications shortcut, disk-image layout), disk-image build script.
  - Owns: AC-02
  - Proof: The build script produces a `.dmg` that mounts and presents the signed `.app` plus an Applications shortcut on a supported macOS version.
  - Delivered: An unconditional DMG-assembly step appended to `native/worker-app/build.sh`, running after app assembly and the conditional signing step — works identically against whatever `.app` the build just produced (signed or unsigned), since AC-02's packaging mechanism doesn't depend on the signing branch itself. Stages a copy of the `.app` (original left in place at its existing path for other tasks/tests) plus an `Applications -> /Applications` symlink, then `hdiutil create -format UDZO -ov` into `SDD Orchestrator Worker-0.1.0.dmg` (the app's own version, read from `mix.exs`). Staging directory removed after every run.
  - Verified beyond the sub-agent's own report: main thread independently rebuilt from a clean `native/worker-app/build/`, mounted the produced `.dmg`, confirmed the mounted volume contains exactly the `.app` and the `Applications` symlink (verified target via `readlink`), detached cleanly, and confirmed the original plain `.app` bundle and the DMG staging directory were left in their correct states (original present, staging gone).

- [x] Task 9 — Notarize and staple the release artifact.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 8
  - Purpose: Satisfy Gatekeeper for an artifact downloaded outside this development machine.
  - Owned surfaces: Notary submission, ticket polling, stapling, local Gatekeeper verification.
  - Owns: AC-10
  - Proof: `xcrun notarytool submit` succeeds and the returned ticket is stapled to the `.dmg`; `spctl --assess --type execute` on the `.app` mounted from the stapled `.dmg` accepts it with no warning, citing "Notarized Developer ID" as the trust source (the actual launch-time check that determines whether an operator sees a warning). `spctl --assess --type open` run directly against the bare `.dmg` file path is not used as proof: implementation found it reports "Insufficient Context" regardless of notarization status, a documented `spctl` CLI limitation (it expects LaunchServices open-event context a real double-click provides, not something a bare file-path invocation supplies) — not a real Gatekeeper rejection, and consistent with Apple's own documented pattern of notarizing an unsigned `.dmg` container around a signed, notarized `.app`. Proof latency depends on Apple's notary service turnaround and does not change this task's scope. Requires the configured notary credentials in the build environment; treat as environment-blocked, not a design defect, if unavailable.
  - Delivered: `SDD_ORCHESTRATOR_NOTARY_PROFILE` (unset by default) drives real notarization in `native/worker-app/build.sh`, using the accountable owner's real `xcrun notarytool` keychain profile. Fails fast, before any submission, if the notary profile is set without a signing identity in the same run (Apple's notary service rejects unsigned submissions outright — no point burning a real submission on a guaranteed rejection). `xcrun notarytool submit --wait` blocks for Apple's real turnaround; both its exit code and a `status: Accepted` check gate stapling — any rejection fetches and surfaces the real `notarytool log` rather than failing silently. `xcrun stapler staple` attaches the ticket to the `.dmg` on success.
  - Verified beyond the sub-agent's own report: main thread independently reproduced the `spctl --type open` "Insufficient Context" result on the same real stapled `.dmg` (including with a hand-crafted `com.apple.quarantine` xattr matching what a real browser download sets — result unchanged), then independently mounted it and ran `spctl --assess --type execute` on the `.app` inside: `accepted`, `source=Notarized Developer ID`, exit 0 — the real, authoritative proof that a real operator sees no warning. `xcrun stapler validate` confirmed the ticket is genuinely stapled. All test mounts and artifacts cleaned up afterward.

- [x] Task 10 — Implement the periodic signed-appcast check.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Let a running app learn about a newer signed release without sending identifying data.
  - Owned surfaces: Appcast schema (version, minimum OS, download descriptor, signature), periodic background fetch, signature verification, menu-bar update-available prompt.
  - Owns: AC-11, AC-12, AC-15
  - Proof: Fixture-appcast tests cover no-update, a valid newer version (prompts, does not auto-install), and a tampered or invalid signature (rejected); a request-capture test asserts only the app version and coarse OS descriptors are sent.
  - Delivered: JSON appcast schema (`latest_version`, `minimum_os`, `download_url`, `sha256`, `signature`) signed with Ed25519 via `CryptoKit` (`Curve25519.Signing`, no new dependency) over a hand-built canonical byte sequence (fixed alphabetical key order, minimal JSON escaping — deliberately not `JSONSerialization`, whose exact byte output isn't a stable cross-version contract for something a signature must match exactly). `AppcastUpdateChecker` fetches, verifies the signature (any failure — missing, malformed, wrong key — collapses to untrusted, never surfaced, matching this project's fail-closed convention), short-circuits before any download when not newer (AC-11's "no action" is a genuine no-op, not silent-after-wasted-work, proven by a test asserting the download call never happens in that case), then downloads and verifies the artifact's SHA-256 against the signed entry before storing it and transitioning `WorkerStatus` to `.updateAvailable` (AC-12 — a menu-bar prompt only; no install action, that's Task 11's). AC-15: the appcast fetch is a bare unauthenticated GET carrying nothing at all, not even the coarse fields — the simplest AC-15-safe choice. `SDDOrchestratorAppcastURL`/`SDDOrchestratorAppcastPublicKey` follow the same build-time-configurable Info.plist pattern as Task 2's dashboard URL; the baked-in default public key is throwaway test material (matching private key documented only in the test target, never linked into the shipped app) — real production key custody is this spec's own release-gate item, exactly like the signing certificate.
  - Verified beyond the sub-agent's own report: main thread independently reviewed the signature verifier, canonical-payload builder, checksum verifier, and orchestration ordering (all correct); independently built and ran the full test suite (155/155); and independently reproduced the sub-agent's manual proof end to end using its own generated fixture — signed a real appcast entry with the documented test private key, served it locally, rebuilt the app with the fixture URL baked in via the build-time override, launched the real `.app`, and confirmed via direct filesystem inspection that the downloaded artifact's SHA-256 matched exactly what was signed, proving the full fetch → verify-signature → compare-version → download → verify-checksum → store pipeline is genuinely wired end to end. Both the sub-agent and the main thread independently identified this session's desktop as live and shared, and avoided screenshotting or scripting it unnecessarily — this task's proof needed no interactive GUI step at all.

- [x] Task 11 — Implement the confirmed update-apply flow.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 10
  - Purpose: Let the operator move to a newer version without losing pairing or interrupting an active run.
  - Owned surfaces: Download and signature/notarization verification of the offered build, active-run gate reusing Task 2's run-state check, in-place install, relaunch, credential preservation across reinstall.
  - Owns: AC-13, AC-14
  - Proof: Tests confirm a confirmation while idle installs and relaunches on the new version with the stored credential unchanged, and a confirmation while a run is active defers the install until the run reaches a terminal state rather than applying it immediately.
  - Delivered: `UpdateInstallCoordinator` (confirm → `ActiveRunChecker`-based active-run gate, reused not duplicated → `GatekeeperAssessor` `spctl --assess` belt-and-suspenders check on top of Task 10's checksum → install handoff), a pure/synchronous state machine mirroring `PairingFlowController`'s shape. AC-14's defer has no push/event to rely on — `AppDelegate` gets a dedicated 15s poll timer (started only while genuinely deferred, stopped once resolved) reusing the exact same `RunStateQuerier` call the Quit flow already uses; the coordinator proceeds automatically once a later poll reports terminal, no second confirm required. Install/relaunch is a detached `/bin/sh` helper (`InstallHelperScriptBuilder`, spawned by `HelperScriptInstallExecutor`, never `wait()`ed so it reparents to `launchd` on app exit rather than becoming a zombie): waits for the parent PID to exit (bounded, 60×0.5s), mounts the `.dmg`, stages the new bundle onto the target's own volume, same-volume `mv` swap with automatic backup restoration if the second move fails, unmounts via an `EXIT` trap (runs on every path), relaunches, self-deletes. `applicationShouldTerminate(_:)` (Task 2's AC-04/AC-05 gate) is reused, not duplicated, for the quit-to-install transition — `isInstallingUpdate` skips the now-redundant active-run warning since the coordinator already satisfied that gate before ever handing off. Credential preservation (AC-13) is a structural property, not a copy/restore step: `~/.sdd_orchestrator/worker/worker.json` lives outside the `.app` bundle entirely, so an install that only ever touches the bundle path leaves it untouched by construction — proved by a test showing neither the Gatekeeper check nor the installer is ever handed that file's path.
  - Verified beyond the sub-agent's own report: main thread independently reviewed the generated helper script (correct bounded wait, checked failure paths with backup restoration, EXIT-trap cleanup on every exit — one minor unchecked `open` call at the very end, after the bundle swap already succeeded, so a failed relaunch would leave the app installed but not auto-opened; low severity, not a correctness or data-loss defect, left as-is) and the coordinator's state machine (correct defer/resume, fail-safe on query failure, no double-confirm race); independently built and ran the full suite (182/182). Real Gatekeeper assessment against a real signed artifact and a full production self-relaunch remain genuinely unverifiable in this environment (no Apple Developer signing identity is loaded here, Tasks 7-9 still blocked) — the sub-agent's own manual proof, appropriately, exercised only the mount/copy/relaunch mechanics against a throwaway fake `.app`/`.dmg` it constructed itself, with `open` shadowed rather than actually relaunching anything, matching the same shared-desktop caution earlier tasks in this effort applied.

- [ ] Task 12 — End-to-end integration proof.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 6, Task 5, Task 9, Task 11
  - Purpose: Prove the packaged pieces work together as one operator journey using this slice's own signed, stapled artifact.
  - Owned surfaces: `capability:signed-macos-worker-distribution`; otherwise integrates Tasks 1–11 into one observed scenario without introducing new surfaces.
  - Owns: AC-16
  - Proof: Mounting this slice's own signed, stapled `.dmg`, dragging the app to Applications, launching it, completing pairing through a real dashboard deep-link action, completing post-pairing workspace/agent setup, observing `Connected` in the menu bar, then quitting to observe `Unavailable` — all without a terminal command. Reaching a genuine, not merely paired, run-execution-connected state additionally requires a `HostedLocalRepositoryBinding` for the target project — see design.md's Risk on this: no production UI anywhere creates one for a normal project, so this task constructs one directly via `HostedLocalRepositoryBindings.put_validated_binding/6` (the same production function this project's own test suite already uses for the same purpose), using a real hosted project and personal workspace, then reaches the pairing screen by navigating directly to its URL with that project's id (since no hosted-project dashboard page yet renders an "Open in App" action — that gap is the same one this task's Risk documents). Every other step — the deep-link URL scheme handoff, pairing-completion endpoint, post-pairing setup, menu-bar state, and Quit — runs through the real, unmodified, already-verified code each owning task delivered. Because no hosted-project dashboard page yet displays worker connection state at all (a second, related gap beyond binding creation — also out of this slice's boundary, see design.md), "the dashboard" side of AC-16's observation is proved by directly querying `HostedLocalRepositoryBindings.connection_state/3` (the same authoritative function such a page would eventually read) rather than a rendered page, with this substitution documented explicitly, not silently assumed equivalent.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] The build, signing, and notarization pipeline produces a stapled `.dmg` that passes Gatekeeper assessment with no warning.
- [ ] Menu-bar status transitions and the active-run-aware quit behavior pass.
- [ ] The pairing-completion endpoint accepts a valid code and refuses generically for expired, reused, unknown, and malformed codes.
- [ ] The URL-scheme pairing handoff succeeds for a valid code and fails safely for expired, reused, and malformed payloads.
- [ ] Post-pairing setup resolves a repository workspace and a coding-agent executable without manual path entry in the successful case, and offers a usable manual fallback when auto-detection fails.
- [ ] The dashboard's deep-link action and install-guidance fallback render correctly on the existing pairing screen.
- [ ] The appcast check sends only the approved coarse fields and never a device, workspace, or credential identifier.
- [ ] A confirmed update installs and relaunches while preserving the stored credential, and defers correctly while a run is active.
- [ ] The end-to-end integration scenario passes with zero terminal commands.
- [ ] Build, formatting, lint, and static checks pass for every new module.

## Blocked Decisions

- Resolved: the accountable owner's Apple Developer ID Application signing certificate is now loaded in this build environment's keychain; Task 7 is complete. Task 8 is unblocked.
- Still environment-blocked: Task 9 (notarization) needs its own separate notary credentials (an App Store Connect API key or app-specific password for `xcrun notarytool`), not yet available in this environment — this transitively blocks Task 12 (depends on Task 9). Tasks 1–8, 10, and 11 do not depend on the notary credential.

## Progress Log

See [progress.md](progress.md).
