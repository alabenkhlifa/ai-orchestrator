# Local Project Onboarding Tasks

## Status

In Progress

## Active Slice

Deliver accountless on-device onboarding for one local Git repository through one paired macOS worker, ending on the new project's dashboard with its repository, storage mode, and connection status visible without source upload.

## Implementation Boundary

Included:

- Accountless device workspace required by the local path.
- macOS worker discovery, graphical installation guidance, secure pairing, replacement pairing, and status.
- Native folder selection, local Git repository validation, and moved-repository recovery.
- First-connection privacy disclosure, approved minimum metadata exchange, and atomic project registration.
- Accountless data-loss warning and export-only project-history recovery boundary.
- Direct handoff to the new project's dashboard with repository, storage, and connection state.
- Shared naming and repository-uniqueness rules.
- Connection-state and failure UX.
- Privacy and security proof for device metadata and pairing credentials.

Excluded:

- Hosted storage and passwordless authentication.
- Remote or cloud workers and agent execution.
- Source upload, browsing, editing, or execution from the control plane.
- Shared-operating-system-user isolation.
- Windows and Linux worker delivery and verification.

Deferred after this slice:

- Hosted local-repository projects through `specs/03-hosted-passwordless-access/` and `specs/05-project-storage-lifecycle/`.
- Combined catalog implementation that preserves separate project identities and shows one authoritative entry after explicit migration or resynchronization.
- Windows worker support, followed by Linux worker support.

Release boundary:

- This slice may be implemented and verified independently.
- The first usable release remains blocked until `specs/01-github-project-onboarding/` and every shared dependency invoked by both onboarding paths also pass their release gates.
- Coordinated browser proof must show that `Work without GitHub` and `Login with GitHub` are both available and complete from the same entry surface.

## Tasks

- [x] Establish the accountless device-workspace boundary.
  - Purpose: Persist local project ownership without requiring an account.
  - Proof: Tests show stable access under the same OS boundary, isolation from hosted authorization, and a clear loss outcome that never presents repository reconnection as restoration of missing project history.
  - Delivered: `DeviceStore` behaviour, durable local DETS adapter (`DeviceStore.Local`), and the `Devices` context; ownership derives from device id and storage mode only. The repository-reconnection-is-not-restoration clause is completed under Task 4, where a connection exists. Native worker adapter and durable device store are release-gated.

- [ ] Implement worker discovery and installation guidance.
  - Purpose: Give non-technical users an actionable path when no worker is available.
  - Proof: macOS browser scenarios cover detected, missing, incompatible, and unavailable worker states plus graphical installation without terminal commands.

- [x] Implement secure workspace-bound pairing.
  - Purpose: Authorize one worker for one workspace without transferable credentials.
  - Proof: Security tests cover attempt expiry, confirmation, replay rejection, revocation, rotation, replacement-worker pairing, and cross-workspace denial.
  - Delivered: `PairingAttempt` and `LocalWorker` (hosted authorization metadata keyed by an opaque `device_workspace_id`) and the `Pairing` context — single-use attempt-bound codes, per-worker salted-digest credentials, rotation, revocation, and workspace-scoped authorization. Raw codes and credentials are never persisted. The native worker endpoint and outbound transport remain release-gated.

- [ ] Implement local repository selection and validation.
  - Purpose: Validate one user-selected Git repository entirely on the worker.
  - Proof: Integration and UI tests cover native folder selection, valid, invalid, inaccessible, moved, non-matching, and unavailable repositories plus canonical-identity reconnection without source upload.

- [ ] Define and enforce minimum outbound metadata.
  - Purpose: Establish connection and compatibility state without sending local paths, remote URLs, filenames, Git history, or source code during onboarding.
  - Proof: Contract and privacy tests reject prohibited fields and any outbound onboarding exchange before first-use confirmation, while allowing later unchanged connections without repeated confirmation.

- [ ] Create the project and local repository connection atomically.
  - Purpose: Apply shared naming and uniqueness rules without partial records.
  - Proof: Tests cover concurrency, duplicate identity, suffix allocation, rollback, and unchanged repository state.

- [ ] Build local onboarding and connection-state UX.
  - Purpose: Complete the path without requiring terminal interaction beyond any approved installer step.
  - Proof: Desktop and mobile scenarios cover graphical installation, pairing, native selection, first-connection disclosure and confirmation, accessible later disclosure, data-loss warning, success, direct new-project dashboard routing, visible repository, storage mode, connection status, replacement-worker pairing, `Locate repository` recovery, and project-portability handoff when an export exists.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Pairing security and cross-workspace isolation tests pass.
- [ ] Worker and repository integration tests pass on the approved macOS versions.
- [ ] Source-upload, prohibited-onboarding-data, first-confirmation, and metadata-minimization checks pass.
- [ ] Accountless data-loss scenarios distinguish export import, repository reconnection, and new project history.
- [ ] Project naming, uniqueness, atomicity, and connection-state tests pass.
- [ ] Successful creation opens the new project's dashboard with the required repository, storage, and connection state.
- [ ] Required browser scenarios pass.
- [ ] The coordinated first-release browser scenarios prove that both primary entry actions are available and complete.
- [ ] GDPR data contract and privacy review for device metadata and credentials are complete.
- [ ] Build, formatting, lint, static checks, and logs review pass.

## Blocked Decisions

- None.

## Release Gate

- Real macOS signing, notarization, and update-channel verification on supported macOS hosts, which needs an Apple signing identity and the notarization service.
- If the control plane is hosted, the hosting processor, region, and transfer safeguards for outbound device metadata and pairing credentials.
- Final privacy review and confirmation of retention durations for the device-metadata and pairing-credential data contract recorded in `design.md`.

## Progress Log

### 2026-07-23 - Extracted from project onboarding

- Completed: Isolated the accepted local-repository, accountless-device, worker-pairing, source-locality, and connection-state behavior.
- Remaining: Resolve worker architecture, repository identity, metadata, privacy, integration, and verification decisions.
- Failed checks: None; implementation has not started.
- Spec updates: Created a focused local onboarding specification without changing accepted product behavior.

### 2026-07-24 - Local setup and recovery checkpoint

- Completed: Approved the local-onboarding product requirements, including macOS scope, native folder selection, explicit connection recovery, first-connection privacy disclosure, export-only project-history recovery, and stable-identity combined-catalog behavior.
- Remaining: Resolve the classified metadata-contract, technical, privacy, and verification blockers before implementation can start.
- Failed checks: None; implementation has not started.
- Spec updates: Product requirements moved from `Draft` to `Approved`; tasks remain `Blocked` at technical design and implementation readiness.

### 2026-07-27 - Technical design and privacy contract resolved

- Completed: Resolved the minimum outbound connection contract, canonical repository fingerprint, macOS packaging and signing, workspace-bound pairing and outbound transport, on-device storage seam, worker verification strategy, and the device-metadata data-protection contract in `design.md`.
- Remaining: Implement the slice on the approved contracts; complete the release-gate signing, notarization, hosting-processor, and final privacy-review items.
- Failed checks: None; implementation has not started.
- Spec updates: Cleared the technical-design and privacy blockers, replaced `Blocked Decisions` with a `Release Gate`, and moved tasks from `Blocked` to `Not Started`.

### 2026-07-27 - Implementation preflight: greenfield confirmed, serialized behind slice 03 foundation

- Completed: `implement-spec` preflight on branch `slice/02-local-project-onboarding` (dedicated worktree, dev/test server port 4002). The local-onboarding slice is greenfield on top of the slice-01 GitHub and slice-05 storage foundation, so `Not Started` is accurate and there is no spec-vs-code drift. Missing entirely: the local-worker subsystem — worker discovery UX, `LocalWorker`, `PairingAttempt`, on-worker git validation, the canonical salted `repository_fingerprint`, and the minimum outbound `RepositoryConnectionContract`. Partial: the device-workspace boundary is an in-memory struct with no persistence and the database rejects device roots (`workspaces_hosted_kind_only`); `Projects.register_project/3` refuses the device path; local onboarding UI is a placeholder; the connection-state vocabulary is GitHub-only.
- Environment-blocked (coordination): slice 02 and Codex's active slice 03 both edit the same foundation — device versus hosted workspace persistence in `accounts.ex` and the `workspaces` table, session and accountless access in `user_auth.ex`, the shared `entry_live.ex` surface, and `privacy/processing_inventory.ex`. Per the parallel-agent contract the user chose to serialize behind slice 03: wait for Codex to commit its shared-foundation changes, then rebase `slice/02-local-project-onboarding` onto updated `main` and build device support on top. No application code changed.
- Failed checks: None; implementation intentionally not started.
- Spec updates: Progress recorded only; status remains `Not Started`.

### 2026-07-27 - Task 1 complete: accountless device-workspace persistence

- Completed: Added the `DeviceStore` behaviour, a durable local DETS adapter (`DeviceStore.Local`), and the `Devices` context so the accountless device workspace persists under the operating-system boundary and never in the hosted database, plus the `Device Persistence Adapter` decision in `design.md`. Ownership derives from the device id and storage mode with no hosted identity.
- Proof: `mix test test/sdd_orchestrator/devices/device_store_test.exs` passed (4 tests: stable access, hosted-identity isolation, cross-restart durability, and loss-yields-fresh-workspace); full suite 298 passed, 1 excluded (`:live`); `mix format --check-formatted` and `mix compile --warnings-as-errors` exit 0.
- Failed checks: None.
- Spec updates: Status `Not Started` → `In Progress`; Task 1 checked. The repository-reconnection-is-not-history-restoration clause is owned by Task 4; the native worker adapter and durable device store remain release-gated.

### 2026-07-27 - Task 3 complete: secure workspace-bound pairing

- Completed: Added `PairingAttempt`, `LocalWorker`, the `Pairing` context, and the `local_workers`/`pairing_attempts` migration, plus the `Pairing Authorization Persistence` decision in `design.md`. Implemented ahead of Task 2 because worker discovery reports on paired workers and needs the worker/pairing domain first (legacy tasks, reconstructed dependency).
- Proof: `mix test test/sdd_orchestrator/devices/pairing_test.exs` passed (10 tests: confirmation, replay rejection, expiry, invalid-code rejection, cross-workspace denial, revocation, rotation, replacement-worker pairing, and digest-only persistence); full suite 308 passed, 1 excluded (`:live`); `mix format --check-formatted` and `mix compile --warnings-as-errors` exit 0.
- Failed checks: None.
- Spec updates: Task 3 checked. The native worker endpoint, outbound transport, and packaging remain release-gated.
