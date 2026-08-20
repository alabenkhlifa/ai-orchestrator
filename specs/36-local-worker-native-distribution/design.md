# Local Worker Native Distribution Design

## Context

`specs/33-local-worker-run-execution` delivered and verified the worker's actual execution behavior — pairing exchange, gateway dial, run execution, evidence upload — as a developer-run process started from this repository's toolchain (`mix worker.pair`, `mix worker.start`). `specs/02-local-project-onboarding` already committed to the target packaging shape ("macOS Worker Packaging": a Developer ID–signed, notarized `.app` in a `.dmg`, updated through a signed appcast) and built a `:device_worker_stub` dev/test stand-in so the graphical pairing UI is exercisable without a real signed binary. Both specs list "signed native worker packaging and installation" as an identical release-gate item. This slice builds that packaging and, because the accountable owner now has Apple Developer credentials, performs the real signing and notarization as part of its own verification rather than deferring it again.

## Proposed Approach

Wrap the existing worker release in a minimal native macOS shell rather than reimplementing any execution logic. The shell owns exactly four things: process lifecycle (launch the embedded `mix release` build, supervise it, stop it on Quit), the menu-bar status UI, the custom-URL-scheme pairing handoff, and the update check/apply flow. It never reimplements pairing, gateway, or run-execution logic — those stay owned by `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` and are only invoked or observed. Pairing-code entry is deep-link-only: the dashboard's existing pairing screen gains an "Open in App" action using a registered custom URL scheme, so the app needs no manual-entry UI at all. The appcast is a public, unauthenticated, versioned feed; the app's periodic check sends nothing beyond the app version and the coarse OS descriptors `specs/02-local-project-onboarding`'s outbound connection contract already approves.

## Components Affected

- A new native macOS shell (menu-bar app) wrapping the existing worker release.
- Build tooling: `.app` assembly, `.dmg` packaging, code signing, notarization/stapling.
- The signed appcast feed and the shell's periodic update check and apply flow.
- `specs/02-local-project-onboarding`'s existing pairing-code screen, extended (not redefined) with the deep-link action and an install-guidance fallback.
- The custom URL-scheme registration consumed by that dashboard screen.

## Data and Access Boundaries

- `WorkerAppRelease`: one published, signed, notarized worker build — semantic version, minimum supported macOS version, a signature/notarization reference, and publish time. Public release metadata; not personal data.

Required boundaries:

- The periodic appcast check is unauthenticated and public. It carries only the app version and the coarse OS descriptors (`os_family`, `os_major`) `specs/02-local-project-onboarding`'s Minimum Outbound Connection Contract already approves for outbound worker metadata — never a device, workspace, project, or credential identifier. It introduces no new personal-data field: the fields it sends are the same coarse compatibility descriptors that contract already treats as non-identifying.
- The URL-scheme pairing payload carries only the single-use pairing code `specs/02-local-project-onboarding`'s pairing contract already defines. Activation is local OS inter-process communication, not a network transmission, so the code never crosses the network a second time by this path.
- Code-signing and notarization credentials (Apple Developer Team ID, signing certificate, notary API key) are build-time secrets held outside the repository and outside any committed configuration; they are never embedded in the shipped binary, logged, or included in a proof receipt.
- The stored worker credential's custody (worker-local keychain, `specs/33-local-worker-run-execution` AC-03) is unchanged by this slice. Packaging and the update-apply flow must preserve that credential across an in-place reinstall, never duplicate or relocate it.

## Interfaces

- App-bundle build interface: assembles the existing worker release into a signed `.app` with the approved bundle identity.
- DMG packaging interface: produces the drag-to-Applications disk image from the signed `.app`.
- Notarization interface: submits the `.dmg`, polls for the notary ticket, and staples it.
- Menu-bar status interface: renders not-paired, pairing, connected, disconnected, and update-available states; exposes Open Dashboard and Quit.
- URL-scheme pairing interface: receives and validates a pairing payload, invokes the existing pairing exchange unchanged, and reports a typed outcome.
- Dashboard deep-link interface: renders the "Open in App" action and the install-guidance fallback on the existing pairing screen without changing that screen's own contract.
- Appcast interface: publishes and fetches the signed release feed.
- Update-apply interface: downloads, verifies, and installs a newer signed build, deferring while a run is active on that worker.

## Decisions and Tradeoffs

### Real Signing And Notarization In This Slice

- Choice: Perform real Developer ID signing and Apple notarization as part of this slice's own tasks and verification, not the release gate.
- Reason: The accountable owner has the required Apple Developer Program credentials now, so deferring signing again would just repeat the placeholder both `specs/02-local-project-onboarding` and `specs/33-local-worker-run-execution` already carry.
- Consequence: The tasks that perform signing and notarization require those credentials to be present in the build environment; if they are not available in a given implementation session, those tasks become environment-blocked rather than a design defect, per this project's established environment-blocker handling. What remains release-gated is a live install proof on a machine other than the development machine and production hosting for the artifacts, not the signing mechanism itself.

### Minimal Native Shell Wrapping The Existing Elixir Release

- Choice: Use a small native macOS shell (Swift/AppKit) whose only jobs are process lifecycle, the menu-bar UI, the URL-scheme handoff, and the update flow; it launches and supervises the existing `mix release` build rather than reimplementing any worker behavior.
- Reason: `specs/33-local-worker-run-execution`'s worker runtime is already implemented and `Verified`; re-deriving pairing, gateway, or run-execution logic natively would duplicate an already-proven contract and risk drift between two implementations of the same behavior.
- Consequence: The build environment needs both the existing Elixir/mix toolchain and a Swift/Xcode toolchain. The shell must treat the embedded release as an opaque child process it starts, stops, and observes for status — never a component it reimplements.

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

## Open Questions

- None.
