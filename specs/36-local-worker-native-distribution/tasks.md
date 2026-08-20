# Local Worker Native Distribution Tasks

## Status

Not Started

## Active Slice

Package the already-`Verified` worker runtime (`specs/33-local-worker-run-execution`) into a Developer ID–signed, notarized macOS `.app`/`.dmg` with a menu-bar status shell, a network-facing pairing-completion endpoint, a deep-link-only pairing handoff from the dashboard, and a prompted, signature-verified auto-update flow — closing the "signed native worker packaging and installation" item `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` both list as release-gated.

## Cross-Specification Dependencies

Requires:

- `capability:local-worker-run-execution` — provider `specs/33-local-worker-run-execution#Task 12` — required before `Task 1`.
- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 3`.

Provides:

- `capability:signed-macos-worker-distribution` — ready after `Task 11`.

## Slice Size Gate

- Slice size: Standard

One coherent outcome — a real, signed, notarized, auto-updating macOS worker distribution — through one verification gate, eleven tasks total, and a longest `Depends on:` path of five tasks (for example `Task 1 → Task 6 → Task 7 → Task 8 → Task 11`, matched by `Task 1 → Task 2 → Task 4 → Task 5 → Task 11` and by `Task 1 → Task 2 → Task 9 → Task 10 → Task 11`), both within the standard limits.

## Task Size Gate

- Every task is `Size: Standard`. Each delivers one independently provable outcome, owns at most three acceptance criteria and at most one data entity, and is expected to produce one task-boundary implementation commit.
- The pairing-completion endpoint (Task 3) is separate from the native URL-scheme handoff (Task 4) because one is a control-plane authorization surface with its own Phoenix-controller proof and the other is native-app runtime behavior with a different failure mode — the same split `specs/33-local-worker-run-execution` already used between its gateway-credential exchange and its gateway client.
- Signing (Task 6), DMG packaging (Task 7), and notarization (Task 8) are three separate tasks, in that order, because packaging must wrap an already-signed `.app` and notarization must submit an already-packaged `.dmg` — each stage fails independently and against a different tool (`codesign`, `hdiutil`/packaging, `xcrun notarytool`).
- The appcast check (Task 9) is separate from the update-apply flow (Task 10) because one is a read-only periodic fetch and the other is a stateful install-and-relaunch action with its own active-run gate.
- No task-size exception is used.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- A native macOS menu-bar shell wrapping the existing worker release: process lifecycle, status UI, Open Dashboard, and Quit with an active-run-aware warning.
- A network-facing pairing-completion endpoint on the control plane, consuming `specs/02-local-project-onboarding`'s existing `Pairing.complete_pairing/2` unchanged.
- App-bundle assembly, `.dmg` packaging, Developer ID signing, and Apple notarization/stapling of the shipped artifact.
- A registered custom URL scheme that receives a pairing payload and submits it to the new pairing-completion endpoint.
- The dashboard's existing pairing screen (`specs/02-local-project-onboarding`), extended with an "Open in App" deep-link action and an install-guidance fallback.
- A signed appcast, a periodic background check, and a confirm-before-install update-apply flow that defers while a run is active and preserves the stored credential across the upgrade.

Excluded:

- The worker runtime's execution behavior: gateway client, command handling, agent adapters, and evidence upload, all already delivered and `Verified` by `specs/33-local-worker-run-execution`. This slice only launches, supervises, and packages that runtime.
- `specs/02-local-project-onboarding`'s pairing contract, credential custody, and connection-status logic; this slice only adds a network transport and a UI entry point that call into that existing, unchanged contract.
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
  - Owned surfaces: `.app` bundle structure, `Info.plist` contract (bundle identifier, semantic version, `LSMinimumSystemVersion`, `LSUIElement`), the new `:worker` `mix release` target and its runtime boot-mode gate (never starts `Endpoint`, `Repo`, or any control-plane process). Because `SddOrchestrator.Worker.Supervisor.start_link/1` refuses to start at all when no configuration is paired yet (`{:error, :not_paired}`), the worker-mode boot path must tolerate that: it starts a minimal always-up host (for example a `DynamicSupervisor`) rather than requiring `Worker.Supervisor` as a required static child, so the release boots successfully whether or not pairing has happened yet. Starting `Worker.Supervisor` for the first time once pairing succeeds is Task 4's job, not this task's.
  - Owns: AC-01, entity:WorkerAppRelease
  - Proof: A build script produces a `.app` whose `Info.plist` matches the approved contract (bundle identifier, `LSUIElement` true, `LSMinimumSystemVersion` at `specs/02-local-project-onboarding`'s approved floor). The embedded release boots successfully in worker mode both with no stored configuration present (starts the always-up host, starts no control-plane process, does not crash) and with a configuration already present (also starts `Worker.Supervisor` under that host).
  - Delivered: `mix.exs` gains a `:worker` release (`rel_templates_path: "rel/overlays/worker"`) alongside the unchanged default `sdd_orchestrator` release (`default_release: :sdd_orchestrator` preserves the bare `MIX_ENV=prod mix release` command every other slice's verification gate already uses — confirmed unchanged: still resolves to `sdd_orchestrator` and still raises on missing `DATABASE_URL`). `rel/overlays/worker/env.sh.eex` sets `SDD_ORCHESTRATOR_RELEASE_MODE=worker` before boot, scoped to that release only. `SddOrchestrator.Application.boot_mode/0` reads that var; worker mode starts only `SddOrchestrator.Worker.Host` (a `DynamicSupervisor`, `worker_host_name/0`) and never `Endpoint`/`Repo`/`Vault`/any control-plane process — confirmed by real RPC into a running built release (`Supervisor.which_children/1` shows only the host; `Process.whereis/1` for `Endpoint`/`Repo` both `nil`). Since `Worker.Supervisor.start_link/1` refuses to start with no paired configuration, it is never a static child; `attach_paired_worker/1` starts it under the host at boot only when a configuration already exists (relaunch case), and Task 4 will call the same `DynamicSupervisor.start_child(SddOrchestrator.Application.worker_host_name(), SddOrchestrator.Worker.Supervisor)` after a first-time pairing succeeds. `native/worker-app/build.sh` assembles `SDD Orchestrator Worker.app` (`Contents/Resources/release` = the built release verbatim; `Contents/MacOS/sdd-orchestrator-worker-launcher` = a placeholder exec-the-release-start-script launcher that Task 2 replaces with the real Swift menu-bar shell). `Info.plist` verified via `plutil -p`: `CFBundleIdentifier=com.sddorchestrator.worker`, `LSMinimumSystemVersion=14.0`, `LSUIElement=true`.

- [ ] Task 2 — Build the menu-bar status shell and quit lifecycle.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Give the operator the app's only native UI surface and a safe way to stop the worker.
  - Owned surfaces: Menu-bar status item (not-paired, pairing, connected, disconnected, update-available states), Open Dashboard action, Quit action, active-run check consulted before quitting.
  - Owns: AC-03, AC-04, AC-05
  - Proof: Shell tests drive each status transition and confirm Quit stops the process immediately when idle, and shows a confirmation warning instead of stopping immediately when a run is active, using the existing run-state query.

- [x] Task 3 — Build the network-facing pairing-completion endpoint.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let a genuinely separate worker process — one with no local database — complete pairing over the network, since `Pairing.complete_pairing/2` has so far only ever been called in-process.
  - Owned surfaces: A control-plane endpoint accepting a single-use pairing code, calling `Pairing.complete_pairing/2` unchanged, returning the issued credential and worker identity or a generic refusal that discloses no specific reason.
  - Owns: AC-17, AC-18
  - Proof: Endpoint tests cover a valid unexpired unused code (returns the same credential shape the existing local call already returns), and expired, already-used, unknown, and malformed codes (each refused generically, no credential issued, no reason disclosed in the response).
  - Delivered: `SddOrchestratorWeb.WorkerPairingController` at `POST /worker_pairings` (unauthenticated `:api` pipeline, deliberately not under `/worker/...` since that prefix implies the already-authenticated `:worker` pipeline). Accepts `code` plus the caller's own `os_family`/`os_major`/`protocol_version`/`app_version` as request parameters — a real remote worker reports these about itself; none are derived from this application's own build or from `WorkerDiscovery.compatibility_policy/0` (that function is the control plane's supported-values policy, not any caller's real environment). Calls `Pairing.complete_pairing/2` unchanged. Every refusal (expired, already-used, unknown, malformed code, malformed request, badly-typed optional attribute) returns identical `403 {"error": "refused"}` with `cache-control: no-store`, proved by a cross-check test asserting expired/used/unknown responses are byte-identical. `pairing.ex` and `worker.pair.ex` untouched.

- [ ] Task 4 — Implement the URL-scheme pairing handoff.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2, Task 3
  - Purpose: Let the app complete pairing from a dashboard-issued deep link without any typed input.
  - Owned surfaces: Custom URL-scheme registration and payload parsing, submission to Task 3's pairing-completion endpoint, typed success/failure reporting into the menu bar. On success, starts `SddOrchestrator.Worker.Supervisor` for the first time under Task 1's always-up host (the release was booted without it, since pairing had not happened yet) rather than requiring the app to relaunch.
  - Owns: AC-07, AC-08
  - Proof: Contract tests feed valid, expired, already-used, and malformed `sddworker://pair` payloads and assert Task 3's endpoint is called only for the valid case, a credential is stored only on success and `Worker.Supervisor` is started under Task 1's host without a relaunch, and every case ends in a defined menu-bar state without a crash.

- [ ] Task 5 — Add the dashboard's "Open in App" deep-link action.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Let the project owner hand a pairing code to the installed app with one click instead of a terminal or manual entry.
  - Owned surfaces: `specs/02-local-project-onboarding`'s existing pairing-code screen, extended with the deep-link action and an install-guidance fallback when the scheme cannot be resolved.
  - Owns: AC-06
  - Proof: LiveView tests assert the pairing screen renders the deep link carrying the current single-use code and falls back to install guidance instead of a silent no-op when the app is not installed.

- [ ] Task 6 — Apply real Developer ID signing.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Make the shipped artifact trustworthy under Gatekeeper using the operator's Apple Developer credentials.
  - Owned surfaces: Deep code-signing of every embedded executable and the outer bundle, hardened runtime, minimal entitlements.
  - Owns: AC-09
  - Proof: `codesign --verify --deep --strict` passes against the `.app` signed with the configured Developer ID identity, and the entitlement list contains nothing beyond outbound networking. Requires the configured signing identity in the build environment; treat as environment-blocked, not a design defect, if unavailable.

- [ ] Task 7 — Package the signed `.app` into an installable `.dmg`.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 6
  - Purpose: Give the operator the standard macOS drag-to-Applications install experience, packaging the app only after it is signed so the disk image never carries an unsigned binary.
  - Owned surfaces: DMG assembly (Applications shortcut, disk-image layout), disk-image build script.
  - Owns: AC-02
  - Proof: The build script produces a `.dmg` that mounts and presents the signed `.app` plus an Applications shortcut on a supported macOS version.

- [ ] Task 8 — Notarize and staple the release artifact.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 7
  - Purpose: Satisfy Gatekeeper for an artifact downloaded outside this development machine.
  - Owned surfaces: Notary submission, ticket polling, stapling, local Gatekeeper verification.
  - Owns: AC-10
  - Proof: `xcrun notarytool submit` succeeds and the returned ticket is stapled to the `.dmg`; `spctl --assess --type open` accepts the stapled artifact with no warning. Proof latency depends on Apple's notary service turnaround and does not change this task's scope. Requires the configured notary credentials in the build environment; treat as environment-blocked, not a design defect, if unavailable.

- [ ] Task 9 — Implement the periodic signed-appcast check.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Let a running app learn about a newer signed release without sending identifying data.
  - Owned surfaces: Appcast schema (version, minimum OS, download descriptor, signature), periodic background fetch, signature verification, menu-bar update-available prompt.
  - Owns: AC-11, AC-12, AC-15
  - Proof: Fixture-appcast tests cover no-update, a valid newer version (prompts, does not auto-install), and a tampered or invalid signature (rejected); a request-capture test asserts only the app version and coarse OS descriptors are sent.

- [ ] Task 10 — Implement the confirmed update-apply flow.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 9
  - Purpose: Let the operator move to a newer version without losing pairing or interrupting an active run.
  - Owned surfaces: Download and signature/notarization verification of the offered build, active-run gate reusing Task 2's run-state check, in-place install, relaunch, credential preservation across reinstall.
  - Owns: AC-13, AC-14
  - Proof: Tests confirm a confirmation while idle installs and relaunches on the new version with the stored credential unchanged, and a confirmation while a run is active defers the install until the run reaches a terminal state rather than applying it immediately.

- [ ] Task 11 — End-to-end integration proof.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5, Task 8, Task 10
  - Purpose: Prove the packaged pieces work together as one operator journey using this slice's own signed, stapled artifact.
  - Owned surfaces: `capability:signed-macos-worker-distribution`; otherwise integrates Tasks 1–10 into one observed scenario without introducing new surfaces.
  - Owns: AC-16
  - Proof: Mounting this slice's own signed, stapled `.dmg`, dragging the app to Applications, launching it, completing pairing through the dashboard's deep-link action, observing `Connected` in both the menu bar and the dashboard, then quitting to observe `Unavailable` — all without a terminal command.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] The build, signing, and notarization pipeline produces a stapled `.dmg` that passes Gatekeeper assessment with no warning.
- [ ] Menu-bar status transitions and the active-run-aware quit behavior pass.
- [ ] The pairing-completion endpoint accepts a valid code and refuses generically for expired, reused, unknown, and malformed codes.
- [ ] The URL-scheme pairing handoff succeeds for a valid code and fails safely for expired, reused, and malformed payloads.
- [ ] The dashboard's deep-link action and install-guidance fallback render correctly on the existing pairing screen.
- [ ] The appcast check sends only the approved coarse fields and never a device, workspace, or credential identifier.
- [ ] A confirmed update installs and relaunches while preserving the stored credential, and defers correctly while a run is active.
- [ ] The end-to-end integration scenario passes with zero terminal commands.
- [ ] Build, formatting, lint, and static checks pass for every new module.

## Blocked Decisions

- Environment-blocked, not a design defect: `security find-identity -v -p codesigning` on the current implementation machine returns zero identities. Task 6 (signing) cannot complete its proof until the accountable owner's Apple Developer Program signing certificate is loaded into this build environment, which transitively blocks Task 7 (packages the signed app), Task 8 (notarization, also needs its own notary credentials), and Task 11 (depends on Task 8). Tasks 1–5, 9, and 10 do not depend on either credential and proceed independently.

## Progress Log

See [progress.md](progress.md).
