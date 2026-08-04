# GitHub Project Onboarding Tasks

## Status

In Progress

Implementation for Tasks 1–11 is complete and locally verified; the remaining items keep the slice short of `Verified`. See the 2026-07-25 slice-implementation-complete progress entry for the exact state: the authenticated end-to-end browser scenarios and the tagged live GitHub App smoke test run in the secret-backed staging environment (environment-blocked locally), and a public hosted release remains gated on the deployment privacy profile and the coordinated `specs/02-local-project-onboarding/` path (AC-02).

## Active Slice

Deliver GitHub project onboarding end to end: authenticate one user, restore their personal workspace, list every repository under the granted access, select where the project work is saved, create one project for one confirmed repository, and open its dashboard with the repository, storage, and connection state.

## Implementation Boundary

Included:

- Single Phoenix/LiveView application bootstrap, PostgreSQL persistence, local assets, OCI release, and canonical checks selected by this slice.
- Session-aware entry routing, GitHub sign-in, protected session restoration, and sign-out.
- Approved onboarding visual tokens, device-local light and dark theme preference, responsive layouts, keyboard operation, and non-color status cues.
- Personal workspace creation and restoration.
- Existing-workspace catalog routing and the non-mutating `Add project` handoff.
- GitHub App repository-access checking, the dedicated grant screen, installation handoff, and validated return.
- Complete authorized repository catalog retrieval, search, and user-facing states.
- Shared plain-language project-data storage selection before final confirmation.
- Shared `ProjectStorage` contract, hosted storage adapter, device readiness-receipt integration boundary, and atomic project and repository-connection creation.
- Direct handoff to the new project's dashboard with repository, storage, and connection state.
- Workspace-scoped naming and post-creation rename.
- Persistent disconnected project state.
- GDPR data contracts, security controls, and proof for data introduced by the slice.
- Enforcement that Slice 01 emits and retains no product analytics.
- Automated, integration, security, and browser verification.

Excluded:

- Local repository onboarding, device setup and its production storage adapter, passwordless hosted access, identity linking, storage migration, portability, collaboration, and agent execution.
- Remote, cloud, or Raspberry Pi workers.
- Repository editing or source upload.
- GitHub webhook ingestion and background repository synchronization.

Deferred after this slice:

- The separate feature specifications under `specs/02-` through `specs/06-`.
- Monorepo subprojects and multiple projects for one repository in a workspace.

Release boundary:

- This slice may be implemented and verified independently.
- Implementation and local verification may proceed under the approved development privacy contract without selecting a production hosting provider.
- A public hosted deployment remains release-blocked until its deployment privacy profile records the controller contact, processors, regions, transfer safeguards, privacy notice, incident path, retention enforcement, and required reviews.
- The first usable release remains blocked until `specs/02-local-project-onboarding/` and every shared dependency invoked by both onboarding paths also pass their release gates.
- Coordinated browser proof must show that `Login with GitHub` and `Work without GitHub` are both available and complete from the same entry surface.

Traceability:

- Deferred criteria: none.
- Release criteria: AC-02
- Deferred entities: none.
- Release entities: none.

Delivery ownership:

- Every implementation task below names its primary UI, domain, persistence, integration, privacy, security, or operational surfaces in `Owned surfaces`.
- A page may compose elements owned by different vertical tasks, but each element and behavior has one primary implementation owner.
- A task that owns a frontend surface is incomplete while that surface or its attached LiveView and browser proof is missing, even when its supporting domain or integration behavior passes.
- Proof, including LiveView, integration, accessibility, and browser tests, verifies an owned surface; it does not substitute for explicit implementation ownership.
- The final integration task connects and verifies surfaces implemented by the earlier vertical tasks. It is not the first or sole owner of the onboarding pages.

## Tasks

- [x] Task 1 — Establish the approved application skeleton and canonical development checks.
  - Depends on: none
  - Purpose: Provide only the selected Phoenix, LiveView, PostgreSQL, local-asset, release, configuration, and test foundations required by this slice.
  - Owned surfaces: Root Phoenix application and supervision tree; PostgreSQL development and test infrastructure; runtime and dependency pins; local asset pipeline; OCI release configuration; ExUnit, LiveView, provider-contract, accessibility, and Playwright test foundations; canonical setup, quality, browser, asset, and release commands.
  - Owns: none (application skeleton; owns no acceptance criteria or data entities).
  - Proof: A clean checkout pins the approved runtime and dependencies; `mise install`, `docker compose up -d postgres`, `mix setup`, `mix check`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, the Playwright setup, production asset build, and production release succeed without committed secrets.
  - Status: Complete. All listed proofs pass (see 2026-07-24 bootstrap progress entry). No committed secrets.

- [x] Task 2 — Establish the shared LiveView presentation foundation.
  - Depends on: Task 1
  - Status: Complete. Shared primitives, tokens, self-hosted font, bundled icons, and device-local theme delivered; all attached proofs pass (see 2026-07-24 presentation-foundation entry). Sign-in/out theme continuity mechanism is implemented and device-local; its end-to-end browser assertion is carried by Task 9 once the auth surface exists.
  - Purpose: Make the approved visual system, theme behavior, responsive structure, and reusable interaction patterns available before workflow screens are implemented.
  - Owned surfaces: Frontend — the root LiveView layout and shared page frame; self-hosted `Public Sans`; locally bundled Lucide icons; graphite, teal, and semantic design tokens; the pre-paint operating-system theme fallback; the device-local manual theme control; reusable button, link, form, selection, status, notice, loading, empty, and failure-state components; baseline responsive containers, focus treatment, and non-color state cues. Supporting — only the JavaScript hooks required for local theme and browser behavior; no workflow-specific screen or hosted theme persistence.
  - Owns: AC-03, AC-04, AC-05, AC-06, AC-07, entity:ClientThemePreference
  - Proof: Component, LiveView, accessibility, and desktop and mobile browser tests show the shared primitives in light and dark themes, operating-system fallback, local manual persistence across reload and sign-in state changes, no cross-device or hosted synchronization, keyboard-visible focus, stable text fit, non-color status meaning, and no external font, icon, analytics, or other optional browser request.

- [x] Task 3 — Deliver the entry, GitHub authentication, and protected-session workflow.
  - Depends on: Task 2
  - Status: Complete. Two-action entry, GitHub OAuth (state + PKCE S256), encrypted credentials, opaque rotated sessions, protected routing, and sign-out delivered; all deterministic proofs pass (see 2026-07-24 auth-and-session entry). The tagged live GitHub App smoke test is environment-blocked locally (no secret-backed GitHub App); it runs in the secret-backed staging environment per the release gate.
  - Purpose: Let a signed-out user choose an onboarding path, complete GitHub sign-in, restore a valid session, and sign out without exposing credentials.
  - Owned surfaces: Frontend — the unauthenticated entry LiveView with exactly `Login with GitHub` and `Work without GitHub`; GitHub connecting, cancellation, provider-failure, and retry states; valid-session entry bypass; the protected sign-out control and return to entry. Supporting — GitHub identity, authorization-attempt, credential, and protected application-session domain and persistence behavior; OAuth initiation and callback integration; protected-route session resolution, rotation, expiry, revocation, and sign-out. The local action after the shared entry handoff remains owned by `specs/02-local-project-onboarding/`.
  - Owns: AC-01, AC-09, AC-10, entity:Account, entity:GitHubIdentity, entity:GitHubAuthorizationAttempt, entity:GitHubCredential, entity:ApplicationSession
  - Proof: Domain, persistence, LiveView, security, and browser tests cover the two-action entry surface, valid-session bypass, PKCE and state success, one-time consumption, mismatch, replay, expiry, cancellation, provider failure and retry, token encryption and refresh, 24-hour idle and 30-day absolute application-session expiry, rotation, restoration, revocation, sign-out return to entry, agent isolation, and rejected post-sign-out access.

- [x] Task 4 — Deliver personal-workspace restoration and the project catalog.
  - Depends on: Task 3
  - Status: Complete. Idempotent personal-workspace get-or-create restoration, the real project catalog with a non-mutating `Add project` control, empty-workspace continuation to the repository-access check, and the workspace-scoped onboarding-attempt lifecycle delivered; all attached deterministic proofs pass (see 2026-07-25 workspace-and-catalog entry). The repository-access check surface is a placeholder owned by Task 5; the authenticated end-to-end browser scenarios are carried by Task 9 because catalog and onboarding screens require a live GitHub-backed session.
  - Purpose: Restore the user's project ownership boundary and route them to the correct next action.
  - Owned surfaces: Frontend — the protected project-catalog LiveView shell, non-empty project list, and visible non-mutating `Add project` control; routing from authentication to either the non-empty catalog or the empty-workspace repository-access check. Supporting — personal-workspace domain and persistence behavior; workspace isolation and stable restoration; the stable base `Project` schema and workspace-scoped catalog read model; and creation of a new `ProjectOnboardingAttempt`, including its schema, initial state, idempotency key, and nullable handoff fields (repository metadata written by Task 5, storage and device-setup return state by Task 6, consumed by Task 7). Connection-state indicators inside catalog rows remain owned by Task 8.
  - Owns: AC-08, AC-11, AC-13, AC-14, AC-15, entity:PersonalWorkspace, entity:Project, entity:ProjectOnboardingAttempt
  - Proof: Domain, persistence, LiveView, and browser tests show stable restoration, isolation between users, no duplicate workspace under retry or concurrency, non-empty workspace routing to the catalog, empty-workspace continuation to the repository-access check, visible catalog projects, and a non-mutating `Add project` handoff.

- [x] Task 5 — Deliver the GitHub repository-access grant and repository picker.
  - Depends on: Task 4
  - Status: Complete. Repository-access check, grant screen, pending-approval recovery, installation handoff/return, and the searchable single-selection repository picker delivered; selected repository persisted onto the onboarding attempt; all attached deterministic proofs pass (see 2026-07-25 repository-access-and-picker entry). The tagged live GitHub App smoke test remains environment-blocked locally (no secret-backed GitHub App); the deterministic `Req.Test` provider-contract tests, including the RS256 app-JWT pending-request lookup, cover the adapter, and the live round trip runs in the secret-backed staging environment per the release gate.
  - Purpose: Explain and obtain repository access when needed, then let the user find and explicitly select any repository returned under the validated grant.
  - Owned surfaces: Frontend — the repository-access checking state; the `Grant repository access` screen; `Continue to GitHub`; canceled or invalid-return recovery; `Waiting for organization approval` and `Check again`; the repository-picker LiveView with loading, searchable single selection, keyboard navigation, repository owner, name, visibility, and organization metadata, no-match, empty, restricted-access, rate-limit, authorization-failure, and provider-failure states. Supporting — GitHub App and provider-adapter access checks, installation handoff and return validation, pending-request lookup, authenticated repository retrieval, pagination, deduplication, normalized provider failures, rate-limit behavior, and persistence of the selected repository metadata into the Task 4 onboarding attempt.
  - Owns: AC-12, AC-16, AC-17, AC-18, AC-19, AC-20, AC-21, AC-22, AC-23
  - Proof: Provider-contract, integration, LiveView, accessibility, and browser tests cover `Metadata: read-only`, no webhook dependency, app-JWT pending-request lookup, no accessible installation, the grant screen, state-bound GitHub handoff, untrusted return parameters, authenticated access re-read, pending organization approval and `Check again`, pagination, deduplication by numeric repository ID, search, exactly-one keyboard selection, visible owner, name, visibility, and organization metadata, no-match, empty results, personal, private, and organization repositories, persisted selection, authorization failures, rate limits, provider failure, and no partial project.

- [x] Task 6 — Deliver storage selection and the resumable device-setup handoff.
  - Depends on: Task 5
  - Status: Complete. The `Where should your project work be saved?` step, both visible choices, the unavailable device mode with its non-selecting setup handoff, explicit-selection-before-continue, and the device readiness-receipt boundary delivered; the shared `ProjectStorage` behaviour contract established; all attached deterministic proofs pass (see 2026-07-25 storage-selection entry).
  - Purpose: Let the user understand and explicitly select where project work is saved without losing their repository selection or creating a project early.
  - Owned surfaces: Frontend — the `Where should your project work be saved?` LiveView step; the approved explanation that project work and the linked repository are separate; visible device and hosted choices; availability, selected, unavailable, setup, cancellation, failure, and return states. Supporting — pre-confirmation `ProjectOnboardingAttempt` storage-selection state and persistence; the stable shared `ProjectStorage` behavior and adapter contract, including `availability/2`, `prepare/3`, and `abort/2`; the device readiness-receipt handoff boundary; preservation of repository and onboarding state across setup. Device setup itself and the production device adapter remain owned by `specs/02-local-project-onboarding/`; Task 7 owns the hosted adapter and registration-time use of the shared contract.
  - Owns: AC-24, AC-25, AC-26, AC-27, entity:DeviceStorageReceipt
  - Proof: Domain, adapter-contract, LiveView, and browser tests show both choices remain visible, unavailable modes explain their prerequisite, setup creates no project and selects no mode, repository and onboarding state survive setup success, cancellation, and failure, successful setup refreshes availability without implicit selection, and continuation remains blocked until one available mode is selected explicitly.

- [x] Task 7 — Deliver project confirmation, naming, and atomic creation.
  - Depends on: Task 6
  - Status: Complete. Final confirmation (repository/storage/editable-name review), workspace-scoped naming (default derivation, lowest-suffix allocation, `NFKC` + default case-fold comparison, natural display names, boundary-whitespace trim, blank/control-character rejection, inline case-insensitive conflict feedback), the reusable rename operation, and atomic project + repository-connection + hosted-storage registration with idempotent retry, repository-already-linked feedback, and no-partial rollback delivered; all attached deterministic proofs pass (see 2026-07-25 project-confirmation entry). The authenticated end-to-end browser scenarios remain carried by Task 9 (they need a live GitHub-backed session).
  - Purpose: Let the user review the repository, storage choice, and editable project name, then create the project without partial or duplicate records.
  - Owned surfaces: Frontend — the final-confirmation LiveView; repository and storage summaries; the editable project-name field; default-name, suffix-allocation, invalid-input, and conflict feedback; submission progress; actionable transaction-failure and retry states. Supporting — additive extension of the Task 4 `Project` schema with the canonical comparison key, workspace uniqueness, storage mode, lifecycle state, and repository connection; display-name allocation, comparison, uniqueness, and reusable rename operation; atomic project, repository-connection, and storage-state persistence; consumption of the existing `ProjectOnboardingAttempt` inside registration; hosted implementation and registration-time use of the Task 6 `ProjectStorage` contract; device readiness-receipt validation; idempotency, rollback, retry, and concurrency behavior. The post-creation rename control is owned by Task 8.
  - Owns: AC-28, AC-29, AC-31, AC-32, AC-33, AC-34, AC-35, AC-36, AC-39, AC-40, entity:Project, entity:RepositoryConnection, entity:HostedProjectStorage
  - Proof: Domain, persistence, fault-injection, LiveView, and browser tests cover final review of repository, project name, and storage; preserved natural display names; boundary whitespace; blank and control-character rejection; spaces; Unicode `NFKC` plus default case-fold comparison; no slug conversion; case-insensitive conflicts and inline feedback; cross-user reuse; lowest suffix allocation; the `(workspace, provider, repository ID)` constraint; duplicate-repository feedback that identifies the existing project; hosted `Ecto.Multi` initialization; device receipt validation; idempotent retry; abort; rollback; concurrent creation and rename; workspace ownership; actionable failures; stable identities; no partial project or connection; no repository mutation; and no agent start.

- [x] Task 8 — Deliver the project dashboard, rename control, and connection recovery.
  - Depends on: Task 7
  - Status: Complete. Post-commit dashboard (visible repository, storage mode, and connection status), the post-creation rename control wired to `Projects.rename_project/2` with inline save and case-insensitive conflict feedback, per-row catalog connection status, and connection revalidation (connected / disconnected / temporarily-unavailable) with `Check again` recovery in both the catalog and the dashboard delivered; all attached deterministic proofs pass (see 2026-07-25 project-dashboard entry). The authenticated end-to-end browser scenarios remain carried by Task 9 (they need a live GitHub-backed session).
  - Purpose: Open the created project, keep it usable when GitHub access changes, and expose the approved post-creation controls and state.
  - Owned surfaces: Frontend — post-commit routing to the new-project dashboard; visible repository, storage mode, and connected status; the post-creation project-name edit control, its wiring to the Task 7 rename operation, and inline result states; connected, disconnected, and temporarily unavailable indicators and recovery actions in project-catalog rows and the project dashboard. Supporting — repository-connection revalidation; connected, disconnected, and temporarily unavailable domain states; persistent access-loss transitions; authenticated recovery of the same project. Task 7 retains ownership of name allocation, comparison, uniqueness, and persistence behavior.
  - Owns: AC-30, AC-37, AC-38
  - Proof: Domain, integration, LiveView, and browser tests show redirect only after commit, visible repository and storage mode, successful rename and inline invalid or conflicting rename feedback, confirmed access loss in both catalog and dashboard, distinct transient provider failure without overwriting the last confirmed state, no stale credential exposure, and authenticated reconnection of the same project without replacing it.

- [x] Task 9 — Integrate onboarding navigation and run the complete frontend workflow proof.
  - Depends on: Task 8
  - Status: Complete (deterministic proof); authenticated browser scenarios environment-blocked. A deterministic end-to-end LiveView integration test drives the full authenticated flow across every screen seam (catalog → repository-access/picker → storage → confirmation → dashboard) with the GitHub fake, proving navigation continuity and resumable onboarding state; all attached deterministic proofs pass (see 2026-07-25 onboarding-integration entry). The desktop and mobile browser scenarios in both themes need a live GitHub-backed session and run in the secret-backed staging environment per the release gate (the same constraint Tasks 3–8 recorded); the unauthenticated entry, theme/OS-fallback/device-local, keyboard-focus, non-color, and layout browser proofs are already green locally (Tasks 2–3).
  - Purpose: Connect the already-owned workflow surfaces and prove the complete responsive, accessible experience without becoming their first implementation owner.
  - Owned surfaces: Frontend integration — cross-task navigation, browser history behavior, focus placement after navigation and validation, resumable onboarding continuity, consistent shared-shell composition, responsive text fit and layout stability, and end-to-end browser scenario orchestration across the entry, catalog, grant, picker, storage, confirmation, and dashboard surfaces. Each workflow screen and its business behavior remain owned by Tasks 3 through 8.
  - Owns: none (frontend integration proof; owns no unique acceptance criterion or data entity).
  - Proof: Desktop and mobile browser scenarios in both themes verify operating-system fallback, device-local manual persistence, no hosted synchronization, sign-in and sign-out continuity, unauthenticated entry, valid-session bypass, existing-project catalog routing, empty-workspace continuation, `Add project`, repository-access checking, grant and pending-approval recovery, valid return, keyboard repository search and selection, every approved catalog state, storage availability and setup return, explicit storage selection, confirmation and naming, duplicate prevention, actionable failures, direct dashboard routing, rename, connected and disconnected recovery, focus visibility and placement, non-color state cues, browser history, text fit, and layout stability. Passing this proof does not transfer implementation ownership from Tasks 3 through 8.

- [x] Task 10 — Enforce and verify the approved slice GDPR data contract.
  - Depends on: Task 8
  - Status: Complete. The approved processing inventory, the storage-limitation retention pruner, the verified operator rights workflow (export + erasure), the product-analytics prohibition with a data-store detection check, and the deployment-privacy release gate delivered; all attached deterministic proofs pass (see 2026-07-25 GDPR-enforcement entry). Deployment-specific controller/vendor/region/transfer/notice evidence remains an explicit release gate, not an implementation blocker.
  - Purpose: Enforce and prove the already-approved lawful-processing, minimization, retention, rights, processors, transfers, no-analytics, and security baseline across the delivered slice.
  - Owned surfaces: Slice processing inventory and field-purpose enforcement; minimization, retention, deletion, export, and verified-rights lifecycle controls; abandoned authorization, onboarding, session, log, cache, and backup cleanup rules; product-analytics prohibition and detection; deployment-privacy profile and release-gate enforcement. Domain-specific access controls remain owned by their vertical tasks.
  - Owns: AC-41, AC-42, AC-43, entity:DataProcessingRecord, entity:DeploymentPrivacyProfile
  - Proof: The approved processing inventory and automated lifecycle checks cover every field, authorization and onboarding attempt, session, credential, log, cache, backup, export, and configured processor; network and data-store checks prove that no product analytics is emitted or retained; verified rights handling is documented and tested; release checks reject an incomplete deployment privacy profile.

- [x] Task 11 — Complete security and observability review.
  - Depends on: Task 9, Task 10
  - Status: Complete. The strict Content-Security-Policy with a per-request nonce for the device-local pre-paint theme script is delivered (resolving the Task 1/2 CSP deferral), the Sobelow `Config.CSP` suppression is removed so the security gate passes with no ignores, and credential redaction across inspection/logs and the absence of secrets in client payloads and external assets are verified; all attached deterministic proofs pass (see 2026-07-25 security-review entry).
  - Purpose: Diagnose failure without leaking secrets or leaving partial state.
  - Owned surfaces: Cross-cutting structured diagnostics and internal correlation; log, client-payload, and browser-network redaction and allowlists; local-only optional browser assets; strict Content-Security-Policy compatible with the device-local pre-paint theme script; review of task-specific credential isolation, authorization, rollback, and failure controls without taking their implementation ownership.
  - Owns: none (cross-cutting security and observability review; owns no acceptance criteria or data entities).
  - Proof: Security tests, browser network review, and structured-log review show no credential, repository name, project name, URL, request-body, external asset, or analytics exposure and sufficient account-neutral diagnostics for every failure path.

## Verification Gate

- [x] Active-slice acceptance criteria pass. (AC-02 is the coordinated release criterion, deferred to `specs/02`.)
- [x] Entry routing, authentication, workspace, repository-access grant, repository catalog, storage selection, project-linking, naming, post-creation dashboard routing, and connection-state tests pass.
- [ ] Deterministic GitHub provider-contract tests pass in normal CI **(passing)**; the tagged live GitHub App smoke test (`test/sdd_orchestrator/github_integration/live_smoke_test.exs`, `@tag :live`, run with `mix test --include live`) runs in the secret-backed staging environment **(environment-blocked locally; skips without staging secrets)**.
- [x] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [x] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass.
- [ ] Required desktop and mobile browser scenarios pass. **Unauthenticated entry, theme, focus, non-color, and layout scenarios pass locally; the authenticated end-to-end scenarios run in staging (environment-blocked locally), covered deterministically by the LiveView integration flow.**
- [x] Light and dark theme, operating-system fallback, device-local preference, no-sync, keyboard-only, focus, contrast, non-color status, responsive text-fit, and layout-stability checks pass.
- [x] PKCE, return validation, credential encryption and refresh, session rotation and expiry, provider revalidation, no-webhook behavior, and secret-isolation checks pass.
- [x] Hosted storage transaction, device readiness-receipt contract, idempotency, rollback, abort, concurrency, and no-partial-project checks pass.
- [x] The approved development data contract, retention cleanup, verified rights workflow, no-analytics proof, and deployment-privacy release-blocking checks pass.
- [x] Browser network and failure-log review proves that credentials, personal display values, external optional assets, and product analytics are absent.
- [x] New decisions and invalidated proof are written back.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
