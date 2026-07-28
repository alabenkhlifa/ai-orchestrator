# Project Storage Selection Tasks

## Status

In Progress

## Active Slice

Deliver one shared storage-selection foundation that lets GitHub and local repository onboarding establish an explicit device or hosted storage mode, commit it atomically with project creation, and show it consistently without implementing later storage migration.

## Cross-Specification Dependencies

Requires:

- None.

Provides:

- `capability:project-storage-authority` — ready after `Task 4`.
- `capability:project-storage-governance` — ready after `Task 6`.

## Implementation Boundary

Included:

- Shared device and hosted storage-mode values, ownership boundaries, and prerequisite contracts.
- Plain-language, explicit storage choice for GitHub and local repository projects.
- Resumable device setup and hosted sign-in with preserved repository and onboarding state.
- Atomic persistence of project, repository connection, and authoritative storage mode.
- Storage-mode and availability presentation in project catalogs and on the new-project dashboard.
- Non-mutating identity-conflict presentation when currently available authoritative records share a stable project ID.
- GDPR data contracts and security controls for introduced records and paths.
- Shared-domain, integration, privacy, security, and browser proof.

Excluded:

- Authentication, worker installation, repository selection, and other source-specific onboarding mechanics already owned by `specs/01-github-project-onboarding/`, `specs/02-local-project-onboarding/`, and `specs/03-hosted-passwordless-access/`.
- Storage-mode migration, transfer, authority handoff, synchronization, retained hosted copies, soft deletion, retention, cleanup, legal exceptions, and rehydration.
- Collaboration behavior, repository transfer, portability packages, project deletion, and agent execution.
- Resolution, merge, synchronization, deletion, or authority selection for later-visible same-ID records.

Deferred after this slice:

- A separate child specification for storage-mode migration and the resulting hosted-copy lifecycle.
- Deferred criteria: none.
- Deferred entities: none.

Release boundary:

- This shared selection slice and both source-owned onboarding integrations must pass before the first usable release.
- A public hosted deployment remains gated on its deployment-specific controller, processor, region, transfer, notice, incident, retention-enforcement, and required privacy or legal evidence.
- Release criteria: none.
- Release entities: none.

## Tasks

- [x] Task 1 - Approve the storage-selection privacy contract.
  - Purpose: Resolve the active data inventory and lifecycle blocker before coding continues.
  - Owned surfaces: Active-slice purpose, lawful basis, minimum fields, access, retention, deletion, rights, processor, transfer, review, and release-gate contract.
  - Owns: none (agreement gate)
  - Depends on: none
  - Proof: Requirements, design, data contracts, task ownership, sequence, and canonical test commands have no unresolved active-slice blockers, and accountable privacy approval is recorded.

- [x] Task 2 - Implement the shared project-storage domain boundary.
  - Purpose: Introduce one common logical workspace schema across hosted and device persistence, represent one explicit authoritative mode, and validate ownership without changing existing hosted project identity or copying device project data.
  - Owned surfaces: `Workspace`, hosted-root backfill with stable existing IDs, device-local workspace schema contract, `StorageMode`, logical `ProjectStorageState`, `DeviceWorkspace`, `PersonalWorkspace`, per-destination workspace-kind and mode constraints, signed-in device-project ownership, availability contract, and adapter-specific persistence shape.
  - Owns: AC-05, AC-06, AC-15, entity:Workspace, entity:StorageMode, entity:ProjectStorageState, entity:DeviceWorkspace, entity:PersonalWorkspace, entity:HostedProjectStorage
  - Depends on: Task 1
  - Proof: Migration, local-schema contract, constraint, and domain tests cover stable hosted backfill IDs, valid mode and workspace-kind pairs in each destination, hosted detail rows, absence of hosted device project and connection data, device ownership regardless of sign-in, non-owning personal-workspace composition, workspace isolation, invalid state, and rollback.

- [x] Task 3 - Implement the shared storage-selection and resumable prerequisite handoff.
  - Purpose: Let users understand and explicitly choose where project work is saved while preserving repository state across prerequisite setup.
  - Owned surfaces: Storage-selection LiveView and components, both approved options and cross-device-only hosted copy, availability states, origin and target workspace state, browser-flow and return binding, device-setup and hosted-sign-in return actions, `ProjectOnboardingAttempt`, bound and minimized `DeviceStorageReceipt`, and source-adapter handoff contract.
  - Owns: AC-01, AC-02, AC-03, AC-14, AC-16, entity:ProjectOnboardingAttempt, entity:DeviceStorageReceipt
  - Depends on: Task 2
  - Proof: Service, LiveView, and browser tests cover both repository-source adapters, approved copy without a collaboration promise, visible unavailable modes, stable origin and explicit target ownership, device setup and hosted sign-in, preserved state, success, cancellation, failure, expiry, mismatch, replay, cross-workspace denial, minimized proof persistence, refreshed availability after success, account-neutral unsuccessful sign-in, and no implicit selection or project creation.

- [x] Task 4 - Integrate storage state with atomic project creation.
  - Purpose: Prevent projects with a missing, ambiguous, unavailable, or partially initialized storage boundary.
  - Owned surfaces: Explicit-selection validation, stable destination project ID, workspace-kind and mode revalidation, `Project`, hosted `Ecto.Multi`, device-local worker transaction, repository-connection transaction participation, hosted-root insertion or device-receipt consumption, destination acknowledgement, adapter preparation and abort or reconciliation, onboarding-attempt consumption, unique idempotency constraints, committed retry, and `capability:project-storage-authority` readiness write-back.
  - Owns: AC-04, AC-07, AC-08, entity:Project
  - Depends on: Task 2, Task 3
  - Proof: Hosted and device transaction, constraint, concurrency, retry, replay, lost-acknowledgement, and fault-injection tests prove one destination contains the project, connection, matching owner and mode, and adapter state or no partial destination state; committed retries return the same project, device reconciliation consumes the transient attempt without duplication, failed preparation is aborted or reconciled, and repository content remains unchanged.

- [ ] Task 5 - Show authoritative storage mode and availability after creation.
  - Purpose: Make on-device and hosted projects understandable without catalog composition changing ownership or storage.
  - Owned surfaces: Post-creation dashboard storage state, mixed-mode project catalog entries, device and connection availability, sign-in or sign-out catalog composition, current-session stable-ID collision detection, separate authoritative-record entries, non-mutating identity-conflict presentation, and absence of cross-boundary collision persistence or analytics.
  - Owns: AC-09, AC-10, AC-11
  - Depends on: Task 4
  - Proof: Query, desktop and mobile LiveView, and browser scenarios cover common workspace scoping, both modes, mixed catalogs, non-owning device-project composition while signed in, unavailable device data, hosted authorization, sign-out with device access preserved, shared-repository entries, separate same-ID authoritative records with identity-conflict state and no resolution action, no cross-boundary collision link or analytics, cross-workspace denial, and post-creation dashboard presentation.

- [ ] Task 6 - Enforce the active-slice privacy and security contract.
  - Purpose: Govern every introduced record, log, processor, and lifecycle without adding product analytics.
  - Owned surfaces: Active data inventory, access controls, retention and deletion enforcement, rights behavior, processor and transfer configuration, log redaction, secret scanning, no-analytics proof, and `capability:project-storage-governance` readiness write-back.
  - Owns: AC-12, AC-13, AC-17
  - Depends on: Task 2, Task 3, Task 4, Task 5
  - Proof: Data-inventory, access, retention, deletion, rights, processor, transfer, log, secret-exposure, and negative analytics checks pass with required privacy or legal approval.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Every active acceptance criterion and data entity has one clear primary task owner.
- [ ] Storage-mode domain, ownership, prerequisite, and workspace-isolation tests pass.
- [ ] Common workspace backfill preserves every existing hosted workspace, project, repository connection, and stable identifier, and invalid workspace-kind and storage-mode pairs are rejected.
- [ ] GitHub and local source adapters pass shared storage-selection integration tests without transferring source-specific ownership into this specification.
- [ ] Storage selection shows the approved labels and explanation, describes hosted storage as cross-device access without claiming collaboration, keeps unavailable modes visible with setup actions, preserves repository and onboarding state across device setup and hosted sign-in, returns after every outcome without an implicit choice, and requires an explicit available selection.
- [ ] Hosted registration commits project, connection, hosted state, mode, and attempt in one `Ecto.Multi`; device registration commits project, local connection, mode, and receipt in one local transaction and reconciles a lost control-plane acknowledgement without duplication.
- [ ] Expired, mismatched, replayed, or cross-workspace hosted returns and device receipts fail closed; stored prerequisite proof is minimized and one-time.
- [ ] Mixed catalog, same-ID identity-conflict, post-creation dashboard, device availability, hosted authorization, sign-in, and sign-out browser scenarios pass without merging records or persisting a cross-boundary collision link.
- [ ] GDPR data contract, retention and deletion controls, privacy review, log review, no-analytics proof, and secret-exposure checks pass.
- [ ] `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [ ] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass.

## Blocked Decisions

- None.

## Progress Log

### 2026-07-28 - Task 4 complete: attempt-integrated atomic registration for both destinations

- Hosted destination (AC-04, AC-07, AC-08): already delivered — `Projects.register_project/3` commits the project, its canonical repository connection, the hosted storage root, and attempt consumption in one `Ecto.Multi`, rolls back atomically, and returns the same project for a committed retry (proven by `project_registration_test`).
- Device destination (new): added `Projects.register_device_project/3`. The device store owns the atomic worker transaction that commits the on-device project, its fingerprint connection, and the device mode under the operating-system boundary — nothing device-authoritative is written to hosted PostgreSQL. The commit is idempotent by the attempt's key (`DeviceProject.idempotency_key`, deduped in `DeviceStore.Local` before the repository-uniqueness check), so a committed retry returns the same project and a lost control-plane acknowledgement is reconciled without a duplicate. After the local commit the transient control-plane attempt is acknowledged by consumption. Creation is blocked without an explicit, available device mode (`:storage_mode_required` / `:storage_not_ready`). The accountless local flow's review/create step now registers through this path.
- Passing proofs: `MIX_ENV=test mix test test/sdd_orchestrator/projects/device_registration_test.exs` (6: AC-07 commit + acknowledgement + no hosted write, AC-04/AC-08 explicit-selection and readiness blocking, committed-retry idempotency, lost-acknowledgement reconciliation, repository-already-linked); full `MIX_ENV=test mix test` (507 passed, 1 excluded live test); `mix format --check-formatted`; `mix credo --strict`; `mix dialyzer`; and `mix compile --warnings-as-errors`.
- Follow-on (source-owned cross-source combinations, per the `Shared Contract, Source-Owned Integration` decision): registering an on-device project from the signed-in GitHub flow, and a hosted project from the accountless local flow (the local hosted-continue remains a placeholder and needs a local-repository hosted connection shape). Both build on the two registration mechanisms this task delivers and are owned by `specs/01` and `specs/02` integration.

### 2026-07-28 - Task 3 complete: local flow routed through the shared step and browser-proven

- Local-flow integration (fulfills `specs/02` requirement 19, the anticipated storage-mode integration): after repository selection the accountless local onboarding flow creates a device-origin onboarding attempt with the selected repository's fingerprint and name, records the detected worker's readiness as a bound receipt so on-device storage is available, and hands off to the shared storage-selection step. Choosing on-device returns to the local review/create step (resumed from the attempt) and registers the on-device project as before; hosted-from-accountless creation remains owned by the atomic-registration task. The `local_onboarding_flow_test` end-to-end proof was updated to drive selection → shared storage step → review → create and passes.
- Browser proof (`assets/e2e/storage-selection.spec.js`): drives the accountless flow to the shared storage step and asserts the approved source-neutral copy, both modes visible, hosted unavailable with a non-selecting sign-in action, on-device ready through the worker receipt, no silent default, a blocked continue, and no axe accessibility violations. It passes on both the desktop `chromium` and `mobile-chromium` Playwright projects against the real Phoenix server.
- Full proof status: Task 3's service, LiveView, and browser tests now cover both repository-source adapters (GitHub numeric-identity handoff and local fingerprint handoff) with the accountless browser path proven end to end; the authenticated GitHub browser path remains `specs/01`'s owned integration. Task 3 is complete. The remaining slice-level gate items — `MIX_ENV=prod mix assets.deploy`, `MIX_ENV=prod mix release`, and the full `npm --prefix assets run test:e2e` across every spec — are run at slice verification after Tasks 4–6.

### 2026-07-28 - Task 3 static, type, security, and unit gate green; browser proof classified

- Gate results: `mix compile --warnings-as-errors` (dev and test), `mix format --check-formatted`, `mix credo --strict` (no issues), `mix deps.audit` (no vulnerabilities), `mix sobelow --config` (no findings), `mix dialyzer` (passed; 7 pre-existing skips, none new), and the full `mix test` (501 passed, 1 excluded live browser test) all pass. The `20260728160000` migration applies, rolls back, and reapplies cleanly on the test database, and the dev database is migrated.
- Coverage of Task 3's proof at the deterministic (service, LiveView, and domain) level: both repository-source adapters (GitHub numeric identity and local fingerprint-plus-name handoff), approved copy without a collaboration promise, both modes visible with unavailable modes explained, stable origin and explicit target ownership, device setup and hosted sign-in return actions, preserved repository and onboarding state across the handoff, sign-in success, cancellation, failure, receipt expiry, mismatch, replay, cross-workspace denial, minimized proof persistence, refreshed availability after success, account-neutral unsuccessful sign-in, and no implicit selection or project creation.
- Remaining for Task 3, classified: the browser (Playwright + axe) modality is the only outstanding proof element. Reaching the shared storage step in a running browser requires an in-flight attempt, so — consistent with the `Shared Contract, Source-Owned Integration` design decision and the existing e2e specs, which prove behavior deterministically at the LiveView level — the end-to-end browser proof is coupled to each source's owned onboarding integration routing into this shared step (GitHub already routes to `/onboarding/storage/:attempt_id`; the accountless local flow's routing into `/onboarding/local/storage/:attempt_id` is source-owned by `specs/02` and not yet wired). Also outstanding: optionally surfacing the source-adapter handoff as a first-class contract module, and the device-mode `continue` target, which the atomic-registration task (Task 4) wires. Task 3 stays `In Progress` until the browser proof and that integration land.

### 2026-07-28 - Task 3 accountless storage surface and hosted sign-in return (AC-02, AC-14)

- Engineering mechanism: Generalized the single shared `StorageSelectionLive` to serve both origins through its `live_action` scope — `:hosted` (authenticated GitHub) keeps the existing behavior, and `:device` mounts the accountless local flow through `Devices.establish_workspace/0` and the device-scoped attempt lookup. Added the accountless route `/onboarding/local/storage/:attempt_id` in a new `:local_storage` live session whose on-mounts resolve both the current account and the current hosted access, added the missing `log-in` icon, and made the render availability-driven for both modes with per-mode setup actions.
- AC-02: Hosted storage now renders visible-but-unavailable with a non-selecting `Sign in` action for a device-origin attempt, while device renders unavailable with its own setup action; both stay visible and neither is silently selected.
- AC-14: `Sign in` hands off to passwordless sign-in bound to a one-time return to this same step; a completed sign-in returns with a hosted session and the accountless mount records the proven hosted workspace as the attempt's prerequisite, refreshing hosted availability without selecting it or creating a project. An unsuccessful sign-in returns without a session, so hosted stays unavailable and no hosted identity is disclosed.
- Passing proofs: `MIX_ENV=test mix test test/sdd_orchestrator_web/live/local_storage_selection_live_test.exs` (9) plus the existing hosted-scope `storage_selection_live_test` (11); full `MIX_ENV=test mix test` (501 passed, 1 excluded live browser test); `MIX_ENV=test mix compile --warnings-as-errors`; `mix format --check-formatted`; and `git diff --check`.
- Remaining for Task 3: the source-adapter handoff contract surfaced as a first-class module and its `both repository-source adapters` service/LiveView coverage; the browser (Playwright + axe) scenarios; and, as source-owned integration, wiring the accountless local flow to route into this shared step (the `continue` device target is a placeholder pending the atomic-registration task).

### 2026-07-28 - Task 3 bound and minimized device-readiness receipt

- Engineering mechanism: Redesigned `DeviceStorageReceipt` to persist only a non-reversible binding — a SHA-256 `digest` of the worker's raw one-time proof plus its nonce, the bound onboarding attempt id, the bound device workspace id, and issue and expiry times. The raw proof is discarded after digesting, and the previously stored raw token and device label no longer enter hosted persistence. `valid_for?/2` additionally binds a device-origin receipt to the attempt's device workspace.
- Fail-closed enforcement: `record_device_receipt/3` verifies the receipt is bound to the attempt (and, for a device-origin attempt, this device workspace) and is unexpired before storing; a mismatched, replayed, or expired receipt returns `:receipt_binding_mismatch` or `:receipt_expired` and writes nothing. Device availability now checks the bound `valid_for?/2` rather than expiry alone, so a receipt bound to another attempt reads as unavailable.
- Passing proofs: `MIX_ENV=test mix test` full suite (492 passed, 1 excluded live browser test); `MIX_ENV=test mix compile --warnings-as-errors`; `mix format --check-formatted`; and `git diff --check`. New proofs cover minimized persistence (no raw proof or device label), digest-only serialization, and cross-attempt, cross-workspace, and expiry denial.

### 2026-07-28 - Task 3 shared attempt origin and identity-gated hosted availability

- Engineering mechanism: Extended the one shared `ProjectOnboardingAttempt` with `origin_kind` (`hosted`/`device`), an opaque `device_workspace_id` (no foreign key, since device workspaces never persist in the hosted database), a `hosted_prerequisite_workspace_id` FK recorded only by a verified sign-in, and a `browser_flow_binding`; made `workspace_id` nullable; and added a database `onboarding_attempt_origin_shape` check so a hosted-origin attempt owns a hosted workspace with no device reference while a device-origin attempt references a device workspace and never carries a hosted owning workspace.
- Behavior: Hosted availability is now identity-gated — a hosted-origin attempt is always available, a device-origin attempt is `{:unavailable, :hosted_sign_in_required}` until a verified sign-in records the hosted prerequisite, and recording either the prerequisite or a device receipt only re-evaluates availability without selecting a mode. The approved, source-neutral storage-selection copy (question, work explanation, and both access-consequence descriptions, including the non-collaboration hosted copy) is centralized in `ProjectStorage`. Device-scoped `start_device_onboarding_attempt`, `get_device_onboarding_attempt`, `select_local_repository`, `record_hosted_prerequisite`, and device heads of `select_storage_mode`/`record_device_receipt` keep accountless attempts isolated from hosted scope.
- Passing proofs: `MIX_ENV=test mix test test/sdd_orchestrator/project_storage/onboarding_origin_test.exs` (9); regression run of `projects_test`, `project_storage_test`, `project_registration_test`, `project_storage/domain_boundary_test`, `storage_selection_live_test` (72); migration apply, rollback, and reapply on the test database; `mix format --check-formatted`; `git diff --check`; and `MIX_ENV=test mix compile --warnings-as-errors`.
- Remaining for Task 3: the bound and minimized `DeviceStorageReceipt` redesign; the accountless storage route with the shared storage LiveView accountless mount, the hosted sign-in return handoff (AC-14) and device-setup return (AC-03); and the source-adapter handoff browser proof for both repository sources.

### 2026-07-28 - Task 3 implementation started

- Preflight: Task 2 is complete. Task 3 owns AC-01, AC-02, AC-03, AC-14, AC-16, `ProjectOnboardingAttempt`, `DeviceStorageReceipt`, the shared storage-selection surface, and the source-adapter handoff contract; its prerequisites exist in the hosted onboarding attempt, passwordless return, device workspace, worker, and local repository-validation foundations.
- Engineering mechanism: Bind every transient attempt to the current signed browser session without persisting the raw binding; store only one-time hosted-return and device-readiness proof digests plus their minimum attempt, workspace, repository, nonce, issue, expiry, and consumption metadata. Treat an existing authenticated hosted session as an available hosted prerequisite only after the attempt and browser binding are verified.
- Source boundary: GitHub continues to supply its approved numeric repository identity. The local adapter supplies only the device-local canonical repository fingerprint and display name to the transient handoff; no path, remote URL, filename, source content, Git history, device label, operating-system username, or stable hardware identifier enters hosted persistence.

### 2026-07-28 - Task 2 completed

- Completed: Verified the common hosted `Workspace` root, one-to-one `PersonalWorkspace`, device-local `DeviceWorkspace` contract, authoritative `StorageMode` and `ProjectStorageState`, stable hosted-ID backfill, destination constraints, device ownership independent of sign-in, and rollback behavior.
- Migration proof: On isolated test database `sdd_orchestrator_test_slice05_migration`, migrated through the legacy project-registration baseline, seeded stable account/workspace/project/connection identities, applied `20260727120000`, confirmed every stable ID and hosted mode, rolled the migration back and confirmed the legacy IDs and account relation, reapplied it, and migrated through the current head.
- Passing proofs: `MIX_ENV=test MIX_TEST_PARTITION=_slice05_tests mix test test/sdd_orchestrator/project_storage/domain_boundary_test.exs test/sdd_orchestrator/project_storage_test.exs test/sdd_orchestrator/accounts_test.exs test/sdd_orchestrator/project_registration_test.exs test/sdd_orchestrator/privacy/rights_test.exs` (67); `mix format --check-formatted`; `MIX_ENV=test mix compile --warnings-as-errors`; `python3 .agents/scripts/validate_spec.py specs/05-project-storage-lifecycle`; and `python3 .agents/scripts/test_validate_spec.py` (14).
- Environment: The prior Docker and Mix filesystem-lock blocker is resolved. A pre-existing repository PostgreSQL container is healthy; proof databases use Slice 05-specific test partitions. The Phoenix server for this worktree remains reserved on port `4005`.

### 2026-07-28 - Parallel sequencing checkpoint

- Sequencing: Foundation-first. This slice owns the shared `Accounts`, `Projects`, `ProjectStorage`, persistence, catalog, dashboard, and privacy implementation needed by project storage selection. Concurrent Slice 06 work is limited to specification refinement until this slice establishes and verifies those shared contracts.
- Isolation: Slice 05 runs in `/Users/alabenkhlifa/IdeaProjects/sdd-orchestrator-slice-05` on `slice/05-project-storage-lifecycle` with local server port `4005`; the Slice 06 owner must use a separate worktree, branch, and port.
- Conflict boundary: Slice 06 must not implement or modify shared storage, project creation, repository uniqueness, catalog collision, or privacy-lifecycle surfaces while Slice 05 owns them.

### 2026-07-27 - Task 2 implementation started

- In progress: Implementing the common logical `Workspace` root, the one-to-one hosted `PersonalWorkspace` profile, the device-local `DeviceWorkspace` contract, shared storage-mode and storage-state validation, stable hosted-ID backfill, and destination constraints.
- Preflight: Task 1 is complete; Task 2 has no forward dependency; active-slice ownership and traceability validate successfully; the full specification-validator suite passes.
- Implemented: Renamed the hosted ownership table into the common root through a reversible migration, backfilled one hosted personal profile per unchanged root ID, constrained hosted roots and projects to hosted mode, tied repository connections to their project's root, added the device-local profile and storage-state contracts without hosted device persistence, made personal-workspace creation root/profile atomic, and extended erasure to delete the root.
- Passing proofs: `python3 .agents/scripts/validate_spec.py specs/05-project-storage-lifecycle`; `python3 .agents/scripts/test_validate_spec.py` (14); `mix format --check-formatted`; `git diff --check`; warnings-as-errors compilation of all changed source modules, database-backed test modules, and the migration against the existing build; standalone `ProjectStorageTest` (11); and direct hosted/device logical-state assertions.
- Environment-blocked: After approval to use Docker and Mix outside the sandbox, the managed execution policy still rejected both escalations. Normal Docker access remains denied on the socket, while database Mix commands cannot acquire Mix's TCP filesystem lock (`:eperm`). Task 2 remains `In Progress`; its implementation is checkpoint-committed at the user's request, but it cannot be marked complete until the migration apply/rollback/reapply proof, focused database-backed ExUnit tests, and required project checks pass.

### 2026-07-26 - Scope health checkpoint

- Completed: Narrowed the prior lifecycle umbrella to focused initial storage selection; approved the product and privacy requirements; and defined the common logical workspace schema, single authoritative-mode persistence, bound prerequisite handoff, destination-atomic and idempotent registration, non-mutating presentation of later-visible same-ID records, lifecycle enforcement, and canonical verification design.
- Remaining: Implement Tasks 2–6, reconcile source-specific onboarding specifications and adapters with the shared destination contract, run the verification gate, and create a separate child specification before implementing storage migration or the retained hosted-copy lifecycle.
- Failed checks: None; specification validation passes after the consolidated discovery update.
- Spec updates: Removed migration, synchronization, retention, cleanup, analytics, legal-exception, and identity-collision resolution behavior from this active agreement while preserving stable project and repository identity, keeping later-visible authoritative records separate, and exposing collisions without mutation or cross-boundary tracking.
