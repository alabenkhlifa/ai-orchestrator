# Worker-Initiated Pairing Tasks

## Status

Verified

All eight tasks are complete and the full local verification gate passes.
`capability:worker-initiated-pairing` is ready, for implementation and local
verification only; release readiness stays separate and is listed in the
release gates below.

## Active Slice

Let someone pair a freshly installed worker app without an existing project: the app obtains and shows a live pairing code, the person copies it from the menu bar and redeems it in the dashboard, that redemption binds the code to their own Mac project space and authorizes the worker, and the app reaches its connected state on its own.

## Cross-Specification Dependencies

Requires:

- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 2`.
- `capability:signed-macos-worker-distribution` — provider `specs/36-local-worker-native-distribution#Task 12` — required before `Task 5`.

Provides:

- `capability:worker-initiated-pairing` — ready after `Task 8`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- An unbound `PairingAttempt` state and the constraints that keep its two valid shapes reachable and the third unreachable.
- An anonymous issuance endpoint with its rate limit and audit.
- One authorized binding that attaches the attempt to the redeeming owner's device workspace, with completion left to the app through the existing endpoint.
- The dashboard pairing form redeeming a real code, and its corrected placeholder.
- Worker-app code acquisition, expiry-driven refresh, menu-bar presentation, and clipboard copy.
- The app's own transition out of the unpaired state once redemption happened elsewhere.
- Retention of unredeemed unbound attempts, and exclusion of codes and credentials from every diagnostic.

Excluded:

- The `Open in App` deep link and `POST /worker_pairings`, whose behavior and contract stay exactly as `specs/36-local-worker-native-distribution/` verified them.
- The workspace-scoped `start_pairing/2` path used by the dashboard and the deep link.
- What a paired worker may then do, owned by `specs/33-local-worker-run-execution/`.
- Re-pairing, credential rotation, and unpairing.
- Hosted-project pairing, non-macOS workers, and pairing from a second device.

Deferred after this slice:

- Configuring a worker paired this way: giving it a project, a repository folder, and a coding agent so it can actually connect. It will need a credential this flow does not retain.
- Retiring the deep link, or unifying the two entry points behind one surface, if usage later shows one is redundant.
- Showing the person which worker a redemption authorized, beyond the connection state the app already reports.

Release gates:

- If the control plane is hosted, the processor, region, and transfer safeguards covering anonymous issuance requests reaching it, on the same basis `specs/02-local-project-onboarding/` already records for outbound device metadata.
- Confirmation of the retention window for unredeemed attempts and issuance-throttle counters as part of the accountable privacy review.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Introduce the unbound pairing attempt and its state constraints.
  - Status: Complete.
  - Size: Exception — the column, its backfill, and the constraints expressing the two valid states are one migration; applying them separately leaves existing rows momentarily violating the constraint that defines a valid attempt.
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let an attempt exist with no device workspace without making the workspace optional for anything that authorizes a worker.
  - Owned surfaces: `PairingAttempt` schema and changesets, the nullable `device_workspace_id`, the database constraints expressing unbound and bound as the only valid states, and existing-row backfill.
  - Owns: AC-03, entity:PairingAttempt
  - Proof: Migration and schema tests prove an unbound attempt inserts, a bound attempt inserts, the mixed invalid state is rejected by the database, every pre-existing attempt remains valid and bound, and no existing workspace-scoped caller changed behavior.

- [x] Task 2 — Implement authorized binding of a code to the redeemer's workspace.
  - Status: Complete. Reopened once because the first implementation also created the worker, which only the app can describe and only the app should hold a credential for.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Make binding the single moment a code stops being inert and becomes attached to exactly one owner's workspace, leaving completion to the app that will hold the credential.
  - Owned surfaces: The bind operation in `Devices.Pairing`, its single-use and one-way binding enforcement, its ownership check against the redeeming owner's own device workspace, and its uniform refusal answer.
  - Owns: AC-05, AC-06
  - Proof: Domain tests cover a valid binding attaching the attempt to the redeemer's own workspace and creating no worker, a second binding of the same code being refused, concurrent bindings where exactly one wins, binding against a foreign workspace being refused, expired, canceled, already-bound, and never-existed codes returning one indistinguishable answer, and a bound attempt then completing through `complete_pairing/2` to issue the worker and its credential.

- [x] Task 3 — Expose anonymous code issuance with its rate limit and audit.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Give an app with no identity a way to obtain a code without letting an unidentified caller mint them without bound.
  - Owned surfaces: The issuance endpoint and route, its rejection of any caller-supplied identity, workspace, project, or secret, `PairingIssuanceThrottle` and its window, the issuance audit entry, and the endpoint's exclusion of codes from logs and diagnostics.
  - Owns: AC-09, entity:PairingIssuanceThrottle
  - Proof: Controller and integration tests prove one call returns exactly one code for an unbound attempt, caller-supplied identity or workspace fields are ignored rather than honored, requests beyond the allowed rate are refused without revealing any earlier code's fate, the throttle expires with its window, and no request or response body reaches a log.

- [x] Task 4 — Redeem a real code in the dashboard pairing form.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Turn the pairing field into the redemption surface the workflow depends on, instead of a field whose value is discarded.
  - Owned surfaces: `LocalOnboardingLive`'s pairing form submission, its authorized redemption call, its success continuation into repository selection, its failure presentation for a refused code, and its placeholder and error copy.
  - Owns: AC-04
  - Proof: LiveView tests cover a valid code being bound to this browser's own workspace and the screen reporting that the app can now finish, a refused code showing one safe message that does not distinguish the reason, an empty submission being rejected before any call, and the copy no longer advertising a code format the product does not issue.

- [x] Task 5 — Acquire and refresh the code in the worker app.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Keep an unpaired app holding a code the dashboard will still accept, without the person managing expiry.
  - Owned surfaces: Worker-app code acquisition against the bundle-resolved control-plane address, the refresh schedule ahead of expiry, the unreachable-control-plane state, and the retirement of a replaced code.
  - Owns: AC-01
  - Proof: Swift tests against the existing HTTP seam cover acquiring a code on first start, replacing it before expiry, surfacing an unreachable control plane rather than a stale code, and never retaining a replaced code.

- [x] Task 6 — Present the code and copy it from the menu bar.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Give the person the one action the workflow asks of them, on the item they already read for status.
  - Owned surfaces: The unpaired menu-bar states, the status line as the copy action, the copy confirmation, and the absence of any automatic clipboard write.
  - Owns: AC-02
  - Proof: Swift tests cover the menu showing the unpaired state, clicking the status line placing the full code on the clipboard and confirming, the clipboard being untouched until the person acts, and `Open Dashboard` and `Quit` remaining reachable.

- [x] Task 7 — Complete the pairing round trip and enforce its data rules.
  - Status: Complete.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4, Task 6
  - Purpose: Prove the two halves meet: a code shown by the app, redeemed in the dashboard, brings the worker online without the person returning to the app, and leaves nothing behind.
  - Owned surfaces: Retention and deletion of unredeemed unbound attempts, and the diagnostic exclusion of codes and credentials across both sides.
  - Owns: AC-10, AC-11
  - Proof: An integration scenario pairs a worker end to end from an app-issued code bound in the dashboard and completed by the app through `POST /worker_pairings`, showing the app reaching its connected state without further input; retention tests prove an unredeemed attempt is discarded once unusable; and a log and diagnostic review across the control plane and the app finds no code, credential, or fragment of either.

- [x] Task 8 — Run the app's pairing loop so the round trip actually closes.
  - Status: Complete. Reopened once: the success handler discarded the credential and set a permanent `pairedSettingUp`, which left a real install stuck on a setup that never finishes.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5, Task 6, Task 7
  - Purpose: Make the app perform, on a schedule, the calls the rest of this slice proved: replace its code before expiry, try to finish pairing, and stop once it has.
  - Owned surfaces: The unpaired polling schedule in `AppDelegate`, the periodic code refresh, the completion attempt against `POST /worker_pairings` using the held code, the hand-off state shown once completion succeeds, stopping the loop then, and the `capability:worker-initiated-pairing` readiness write-back.
  - Owns: AC-07, AC-08
  - Proof: Swift tests drive the loop's decisions against the existing HTTP and command seams: an unpaired tick refreshes an expiring code, a tick attempts completion with the held code, a refused completion leaves the code and keeps waiting, a successful completion discards the code and shows the hand-off state without claiming a setup, and a paired tick stops polling.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Every active acceptance criterion and data entity has one clear primary task owner.
- [x] Unbound and bound attempt states, one-way single-use binding, concurrency, foreign-workspace refusal, and completion of a bound attempt tests pass.
- [x] Expired, canceled, already-redeemed, and never-existed codes are proven indistinguishable to the caller.
- [x] Anonymous issuance, its rate limit, and its audit pass without honoring any caller-supplied identity or workspace.
- [x] `POST /worker_pairings`, the `Open in App` deep link, and the workspace-scoped `start_pairing/2` path are proven unchanged.
- [x] Required desktop and mobile browser scenarios for the redemption surface pass.
- [x] Worker-app tests for acquisition, refresh, presentation, clipboard, and the post-redemption transition pass.
- [x] Retention of unredeemed attempts and throttle counters passes, and the log, diagnostic, and no-analytics review finds no code or credential.
- [x] `python3 .agents/scripts/run_proof.py slice -- mix check`, and the same through slice scope for `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test`, pass.
- [x] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass through slice scope.
- [x] New decisions and invalidated proof are written back.

## Blocked Decisions

- None. Both required capabilities are ready and `Task 1` is the next executable task.

## Progress Log

See [progress.md](progress.md).
