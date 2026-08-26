# Worker-Initiated Pairing Tasks

## Status

Not Started

## Active Slice

Let someone pair a freshly installed worker app without an existing project: the app obtains and shows a live pairing code, the person copies it from the menu bar and redeems it in the dashboard, that redemption binds the code to their own Mac project space and authorizes the worker, and the app reaches its connected state on its own.

## Cross-Specification Dependencies

Requires:

- `capability:workspace-bound-local-worker-authorization` — provider `specs/02-local-project-onboarding#Task 3` — required before `Task 2`.
- `capability:signed-macos-worker-distribution` — provider `specs/36-local-worker-native-distribution#Task 12` — required before `Task 5`.

Provides:

- `capability:worker-initiated-pairing` — ready after `Task 7`.

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
- One authorized bind-and-complete redemption that attaches the attempt to the redeeming owner's device workspace and authorizes one worker.
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

- [ ] Task 1 — Introduce the unbound pairing attempt and its state constraints.
  - Size: Exception — the column, its backfill, and the constraints expressing the two valid states are one migration; applying them separately leaves existing rows momentarily violating the constraint that defines a valid attempt.
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let an attempt exist with no device workspace without making the workspace optional for anything that authorizes a worker.
  - Owned surfaces: `PairingAttempt` schema and changesets, the nullable `device_workspace_id`, the database constraints expressing unbound and bound as the only valid states, and existing-row backfill.
  - Owns: AC-03, entity:PairingAttempt
  - Proof: Migration and schema tests prove an unbound attempt inserts, a bound attempt inserts, the mixed invalid state is rejected by the database, every pre-existing attempt remains valid and bound, and no existing workspace-scoped caller changed behavior.

- [ ] Task 2 — Implement authorized bind-and-complete redemption.
  - Size: Exception — binding the workspace and authorizing the worker are one transaction; an attempt that is bound but not completed is a workspace-attached credential with no holder.
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Make redemption the single moment a code stops being inert and starts authorizing exactly one worker for exactly one owner.
  - Owned surfaces: The bind-and-complete operation in `Devices.Pairing`, its single-use and one-way binding enforcement, its ownership check against the redeeming owner's own device workspace, and its uniform refusal answer.
  - Owns: AC-04, AC-05, AC-06
  - Proof: Domain and transaction tests cover a valid redemption binding to the redeemer's own workspace and authorizing one worker, a second redemption of the same code being refused, concurrent redemptions where exactly one wins, redemption against a foreign workspace being refused, and expired, canceled, already-redeemed, and never-existed codes returning one indistinguishable answer.

- [ ] Task 3 — Expose anonymous code issuance with its rate limit and audit.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Give an app with no identity a way to obtain a code without letting an unidentified caller mint them without bound.
  - Owned surfaces: The issuance endpoint and route, its rejection of any caller-supplied identity, workspace, project, or secret, `PairingIssuanceThrottle` and its window, the issuance audit entry, and the endpoint's exclusion of codes from logs and diagnostics.
  - Owns: AC-09, entity:PairingIssuanceThrottle
  - Proof: Controller and integration tests prove one call returns exactly one code for an unbound attempt, caller-supplied identity or workspace fields are ignored rather than honored, requests beyond the allowed rate are refused without revealing any earlier code's fate, the throttle expires with its window, and no request or response body reaches a log.

- [ ] Task 4 — Redeem a real code in the dashboard pairing form.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 2
  - Purpose: Turn the pairing field into the redemption surface the workflow depends on, instead of a field whose value is discarded.
  - Owned surfaces: `LocalOnboardingLive`'s pairing form submission, its authorized redemption call, its success continuation into repository selection, its failure presentation for a refused code, and its placeholder and error copy.
  - Owns: AC-01
  - Proof: LiveView tests cover a valid code pairing the worker and continuing the flow, a refused code showing one safe message that does not distinguish the reason, an empty submission being rejected before any call, and the copy no longer advertising a code format the product does not issue.

- [ ] Task 5 — Acquire and refresh the code in the worker app.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 3
  - Purpose: Keep an unpaired app holding a code the dashboard will still accept, without the person managing expiry.
  - Owned surfaces: Worker-app code acquisition against the bundle-resolved control-plane address, the refresh schedule ahead of expiry, the unreachable-control-plane state, and the retirement of a replaced code.
  - Owns: AC-07
  - Proof: Swift tests against the existing HTTP seam cover acquiring a code on first start, replacing it before expiry, surfacing an unreachable control plane rather than a stale code, and never retaining a replaced code.

- [ ] Task 6 — Present the code and copy it from the menu bar.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 5
  - Purpose: Give the person the one action the workflow asks of them, on the item they already read for status.
  - Owned surfaces: The unpaired menu-bar states, the status line as the copy action, the copy confirmation, and the absence of any automatic clipboard write.
  - Owns: AC-02
  - Proof: Swift tests cover the unpaired menu offering the copy action, clicking it placing the full code on the clipboard and confirming, the clipboard being untouched until the person acts, and `Open Dashboard` and `Quit` remaining reachable.

- [ ] Task 7 — Complete the pairing round trip and enforce its data rules.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4, Task 6
  - Purpose: Prove the two halves meet: a code shown by the app, redeemed in the dashboard, brings the worker online without the person returning to the app, and leaves nothing behind.
  - Owned surfaces: The app's transition out of the unpaired state after an external redemption, retention and deletion of unredeemed unbound attempts, the diagnostic exclusion of codes and credentials across both sides, and the `capability:worker-initiated-pairing` readiness write-back.
  - Owns: AC-08, AC-10, AC-11
  - Proof: An integration scenario pairs a worker end to end from an app-issued code redeemed in the dashboard and shows the app reaching its connected state without further input; retention tests prove an unredeemed attempt is discarded once unusable; and a log and diagnostic review across the control plane and the app finds no code, credential, or fragment of either.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Every active acceptance criterion and data entity has one clear primary task owner.
- [ ] Unbound and bound attempt states, one-way single-use binding, concurrency, and foreign-workspace refusal tests pass.
- [ ] Expired, canceled, already-redeemed, and never-existed codes are proven indistinguishable to the caller.
- [ ] Anonymous issuance, its rate limit, and its audit pass without honoring any caller-supplied identity or workspace.
- [ ] `POST /worker_pairings`, the `Open in App` deep link, and the workspace-scoped `start_pairing/2` path are proven unchanged.
- [ ] Required desktop and mobile browser scenarios for the redemption surface pass.
- [ ] Worker-app tests for acquisition, refresh, presentation, clipboard, and the post-redemption transition pass.
- [ ] Retention of unredeemed attempts and throttle counters passes, and the log, diagnostic, and no-analytics review finds no code or credential.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check`, and the same through slice scope for `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test`, pass.
- [ ] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass through slice scope.
- [ ] New decisions and invalidated proof are written back.

## Blocked Decisions

- None. Both required capabilities are ready and `Task 1` is the next executable task.

## Progress Log

See [progress.md](progress.md).
