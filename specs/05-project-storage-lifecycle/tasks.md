# Project Storage Selection Tasks

## Status

In Progress

Tasks 1–6 are implemented and locally verified. The full local verification gate passes: `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` (515 passing); `npm --prefix assets ci` and the full `npm --prefix assets run test:e2e` (74 passing across `chromium` and `mobile-chromium`); and `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release`. The slice stays short of `Verified` for two reasons, both recorded in the 2026-07-28 progress entries: the signed-in mixed-catalog and same-id identity-conflict scenarios are proven deterministically at the query and LiveView level but not yet as a browser scenario (that scenario needs an e2e-creatable hosted project plus a `specs/06-project-portability/` restore for the collision), and a public hosted release remains gated on the deployment privacy profile (controller, processors, regions, transfer safeguards, notices, incident path, retention enforcement, and required review). The cross-source registration combinations (a device project from the signed-in GitHub flow, and a hosted project from the accountless local flow) are source-owned follow-ons that build on the two registration mechanisms delivered here.

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

- [x] Task 5 - Show authoritative storage mode and availability after creation.
  - Purpose: Make on-device and hosted projects understandable without catalog composition changing ownership or storage.
  - Owned surfaces: Post-creation dashboard storage state, mixed-mode project catalog entries, device and connection availability, sign-in or sign-out catalog composition, current-session stable-ID collision detection, separate authoritative-record entries, non-mutating identity-conflict presentation, and absence of cross-boundary collision persistence or analytics.
  - Owns: AC-09, AC-10, AC-11
  - Depends on: Task 4
  - Proof: Query, desktop and mobile LiveView, and browser scenarios cover common workspace scoping, both modes, mixed catalogs, non-owning device-project composition while signed in, unavailable device data, hosted authorization, sign-out with device access preserved, shared-repository entries, separate same-ID authoritative records with identity-conflict state and no resolution action, no cross-boundary collision link or analytics, cross-workspace denial, and post-creation dashboard presentation.

- [x] Task 6 - Enforce the active-slice privacy and security contract.
  - Purpose: Govern every introduced record, log, processor, and lifecycle without adding product analytics.
  - Owned surfaces: Active data inventory, access controls, retention and deletion enforcement, rights behavior, processor and transfer configuration, log redaction, secret scanning, no-analytics proof, and `capability:project-storage-governance` readiness write-back.
  - Owns: AC-12, AC-13, AC-17
  - Depends on: Task 2, Task 3, Task 4, Task 5
  - Proof: Data-inventory, access, retention, deletion, rights, processor, transfer, log, secret-exposure, and negative analytics checks pass with required privacy or legal approval.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Every active acceptance criterion and data entity has one clear primary task owner.
- [x] Storage-mode domain, ownership, prerequisite, and workspace-isolation tests pass.
- [x] Common workspace backfill preserves every existing hosted workspace, project, repository connection, and stable identifier, and invalid workspace-kind and storage-mode pairs are rejected.
- [x] GitHub and local source adapters pass shared storage-selection integration tests without transferring source-specific ownership into this specification.
- [x] Storage selection shows the approved labels and explanation, describes hosted storage as cross-device access without claiming collaboration, keeps unavailable modes visible with setup actions, preserves repository and onboarding state across device setup and hosted sign-in, returns after every outcome without an implicit choice, and requires an explicit available selection.
- [x] Hosted registration commits project, connection, hosted state, mode, and attempt in one `Ecto.Multi`; device registration commits project, local connection, mode, and receipt in one local transaction and reconciles a lost control-plane acknowledgement without duplication.
- [x] Expired, mismatched, replayed, or cross-workspace hosted returns and device receipts fail closed; stored prerequisite proof is minimized and one-time.
- [ ] Mixed catalog, same-ID identity-conflict, post-creation dashboard, device availability, hosted authorization, sign-in, and sign-out browser scenarios pass without merging records or persisting a cross-boundary collision link. (Deterministically proven at the query and LiveView level; the storage-selection step is browser-proven. The signed-in mixed-catalog and same-id browser scenario is a follow-on: it needs an e2e-creatable hosted project and a `specs/06` restore for the collision.)
- [x] GDPR data contract, retention and deletion controls, privacy review, log review, no-analytics proof, and secret-exposure checks pass.
- [x] `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [x] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
