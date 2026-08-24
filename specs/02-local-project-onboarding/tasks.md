# Local Project Onboarding Tasks

## Status

In Progress

Tasks 1–10 are complete. The local implementation and slice-scoped verification pass; coordinated first-release browser proof and the final privacy review remain open at the release boundary. Task 10 replaced the hardcoded macOS compatibility window with a computed one, closing the staleness defect `specs/36-local-worker-native-distribution` Task 12 found. Task 11 is new and unstarted: it refreshes a paired worker's liveness from the control plane's own attached-worker registry, per the Registry-Derived Worker Liveness decision in `design.md`, closing the second defect that same proof found.

## Active Slice

Deliver accountless on-device onboarding for one local Git repository through one paired macOS worker, ending on the new project's dashboard with its repository, storage mode, and connection status visible without source upload.

## Cross-Specification Dependencies

Requires:

- None.

Provides:

- `capability:workspace-bound-local-worker-authorization` — ready after `Task 3`.
- `capability:portable-local-repository-identity` — ready after `Task 9`.

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof expected to run in about ten minutes.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.
- Completed task labels and proof history are preserved; the portability correction is split into a pure identity boundary and one source-side integration workflow.

## Proof Scope Gate

- Applies to: Task 10, Task 11.

## Implementation Boundary

Included:

- Accountless device workspace required by the local path.
- macOS worker discovery, graphical installation guidance, secure pairing, replacement pairing, and status.
- Native folder selection, local Git repository validation, and moved-repository recovery.
- Versioned portable local repository identity generation and exact matching without source workspace identity.
- Workspace-bounded duplicate comparison and explicit source-side upgrade of legacy workspace-scoped fingerprints.
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
- Global repository-identity lookup or correlation across independently onboarded workspaces.

Deferred after this slice:

- Hosted local-repository projects through `specs/03-hosted-passwordless-access/` and `specs/05-project-storage-lifecycle/`.
- Combined catalog implementation that preserves separate project identities and shows one authoritative entry after explicit migration or resynchronization.
- Windows worker support, followed by Linux worker support.
- Deferred criteria: AC-24, AC-25, AC-26, AC-27
- Deferred entities: none.

Release boundary:

- This slice may be implemented and verified independently.
- The first usable release remains blocked until `specs/01-github-project-onboarding/` and every shared dependency invoked by both onboarding paths also pass their release gates.
- Coordinated browser proof must show that `Work without GitHub` and `Login with GitHub` are both available and complete from the same entry surface.
- Release criteria: AC-02
- Release entities: none.

## Tasks

- [x] Task 1 - Establish the accountless device-workspace boundary.
  - Size: Standard
  - Purpose: Persist local project ownership without requiring an account.
  - Owned surfaces: `DeviceWorkspace`, `DeviceStore` behavior, durable development adapter, operating-system ownership boundary, hosted-persistence exclusion, and data-loss behavior.
  - Owns: AC-01, AC-28, AC-29, entity:DeviceWorkspace
  - Depends on: none
  - Proof: Tests show stable access under the same OS boundary, isolation from hosted authorization, and a clear loss outcome that never presents repository reconnection as restoration of missing project history.
  - Delivered: `DeviceStore` behaviour, durable local DETS adapter (`DeviceStore.Local`), and the `Devices` context; ownership derives from device id and storage mode only. The repository-reconnection-is-not-restoration clause is completed under Task 4, where a connection exists. Native worker adapter and durable device store are release-gated.

- [x] Task 3 - Implement secure workspace-bound pairing.
  - Size: Standard
  - Purpose: Authorize one worker for one workspace without transferable credentials.
  - Owned surfaces: `capability:workspace-bound-local-worker-authorization`, `PairingAttempt`, `LocalWorker`, attempt expiry and replay protection, credential issuance and digest persistence, workspace authorization, revocation, rotation, and replacement pairing.
  - Owns: AC-04, AC-19, AC-31, entity:LocalWorker, entity:PairingAttempt
  - Depends on: Task 1
  - Proof: Security tests cover attempt expiry, confirmation, replay rejection, revocation, rotation, replacement-worker pairing, and cross-workspace denial.
  - Delivered: `PairingAttempt` and `LocalWorker` (hosted authorization metadata keyed by an opaque `device_workspace_id`) and the `Pairing` context — single-use attempt-bound codes, per-worker salted-digest credentials, rotation, revocation, and workspace-scoped authorization. Raw codes and credentials are never persisted. `capability:workspace-bound-local-worker-authorization` is ready. The native worker endpoint and outbound transport remain release-gated.

- [x] Task 2 - Implement worker discovery and installation guidance.
  - Size: Standard
  - Purpose: Give non-technical users an actionable path when no worker is available.
  - Owned surfaces: Worker compatibility and reachability policy, detected, missing, incompatible, and unavailable states, graphical installation guidance, retry, and development worker stand-in.
  - Owns: AC-03, AC-05, AC-18
  - Depends on: Task 3
  - Proof: macOS browser scenarios cover detected, missing, incompatible, and unavailable worker states plus graphical installation without terminal commands.
  - Delivered: `Devices.WorkerDiscovery` (macOS 14/15, protocol 1, `last_seen_at` reachability) plus `Devices.worker_status/1` over `Pairing.active_workers/1` and `Pairing.mark_seen/1`, and `LocalOnboardingLive` rendering all four states — `:missing` (graphical download + pairing-code entry, no terminal command), `:incompatible` (update/reinstall + replacement pairing), `:unavailable` (start-and-retry, projects stay visible), and `:detected` (continue to native selection). `ConnectionStatus.device_connection_badge/1` shows connection state. The `:device_worker_stub` flag (on in dev/test, off in prod) drives a local worker stand-in through pairing and native folder selection so the graphical flow is exercisable without the signed native worker. Proof is LiveView tests over all four states asserting terminal-free install guidance; the coordinated Playwright browser scenarios land with Task 7.

- [x] Task 4 - Implement local repository selection and legacy validation.
  - Size: Standard
  - Purpose: Validate one user-selected Git repository entirely on the worker.
  - Owned surfaces: Native selection handoff, Git repository and root-commit validation, legacy workspace-scoped fingerprint generation and matching, moved, clone, worktree, and changed-remote stability, and source-local execution.
  - Owns: AC-06, AC-17, AC-32
  - Depends on: Task 2
  - Proof: Integration and UI tests cover native folder selection, valid, invalid, inaccessible, moved, non-matching, and unavailable repositories plus canonical-identity reconnection without source upload.
  - Delivered: `Devices.RepositoryValidation` validates a repository on the worker boundary and returns only a non-reversible canonical fingerprint (HMAC over sorted root-commit ids, per-workspace salt) — stable across moved paths, clones, worktrees, and changed remotes, distinguishing unrelated repositories, with no path or source exposure. The native OS folder dialog is a release-gated native-worker capability; the browser display of the selected repository and the worker-unavailable state land in Task 7; the reconnection-is-not-history-restoration distinction lands with Task 6.

- [x] Task 5 - Define and enforce minimum outbound metadata.
  - Size: Standard
  - Purpose: Establish connection and compatibility state without sending local paths, remote URLs, filenames, Git history, or source code during onboarding.
  - Owned surfaces: `RepositoryConnectionContract`, exhaustive allowed fields, nested compatibility allowlist, prohibited and unexpected field rejection, first-outbound boundary, and minimum metadata proof.
  - Owns: AC-08, AC-09, AC-10
  - Depends on: Task 4
  - Proof: Contract and privacy tests reject prohibited fields and any outbound onboarding exchange before first-use confirmation, while allowing later unchanged connections without repeated confirmation.
  - Delivered: `Devices.RepositoryConnectionContract` defines the exhaustive allowed outbound fields (opaque connection id, workspace and worker ids, repository fingerprint, coarse compatibility, connection status) and fails closed on any prohibited, unexpected, or missing field at the top level and inside compatibility. The first-use disclosure and confirmation gate, and the confirm-once behavior, are delivered in Task 7.

- [x] Task 6 - Create the project and local repository connection atomically.
  - Size: Standard
  - Purpose: Apply shared naming and uniqueness rules without partial records.
  - Owned surfaces: `Project`, `RepositoryConnection`, device registration transaction, case-insensitive naming, repository uniqueness, suffix allocation, idempotent failure behavior, and unchanged repository state.
  - Owns: AC-14, AC-15, AC-16, entity:Project, entity:RepositoryConnection
  - Depends on: Task 5
  - Proof: Tests cover concurrency, duplicate identity, suffix allocation, rollback, and unchanged repository state.
  - Delivered: `DeviceProject` plus device-store registration (`Devices.register_project/2`, `list_projects/0`, `get_project/1`, `find_by_fingerprint/1`) applying the shared workspace-scoped case-insensitive name key (reused from `Projects.Project.name_key/1`) with suffix allocation and one-project-per-repository (by fingerprint) uniqueness. Writes serialize through the store GenServer, so registration is atomic and a rejected registration writes nothing; device data never reaches Postgres and repository files are never touched. This also completes Task 1's deferred clause: after data loss the store is empty, so reconnecting a repository starts new history rather than restoring it.

- [x] Task 7 - Build local onboarding and connection-state UX.
  - Size: Standard
  - Purpose: Complete the path without requiring terminal interaction beyond any approved installer step.
  - Owned surfaces: Local onboarding LiveView, storage explanation, worker and selection handoffs, first-connection disclosure, atomic registration submission, dashboard routing, connection-state presentation, duplicate handoff, replacement pairing, `Locate repository`, responsive accessibility behavior, and project-portability recovery copy.
  - Owns: AC-07, AC-20, AC-30
  - Depends on: Task 6
  - Proof: Desktop and mobile scenarios cover graphical installation, pairing, native selection, first-connection disclosure and confirmation, accessible later disclosure, data-loss warning, success, direct new-project dashboard routing, visible repository, storage mode, connection status, replacement-worker pairing, `Locate repository` recovery, and project-portability handoff when an export exists.
  - Delivered: `LocalOnboardingLive` runs the whole accountless flow as internal steps — storage-mode explanation, worker discovery (Task 2), stub-driven pairing, native folder selection (`RepositoryValidation.validate/2`, name/location shown locally), and a first-connection privacy disclosure that states what stays local, what is shared, and the accountless data-loss limit with a project-portability recovery mention. Confirmation is required once (inferred from an empty device store) and afterwards the disclosure stays accessible behind a disclosure control without re-prompting. Confirming registers the project atomically through `Devices.register_project/2` and routes to `DeviceProjectDashboardLive` at `/local/projects/:id`, which shows the repository, the `On this device` storage mode, and a connection status derived live from `Devices.worker_status/1`. A duplicate repository is blocked (one project per repository) with a link to the existing project. `Locate repository` (a `locate` query parameter carrying the project id) reconnects only a canonical-identity match and treats a non-matching selection as a different repository. Replacement-worker pairing reuses the discovery pairing form. Primary actions are full-width on mobile and never wrap; negative states use error-red icons.

- [x] Task 8 - Implement the versioned portable repository-identity boundary.
  - Size: Standard
  - Purpose: Let an authorized worker generate and exactly match a non-reversible local repository identity without a source workspace key.
  - Owned surfaces: `PortableRepositoryIdentity`, version tag and strict parser, random validation-salt generation, HMAC-SHA256 root-commit digest, constant-time matching, fresh independent identities, legacy-format recognition and original-workspace match, invalid and malformed identifier rejection, and path, credential, raw-object-ID, and workspace-identity exclusion.
  - Owns: AC-11, AC-13, AC-23, entity:PortableRepositoryIdentity
  - Depends on: Task 4
  - Proof: Focused worker-boundary tests cover generation, round trip, exact and mismatched matches, independent salts, moved paths, clones, worktrees, changed remotes, malformed and legacy formats, constant-time comparison seam, forbidden-field absence, and unchanged Git fixtures.
  - Delivered: `Devices.PortableRepositoryIdentity` uses the strict canonical format `local-repo:v1:{validation_salt}:{digest}` with 32-byte URL-safe unpadded components, a fresh cryptographically random validation salt for every generation, and an HMAC-SHA256 digest over Task 4's sorted worker-local root commits. It strictly parses and round-trips portable values, rejects malformed and legacy values from portable matching, performs exact portable and original-workspace legacy matching through `Plug.Crypto.secure_compare/2`, and exposes an explicit comparison seam for proof. `RepositoryValidation.root_commit_ids/1` reuses Task 4's validation while keeping raw Git object ids inside the worker boundary.

- [x] Task 9 - Integrate portable identity creation, duplicate detection, and legacy upgrade.
  - Size: Standard
  - Purpose: Use the portable identity in normal onboarding and upgrade an existing legacy connection only after explicit source-side proof.
  - Owned surfaces: `capability:portable-local-repository-identity`, new-connection identity allocation, workspace-authorized existing-identifier comparison before allocation, duplicate blocking, `RepositoryConnectionContract` versioned identity validation, `Locate repository` legacy-upgrade state, exact legacy proof, atomic device-store canonical-identity replacement and uniqueness recheck, failure and race rollback, actionable backup-readiness handoff, privacy disclosure update, and no global repository-equality query.
  - Owns: AC-12, AC-21, AC-22
  - Depends on: Task 7, Task 8
  - Proof: Focused device-store, onboarding, privacy, and desktop and mobile LiveView tests cover new identity creation, same-workspace duplicate detection, independent-workspace unlinkability, exact portable Locate matching, successful legacy upgrade, mismatch, unavailable worker, uniqueness race, rollback, unchanged repository state, and backup-ready versus upgrade-required results.
  - Delivered: `Devices.select_repository/2` compares only the current device workspace's authorized portable and legacy identities before allocating a fresh portable identity, and local onboarding blocks a match at selection without a global equality query. `RepositoryConnectionContract` now rejects legacy and malformed onboarding identities. `Devices.locate_repository/3` performs exact portable reconnection or exact original-workspace legacy proof, then atomically replaces only the legacy identity through `DeviceStore.replace_repository_identity/4`; the store rechecks the expected project identity, every other identity compared by the worker, portable replacement validity, and repository uniqueness so mismatches, unavailable sources, concurrent changes, and uniqueness races preserve the original project. The privacy disclosure explains independent identifiers and deliberate same-project transfer, while the device dashboard reports `backup_ready` or an actionable `upgrade_required` handoff.

- [x] Task 10 - Compute the macOS compatibility window instead of hardcoding it.
  - Size: Standard
  - Proof scope: Focused
  - Purpose: Stop the supported macOS major window from silently drifting stale between Apple releases — the failure `specs/36-local-worker-native-distribution` Task 12 hit against a real current-OS machine.
  - Owned surfaces: `WorkerDiscovery.compatibility_policy/0`'s macOS-major computation, the macOS-major/GA-release-date reference table, and the one-major forward-tolerance boundary for a released major not yet added to that table.
  - Owns: none (compatibility-window correctness fix already covered by Task 2's AC-03; owns no unique acceptance criterion or data entity).
  - Depends on: Task 2
  - Proof: Focused tests cover the computed window at each tabulated release-date boundary (the day before and the day of), continued rejection below the computed floor and two or more majors above the highest tabulated entry, and acceptance of exactly one major above the highest tabulated entry.
  - Delivered: `WorkerDiscovery` now computes its supported macOS majors from `@macos_releases`, a maintained ascending major/GA-release-date table, evaluated against the instant under test: the current major is the highest tabulated major already released, and the window is that row plus the tabulated row immediately before it. Because Apple's numbering is not contiguous (15 was followed by 26), "the previous major" resolves to the previous tabulated row rather than `major - 1`, which corrects the window from the nonexistent `25`/`26` pair to the real `15`/`26`. `compatible?/2` and `compatibility_policy/1` accept `now:` (a `DateTime` or a `Date`) so the window is provable at any instant, and `status/2` threads it through. A worker reporting exactly one major above the highest tabulated entry is tolerated as compatible; two or more above, anything below the computed floor, and any non-numeric or missing major stay incompatible. `LocalOnboardingLive`'s install-guidance copy now renders the computed window instead of a hardcoded "macOS 25 and 26", so the guidance cannot drift from the policy it describes.

- [ ] Task 11 - Refresh worker liveness from the attached-worker registry.
  - Size: Standard
  - Proof scope: Focused
  - Purpose: Keep a genuinely connected worker reported connected instead of going stale about ninety seconds after the last dev stand-in refresh — the defect `specs/36-local-worker-native-distribution` Task 12 found running the real signed worker.
  - Owned surfaces: The supervised periodic worker-liveness refresher, its enumeration of `Delivery.CommandTransport.Channel`'s attached-worker registry, its refresh interval relative to `WorkerDiscovery.staleness_seconds/0`, and its environment gating in the control-plane supervision tree.
  - Owns: none (AC-15 and AC-18 already own the observable connection-state behavior; this task makes them truthful against a real worker and introduces no new acceptance criterion or data entity).
  - Depends on: Task 2
  - Proof: Focused tests cover one refresher pass marking every attached worker seen, leaving a paired but unattached worker untouched, tolerating a revoked or inactive worker without failing the pass, and moving `WorkerDiscovery.status/2` from `:unavailable` to `:detected` across a pass without any worker-initiated call.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Pairing security and cross-workspace isolation tests pass.
- [x] Worker and repository integration tests pass on the approved macOS versions.
- [x] Source-upload, prohibited-onboarding-data, first-confirmation, and metadata-minimization checks pass.
- [x] Accountless data-loss scenarios distinguish export import, repository reconnection, and new project history.
- [x] Project naming, uniqueness, atomicity, and connection-state tests pass.
- [x] Successful creation opens the new project's dashboard with the required repository, storage, and connection state.
- [x] Required browser scenarios pass.
- [ ] The coordinated first-release browser scenarios prove that both primary entry actions are available and complete.
- [ ] GDPR data contract and privacy review for device metadata and credentials are complete.
- [x] Build, formatting, lint, static checks, and logs review pass.
- [x] Portable identity generation, exact target matching, independent-workspace unlinkability, same-workspace duplicate detection, and malformed-identifier tests pass.
- [x] Legacy source-side upgrade, atomic rollback, backup-readiness handoff, and unchanged-repository proofs pass.

## Blocked Decisions

- None.

## Release Gate

- Real macOS signing, notarization, and update-channel verification on supported macOS hosts, which needs an Apple signing identity and the notarization service.
- If the control plane is hosted, the hosting processor, region, and transfer safeguards for outbound device metadata and pairing credentials.
- Final privacy review and confirmation of retention durations for the device-metadata and pairing-credential data contract recorded in `design.md`.

## Progress Log

See [progress.md](progress.md).
