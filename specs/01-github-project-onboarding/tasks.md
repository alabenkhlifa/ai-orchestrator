# GitHub Project Onboarding Tasks

## Status

In Progress

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
  - Purpose: Provide only the selected Phoenix, LiveView, PostgreSQL, local-asset, release, configuration, and test foundations required by this slice.
  - Owned surfaces: Root Phoenix application and supervision tree; PostgreSQL development and test infrastructure; runtime and dependency pins; local asset pipeline; OCI release configuration; ExUnit, LiveView, provider-contract, accessibility, and Playwright test foundations; canonical setup, quality, browser, asset, and release commands.
  - Owns: none (application skeleton; owns no acceptance criteria or data entities).
  - Proof: A clean checkout pins the approved runtime and dependencies; `mise install`, `docker compose up -d postgres`, `mix setup`, `mix check`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, the Playwright setup, production asset build, and production release succeed without committed secrets.
  - Status: Complete. All listed proofs pass (see 2026-07-24 bootstrap progress entry). No committed secrets.

- [x] Task 2 — Establish the shared LiveView presentation foundation.
  - Status: Complete. Shared primitives, tokens, self-hosted font, bundled icons, and device-local theme delivered; all attached proofs pass (see 2026-07-24 presentation-foundation entry). Sign-in/out theme continuity mechanism is implemented and device-local; its end-to-end browser assertion is carried by Task 9 once the auth surface exists.
  - Purpose: Make the approved visual system, theme behavior, responsive structure, and reusable interaction patterns available before workflow screens are implemented.
  - Owned surfaces: Frontend — the root LiveView layout and shared page frame; self-hosted `Public Sans`; locally bundled Lucide icons; graphite, teal, and semantic design tokens; the pre-paint operating-system theme fallback; the device-local manual theme control; reusable button, link, form, selection, status, notice, loading, empty, and failure-state components; baseline responsive containers, focus treatment, and non-color state cues. Supporting — only the JavaScript hooks required for local theme and browser behavior; no workflow-specific screen or hosted theme persistence.
  - Owns: AC-03, AC-04, AC-05, AC-06, AC-07, entity:ClientThemePreference
  - Proof: Component, LiveView, accessibility, and desktop and mobile browser tests show the shared primitives in light and dark themes, operating-system fallback, local manual persistence across reload and sign-in state changes, no cross-device or hosted synchronization, keyboard-visible focus, stable text fit, non-color status meaning, and no external font, icon, analytics, or other optional browser request.

- [x] Task 3 — Deliver the entry, GitHub authentication, and protected-session workflow.
  - Status: Complete. Two-action entry, GitHub OAuth (state + PKCE S256), encrypted credentials, opaque rotated sessions, protected routing, and sign-out delivered; all deterministic proofs pass (see 2026-07-24 auth-and-session entry). The tagged live GitHub App smoke test is environment-blocked locally (no secret-backed GitHub App); it runs in the secret-backed staging environment per the release gate.
  - Purpose: Let a signed-out user choose an onboarding path, complete GitHub sign-in, restore a valid session, and sign out without exposing credentials.
  - Owned surfaces: Frontend — the unauthenticated entry LiveView with exactly `Login with GitHub` and `Work without GitHub`; GitHub connecting, cancellation, provider-failure, and retry states; valid-session entry bypass; the protected sign-out control and return to entry. Supporting — GitHub identity, authorization-attempt, credential, and protected application-session domain and persistence behavior; OAuth initiation and callback integration; protected-route session resolution, rotation, expiry, revocation, and sign-out. The local action after the shared entry handoff remains owned by `specs/02-local-project-onboarding/`.
  - Owns: AC-01, AC-09, AC-10, entity:Account, entity:GitHubIdentity, entity:GitHubAuthorizationAttempt, entity:GitHubCredential, entity:ApplicationSession
  - Proof: Domain, persistence, LiveView, security, and browser tests cover the two-action entry surface, valid-session bypass, PKCE and state success, one-time consumption, mismatch, replay, expiry, cancellation, provider failure and retry, token encryption and refresh, 24-hour idle and 30-day absolute application-session expiry, rotation, restoration, revocation, sign-out return to entry, agent isolation, and rejected post-sign-out access.

- [x] Task 4 — Deliver personal-workspace restoration and the project catalog.
  - Status: Complete. Idempotent personal-workspace get-or-create restoration, the real project catalog with a non-mutating `Add project` control, empty-workspace continuation to the repository-access check, and the workspace-scoped onboarding-attempt lifecycle delivered; all attached deterministic proofs pass (see 2026-07-25 workspace-and-catalog entry). The repository-access check surface is a placeholder owned by Task 5; the authenticated end-to-end browser scenarios are carried by Task 9 because catalog and onboarding screens require a live GitHub-backed session.
  - Purpose: Restore the user's project ownership boundary and route them to the correct next action.
  - Owned surfaces: Frontend — the protected project-catalog LiveView shell, project list, empty state, and visible non-mutating `Add project` control; routing from authentication to either the non-empty catalog or the empty-workspace repository-access check. Supporting — personal-workspace domain and persistence behavior, workspace isolation, stable restoration, and creation of a new `ProjectOnboardingAttempt`, including its schema, initial state, and idempotency key (repository metadata written by Task 5, storage and device-setup return state by Task 6, consumed by Task 7). Connection-state indicators inside catalog rows remain owned by Task 8.
  - Owns: AC-08, AC-11, AC-13, AC-14, AC-15, entity:PersonalWorkspace, entity:ProjectOnboardingAttempt
  - Proof: Domain, persistence, LiveView, and browser tests show stable restoration, isolation between users, no duplicate workspace under retry or concurrency, non-empty workspace routing to the catalog, empty-workspace continuation to the repository-access check, visible catalog projects, and a non-mutating `Add project` handoff.

- [ ] Task 5 — Deliver the GitHub repository-access grant and repository picker.
  - Purpose: Explain and obtain repository access when needed, then let the user find and explicitly select any repository returned under the validated grant.
  - Owned surfaces: Frontend — the repository-access checking state; the `Grant repository access` screen; `Continue to GitHub`; canceled or invalid-return recovery; `Waiting for organization approval` and `Check again`; the repository-picker LiveView with loading, searchable single selection, keyboard navigation, no-match, empty, restricted-access, rate-limit, authorization-failure, and provider-failure states. Supporting — GitHub App and provider-adapter access checks, installation handoff and return validation, pending-request lookup, authenticated repository retrieval, pagination, deduplication, normalized provider failures, and rate-limit behavior.
  - Owns: AC-12, AC-16, AC-17, AC-18, AC-19, AC-20, AC-21, AC-22, AC-23
  - Proof: Provider-contract, integration, LiveView, accessibility, and browser tests cover `Metadata: read-only`, no webhook dependency, app-JWT pending-request lookup, no accessible installation, the grant screen, state-bound GitHub handoff, untrusted return parameters, authenticated access re-read, pending organization approval and `Check again`, pagination, deduplication by numeric repository ID, search, exactly-one keyboard selection, no-match, empty results, personal, private, and organization repositories, authorization failures, rate limits, provider failure, and no partial project.

- [ ] Task 6 — Deliver storage selection and the resumable device-setup handoff.
  - Purpose: Let the user understand and explicitly select where project work is saved without losing their repository selection or creating a project early.
  - Owned surfaces: Frontend — the `Where should your project work be saved?` LiveView step; the approved explanation that project work and the linked repository are separate; visible device and hosted choices; availability, selected, unavailable, setup, cancellation, failure, and return states. Supporting — pre-confirmation `ProjectOnboardingAttempt` storage-selection state and persistence; `ProjectStorage.availability/2`; the device readiness-receipt handoff boundary; preservation of repository and onboarding state across setup. Device setup itself and the production device adapter remain owned by `specs/02-local-project-onboarding/`.
  - Owns: AC-24, AC-25, AC-26, AC-27, entity:DeviceStorageReceipt
  - Proof: Domain, adapter-contract, LiveView, and browser tests show both choices remain visible, unavailable modes explain their prerequisite, setup creates no project and selects no mode, repository and onboarding state survive setup success, cancellation, and failure, successful setup refreshes availability without implicit selection, and continuation remains blocked until one available mode is selected explicitly.

- [ ] Task 7 — Deliver project confirmation, naming, and atomic creation.
  - Purpose: Let the user review the repository, storage choice, and editable project name, then create the project without partial or duplicate records.
  - Owned surfaces: Frontend — the final-confirmation LiveView; repository and storage summaries; the editable project-name field; default-name, suffix-allocation, invalid-input, and conflict feedback; submission progress; actionable transaction-failure and retry states. Supporting — display-name allocation, comparison, uniqueness, and reusable rename operation; atomic project, repository-connection, and storage-state persistence; consumption of the existing `ProjectOnboardingAttempt` inside registration; the shared `ProjectStorage` preparation and abort contract; hosted adapter; device readiness-receipt validation; idempotency, rollback, retry, and concurrency behavior. The post-creation rename control is owned by Task 8.
  - Owns: AC-28, AC-29, AC-31, AC-32, AC-33, AC-34, AC-35, AC-36, AC-39, AC-40, entity:Project, entity:RepositoryConnection, entity:HostedProjectStorage
  - Proof: Domain, persistence, fault-injection, LiveView, and browser tests cover final review of repository, project name, and storage; preserved natural display names; boundary whitespace; blank and control-character rejection; spaces; Unicode `NFKC` plus default case-fold comparison; no slug conversion; case-insensitive conflicts and inline feedback; cross-user reuse; lowest suffix allocation; the `(workspace, provider, repository ID)` constraint; duplicate-repository feedback that identifies the existing project; hosted `Ecto.Multi` initialization; device receipt validation; idempotent retry; abort; rollback; concurrent creation and rename; workspace ownership; actionable failures; stable identities; no partial project or connection; no repository mutation; and no agent start.

- [ ] Task 8 — Deliver the project dashboard, rename control, and connection recovery.
  - Purpose: Open the created project, keep it usable when GitHub access changes, and expose the approved post-creation controls and state.
  - Owned surfaces: Frontend — post-commit routing to the new-project dashboard; visible repository, storage mode, and connected status; the post-creation project-name edit control, its wiring to the Task 7 rename operation, and inline result states; connected, disconnected, and temporarily unavailable indicators and recovery actions in project-catalog rows and the project dashboard. Supporting — repository-connection revalidation; connected, disconnected, and temporarily unavailable domain states; persistent access-loss transitions; authenticated recovery of the same project. Task 7 retains ownership of name allocation, comparison, uniqueness, and persistence behavior.
  - Owns: AC-30, AC-37, AC-38
  - Proof: Domain, integration, LiveView, and browser tests show redirect only after commit, visible repository and storage mode, successful rename and inline invalid or conflicting rename feedback, confirmed access loss in both catalog and dashboard, distinct transient provider failure without overwriting the last confirmed state, no stale credential exposure, and authenticated reconnection of the same project without replacing it.

- [ ] Task 9 — Integrate onboarding navigation and run the complete frontend workflow proof.
  - Purpose: Connect the already-owned workflow surfaces and prove the complete responsive, accessible experience without becoming their first implementation owner.
  - Owned surfaces: Frontend integration — cross-task navigation, browser history behavior, focus placement after navigation and validation, resumable onboarding continuity, consistent shared-shell composition, responsive text fit and layout stability, and end-to-end browser scenario orchestration across the entry, catalog, grant, picker, storage, confirmation, and dashboard surfaces. Each workflow screen and its business behavior remain owned by Tasks 3 through 8.
  - Owns: none (frontend integration proof; owns no unique acceptance criterion or data entity).
  - Proof: Desktop and mobile browser scenarios in both themes verify operating-system fallback, device-local manual persistence, no hosted synchronization, sign-in and sign-out continuity, unauthenticated entry, valid-session bypass, existing-project catalog routing, empty-workspace continuation, `Add project`, repository-access checking, grant and pending-approval recovery, valid return, keyboard repository search and selection, every approved catalog state, storage availability and setup return, explicit storage selection, confirmation and naming, duplicate prevention, actionable failures, direct dashboard routing, rename, connected and disconnected recovery, focus visibility and placement, non-color state cues, browser history, text fit, and layout stability. Passing this proof does not transfer implementation ownership from Tasks 3 through 8.

- [ ] Task 10 — Define and enforce the slice GDPR data contract.
  - Purpose: Make lawful processing, minimization, retention, rights, processors, transfers, no-analytics enforcement, and security part of implementation approval.
  - Owned surfaces: Slice processing inventory and field-purpose enforcement; minimization, retention, deletion, export, and verified-rights lifecycle controls; abandoned authorization, onboarding, session, log, cache, and backup cleanup rules; product-analytics prohibition and detection; deployment-privacy profile and release-gate enforcement. Domain-specific access controls remain owned by their vertical tasks.
  - Owns: AC-41, AC-42, AC-43, entity:DataProcessingRecord, entity:DeploymentPrivacyProfile
  - Proof: The approved processing inventory and automated lifecycle checks cover every field, authorization and onboarding attempt, session, credential, log, cache, backup, export, and configured processor; network and data-store checks prove that no product analytics is emitted or retained; verified rights handling is documented and tested; release checks reject an incomplete deployment privacy profile.

- [ ] Task 11 — Complete security and observability review.
  - Purpose: Diagnose failure without leaking secrets or leaving partial state.
  - Owned surfaces: Cross-cutting structured diagnostics and internal correlation; log, client-payload, and browser-network redaction and allowlists; local-only optional browser assets; strict Content-Security-Policy compatible with the device-local pre-paint theme script; review of task-specific credential isolation, authorization, rollback, and failure controls without taking their implementation ownership.
  - Owns: none (cross-cutting security and observability review; owns no acceptance criteria or data entities).
  - Proof: Security tests, browser network review, and structured-log review show no credential, repository name, project name, URL, request-body, external asset, or analytics exposure and sufficient account-neutral diagnostics for every failure path.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Entry routing, authentication, workspace, repository-access grant, repository catalog, storage selection, project-linking, naming, post-creation dashboard routing, and connection-state tests pass.
- [ ] Deterministic GitHub provider-contract tests pass in normal CI, and the tagged live GitHub App smoke test passes in the secret-backed staging environment.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [ ] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass.
- [ ] Required desktop and mobile browser scenarios pass.
- [ ] Light and dark theme, operating-system fallback, device-local preference, no-sync, keyboard-only, focus, contrast, non-color status, responsive text-fit, and layout-stability checks pass.
- [ ] PKCE, return validation, credential encryption and refresh, session rotation and expiry, provider revalidation, no-webhook behavior, and secret-isolation checks pass.
- [ ] Hosted storage transaction, device readiness-receipt contract, idempotency, rollback, abort, concurrency, and no-partial-project checks pass.
- [ ] The approved development data contract, retention cleanup, verified rights workflow, no-analytics proof, and deployment-privacy release-blocking checks pass.
- [ ] Browser network and failure-log review proves that credentials, personal display values, external optional assets, and product analytics are absent.
- [ ] New decisions and invalidated proof are written back.

## Blocked Decisions

- None.

## Progress Log

### 2026-07-23 - Specification split checkpoint

- Completed: Narrowed the original project-onboarding specification to the GitHub sign-in, repository discovery, project creation, naming, and disconnected-state slice.
- Remaining: Resolve the listed architecture, integration, storage, privacy, and verification decisions before approval.
- Failed checks: None; implementation has not started.
- Spec updates: Moved local onboarding, hosted passwordless access, identity linking, storage lifecycle, and portability into separate ordered specifications without changing accepted behavior.

### 2026-07-23 - Technical design checkpoint

- Completed: Selected the Phoenix application foundation, GitHub App authorization and installation contract, protected session and credential boundaries, stable repository identity, storage adapter, Unicode name comparison, provider-neutral deployment, and canonical verification toolchain.
- Remaining at this checkpoint: Approve the Slice 01 privacy contract; resolved by the 2026-07-24 checkpoint below.
- Failed checks: None; implementation has not started.
- Spec updates: Removed the resolved engineering questions and identified the then-remaining privacy and legal blocker.

### 2026-07-24 - Privacy contract approval

- Completed: Approved the development-time controller, purposes, lawful bases, data minimization, retention, access, rights, processor role, no-analytics, and cleanup contract.
- Remaining: No active-slice decision blocks implementation. Each public hosted deployment must still complete its deployment-specific privacy release gate.
- Failed checks: None; implementation has not started.
- Spec updates: Separated stable implementation requirements from controller contact, vendor, region, transfer, notice, incident, and final-review evidence that depends on the production deployment.

### 2026-07-24 - Application skeleton bootstrap complete

- Completed: Bootstrapped the single Phoenix application at the repository root and established every canonical development check. Task 1 is done.
- Toolchain (pinned in `mise.toml`): Erlang/OTP 29.0.3, Elixir 1.20.2-otp-29, Node 22.13.1. Phoenix 1.8.9, Phoenix LiveView 1.2.7, Ecto SQL 3.14.0, Bandit 1.12.0 (locked in `mix.lock`).
- Passing proofs: `mise install`; `docker compose up -d postgres` (Postgres 17, healthy); `mix setup`; `mix check` (format-check, compile `--warnings-as-errors`, `credo --strict`, `mix test` = 5 passed) as the standard alias; `mix dialyzer` (0 errors); `mix deps.audit` (no vulnerabilities); `mix sobelow --config`; `npm --prefix assets ci`; `npm --prefix assets run test:e2e` (Playwright/Chromium smoke = 1 passed); `MIX_ENV=prod mix assets.deploy`; `MIX_ENV=prod mix release`.
- Failed checks: None. Secrets remain runtime-only; none committed.
- Deferred: Content-Security-Policy is intentionally not yet enforced. Sobelow's `Config.CSP` is the only ignored check (`.sobelow-conf`, documented). A correct strict CSP needs a nonce/hash for the device-local pre-paint inline theme script, so it is owned by the theme interface and the "Complete security and observability review" task, not the skeleton.
- Local engineering decisions (implementation mechanisms, non-behavioral): the dev/test Postgres publishes host port `5433` (localhost-only) to avoid clashing with an existing local Postgres on 5432; `mix assets.deploy` compiles first so Phoenix 1.8 colocated CSS/JS is generated before Tailwind/esbuild; `mix check` runs under `MIX_ENV=test`; `Credo.Check.Design.AliasUsage` is disabled for Phoenix-generated code.
- Note: Only the skeleton task is complete. The remaining slice tasks are not started; the slice is not `Verified`.

### 2026-07-24 - Frontend delivery plan correction

- Completed: Replaced the incomplete task decomposition with an early shared presentation task followed by explicit vertical frontend workflows for entry and authentication, project catalog, repository access and selection, storage choice, confirmation and creation, project dashboard, and connection recovery.
- Remaining: Tasks 2 through 11 are not started. Every frontend surface must be implemented and pass its attached LiveView and browser proof before its owning task can complete.
- Failed checks: None. Task 1 proof remains valid; no implementation proof was removed or invalidated.
- Spec updates: Requirements and technical design are unchanged. The active-slice task plan now assigns each frontend and supporting surface one primary owner and keeps the final browser task limited to integration and verification.

### 2026-07-24 - Frontend plan review checkpoint

- Verdict: Independent second-pass review of the added frontend task decomposition (Task 2 shared presentation foundation, Tasks 3-9 vertical frontend workflows, Tasks 10-11 GDPR and security). The plan is coherent and trustworthy to start implementing: every Slice 01 acceptance criterion and frontend business rule maps to exactly one owning task, scope stays inside the active-slice boundary, and the delivery-ownership contract (one primary owner per surface, Task 9 integration-only) holds. No implementation exists for Tasks 2-11, so there was no task proof to re-run for them.
- Re-run evidence: `python3 .agents/scripts/validate_spec.py specs/01-github-project-onboarding` passed. Task 1's bootstrap proof was not re-run in this review (out of the requested frontend-plan scope); it remains claimed-complete per the 2026-07-24 bootstrap entry.
- Findings (plan-clarity; route to `update-spec`; no implementation defects, no code change):
  - Major - `ProjectOnboardingAttempt` lifecycle has no single explicit owner. Its creation (at `Add project` and empty-workspace continuation), persistence of the selected repository into it, and idempotency-key generation fall in a seam between Task 4 ("new onboarding-attempt handoff"), Task 5 (repository selection), Task 6 ("storage-selection state and persistence"), and Task 7 ("consumes the existing attempt"). The delivery-ownership section promises one owner per behavior; assign the attempt's schema/migration, repository-metadata persistence, and idempotency-key creation to one task before those tasks start.
  - Minor - Repository-picker row metadata display (owner, name, visibility, organization; requirements business rule) is not explicit in Task 5's proof, although keyboard selection and personal/private/organization categories are.
  - Minor - The `ProjectStorage` behaviour is split across tasks (`availability/2` in Task 6; `prepare/3`, `abort/2`, hosted adapter in Task 7). Name a single owner for the shared behaviour/contract module to avoid a seam.
  - Minor - Task 2's pre-paint inline theme script and Task 11's strict CSP must coordinate a nonce or hash so the script is not blocked (already noted in the Task 1 CSP deferral).
  - Nit - Accessibility proof (keyboard, focus, non-color, contrast) is concentrated in Tasks 2, 5, and 9; Tasks 3, 4, 6, 7, 8 do not each restate it.
- Route: The refinements are agreement-clarity items owned by `update-spec`; none require application code. No task checkbox or slice status was changed by this review.
- Blockers: None.

### 2026-07-24 - Traceability coverage adoption

- Completed: Adopted the machine-checkable coverage convention on this slice. Tagged all 43 acceptance criteria with stable `[AC-01]`-`[AC-43]` IDs and added an `Owns:` line to every task naming the criteria and `## Data and Access Boundaries` entities it primarily owns. `validate_spec.py` now enforces that each acceptance criterion has exactly one owning task and each of the 14 data entities at least one; the slice passes.
- Resolved: The `ProjectOnboardingAttempt` ownership gap raised in the review checkpoint. Task 4 now owns the attempt's schema, creation, initial state, and idempotency key; Task 5 writes the selected repository metadata, Task 6 the storage and device-setup return state, and Task 7 consumes it. Reassign if a different owner is preferred.
- Remaining: The Minor review items (repository-picker row metadata in Task 5's proof, a single owner for the shared `ProjectStorage` behaviour module, Task 2 and Task 11 CSP nonce coordination) are unchanged and still route to `update-spec` if pursued. Tasks 2-11 remain not started.
- Failed checks: None. `python3 .agents/scripts/validate_spec.py specs/01-github-project-onboarding` passes with coverage enforced.
- Spec updates: Acceptance criteria carry stable IDs and task ownership is now explicit and validator-enforced; no acceptance-criterion wording, scope, or design decision changed. The convention is wired into the `add-spec` and `update-spec` Delivery Coverage Gates and templates so later specs adopt it when created or next edited.

### 2026-07-24 - Shared presentation foundation complete (Task 2)

- Completed: Delivered the shared LiveView presentation foundation. Replaced the generator's daisyUI Phoenix/Elixir themes with the approved graphite/teal token system (light and dark) mapped into Tailwind v4; self-hosted `Public Sans` (400/500/600/700 + 400 italic woff2) with no Google Fonts request; a locally bundled Lucide icon component (`SddOrchestratorWeb.Icons.lucide/1`); a device-local, pre-paint theme with OS-preference fallback and a delegated toggle handler that never contacts the server; and the reusable primitives in `SddOrchestratorWeb.UI` (app shell, button, badge/status, notice, spinner, skeleton, empty/failure states, single-select radio row, text field) with keyboard-visible focus and non-color status cues. A dev/test-only design-system preview at `/_ui` is the render surface for the proofs.
- Owns satisfied: AC-03, AC-04, AC-05, AC-06 (mechanism), AC-07 (mechanism), entity:ClientThemePreference (browser `localStorage` only; no server record).
- Passing proofs: `mix check` (format, `compile --warnings-as-errors`, `credo --strict`, `mix test` = 17 passed); `mix dialyzer` (0 errors); `mix deps.audit` (no vulnerabilities); `mix sobelow --config`; `npm --prefix assets run test:e2e` (10 Playwright tests incl. axe light/dark, no external font/icon/analytics request, self-hosted Public Sans, OS fallback, device-local persistence across reload, keyboard focus visibility, non-color status cues, mobile+desktop layout fit); `MIX_ENV=prod mix assets.deploy` (fonts digested) and `MIX_ENV=prod mix release`.
- Failed checks: None.
- Deferred/coordination: AC-07's cross-sign-in browser assertion and AC-06's true cross-device check are inherently end-to-end; the mechanism is device-local and server-independent now, and the sign-in/out theme-continuity scenario is verified by Task 9 once the auth surface exists. Task 11 must add the strict CSP nonce/hash for the pre-paint inline theme script (already recorded as the Task 1 CSP deferral). Removed the unused `daisyui` dependency; added `@axe-core/playwright` for the accessibility proof.
- Local engineering decisions (non-behavioral): design tokens are defined as CSS custom properties that switch on `:root[data-theme=dark]` and are exposed to Tailwind via `@theme inline`; the theme toggle is a delegated `document` click listener (not a LiveView hook) so it works before the socket connects and stays device-local; the `/_ui` preview route is compile-guarded by `config :sdd_orchestrator, :ui_preview` (dev + test only).

### 2026-07-24 - Entry, GitHub authentication, and protected session complete (Task 3)

- Completed: Delivered the unauthenticated two-action entry (`Login with GitHub` + `Work without GitHub`, with cancelled/failed recovery and retry), the GitHub App user OAuth flow (random `state` + PKCE `S256`, one-time single-use consumption bound to a browser-flow nonce, code exchange, stable-identity resolution), account/identity/encrypted-credential provisioning and restoration, opaque digest-only application sessions (24h idle / 30d absolute, sliding idle, rotation on sign-in, revocation on sign-out), protected-route resolution that fails closed, and sign-out back to the entry. The local action hands off to a placeholder owned by `specs/02`.
- Owns satisfied: AC-01, AC-09, AC-10; entity:Account, entity:GitHubIdentity, entity:GitHubAuthorizationAttempt, entity:GitHubCredential, entity:ApplicationSession.
- Architecture: new `Accounts` context (5 schemas + migration), `GitHubIntegration` context with a `Provider` behaviour (real `Req` adapter + deterministic test fake), `SddOrchestrator.Vault` (Cloak AES-256-GCM) with `Encrypted.Binary` for tokens and PKCE verifiers, `SddOrchestratorWeb.UserAuth` plug + `on_mount` hooks, `AuthController`, and `EntryLive`/`ProjectsLive`/`LocalOnboardingLive`. `/` now routes to `EntryLive` (the old page controller was removed).
- Passing proofs: `mix check` (format, `compile --warnings-as-errors`, `credo --strict`, `mix test` = 48 passed) covering domain/persistence/session/security, provider-contract (`Req.Test`), controller integration (full sign-in, cancel, failure, replay, sign-out), and LiveView (two-action entry, recovery states, valid-session bypass, protected fail-closed, no token in payload); `mix dialyzer` (0, 1 documented Ecto.Multi/MapSet opaqueness skip); `mix deps.audit`; `mix sobelow --config`; `npm --prefix assets run test:e2e` (18 tests incl. entry two-action surface, recovery states, local handoff, protected redirect, axe light/dark); `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release`.
- Failed checks: None.
- Environment-blocked (not an implementation defect): the tagged live GitHub App smoke test (real OAuth round trip) needs a secret-backed GitHub App; ordinary CI uses the deterministic fake. It runs in the secret-backed staging environment per the release gate.
- Seam handoffs: `PersonalWorkspace` restoration and the real project catalog (AC-08/AC-11+) are Task 4; the `Metadata: read-only` scope assertion (AC-12) is Task 5. `ProjectsLive` is a Task 3 placeholder the catalog task replaces. Theme continuity across sign-in/out (AC-07) is unaffected because the theme lives only in device `localStorage`; its end-to-end browser assertion remains Task 9.
- Local engineering decisions (non-behavioral): the opaque session token lives in the signed `HttpOnly`, `SameSite=Lax` Plug session cookie (server stores only its SHA-256 digest); the OAuth browser-flow nonce is carried in the same session; `state`/token digests use SHA-256 hex; the dev vault key is checked in for local development only (prod supplies `CLOAK_KEY` at runtime); `ReqProvider` accepts injected `req_options` so `Req.Test` can exercise its request/response contract; a narrow `.dialyzer_ignore.exs` suppresses only the known Ecto.Multi opaqueness false positive; the entry CTA buttons are full-width on mobile and the shared `lg` button was enlarged with `whitespace-nowrap` so labels never wrap.

### 2026-07-25 - Personal-workspace restoration and project catalog complete (Task 4)

- Completed: Delivered the protected project catalog and its post-authentication routing. `Accounts.get_or_create_personal_workspace/1` restores the account's one stable workspace (race-safe via the unique `account_id` index plus `on_conflict: :nothing`). The rewritten `ProjectsLive` routes a restored non-empty workspace to its catalog with a non-mutating `Add project` control, and continues an empty workspace straight to the repository-access check without another action. The new `Projects` context owns the workspace-scoped catalog read model (`list_catalog/1`, `has_projects?/1`) and the onboarding-attempt lifecycle (`start_onboarding_attempt/1`, `get_or_start_onboarding_attempt/1`, workspace-scoped `get_onboarding_attempt/2`). Both onboarding entry points (`Add project` and the empty-workspace continuation) open or reuse one active `ProjectOnboardingAttempt` and hand off to the repository-access check; neither creates a project or repository connection.
- Owns satisfied: AC-08 (valid-session restore + catalog), AC-11 (stable workspace created/restored without exposing credentials), AC-13 (non-empty workspace → catalog with `Add project`), AC-14 (empty workspace → repository-access check without another action), AC-15 (`Add project` → repository-access check with no project/connection created); entity:PersonalWorkspace, entity:ProjectOnboardingAttempt.
- Architecture: new `PersonalWorkspace` schema and workspace get-or-create added to the `Accounts` context (one-to-one with `Account`, `has_one :personal_workspace`); new `Projects` context with a minimal `Project` read-model schema and the `ProjectOnboardingAttempt` schema; one migration adding `personal_workspaces`, `projects`, and `project_onboarding_attempts`; a `RepositoryAccessLive` placeholder at `/onboarding/repository-access/:attempt_id` inside the `:authenticated` live_session.
- Seam decision (product owner, 2026-07-25): the catalog reads projects through a minimal `Project` table introduced by this task (id, workspace_id, name, timestamps) so AC-13 and "visible catalog projects" are fully proven now. The project-confirmation task (Task 7) extends this table with the canonical name key and workspace uniqueness, storage mode, lifecycle state, and repository connection, and owns the atomic registration transaction; `entity:Project` ownership stays declared on Task 7 (declaration-based coverage, validator unaffected).
- Onboarding-attempt lifecycle (non-behavioral mechanism): `get_or_start_onboarding_attempt/1` reuses the workspace's active (unconsumed, unexpired) attempt so entry is idempotent under reconnects and repeated navigation and a workspace never accumulates parallel live attempts; a new attempt is started once the active one is consumed (Task 7) or expires. Attempt fields for the selected repository (Task 5), storage mode and device-setup return state (Task 6), and consumption (Task 7) are created now as nullable columns and filled by those tasks.
- Empty-state interpretation: AC-14 makes an empty workspace continue to the repository-access check rather than render an empty catalog page, so the catalog is only shown for a non-empty workspace; the shared `empty_state/1` primitive remains available for later reuse. Flag to `update-spec` if a literal empty catalog page is wanted instead.
- Passing proofs: `mix check` (format, `compile --warnings-as-errors`, `credo --strict`, `mix test` = 73 passed) covering workspace get-or-create (stable restore, idempotent retry, unique-constraint duplicate rejection, cross-account isolation), the catalog read model (workspace-scoped listing and `has_projects?`), the attempt lifecycle (initial state, distinct idempotency keys, active reuse, no reuse after consumption/expiry, workspace-scoped and malformed-id lookup), and LiveView routing (restored non-empty catalog with visible projects and no token in the payload, empty-workspace continuation opening exactly one attempt and no project, `Add project` handoff, and repository-access placeholder scoping and auth requirement); `mix dialyzer` (0, 1 documented skip); `mix deps.audit` (no vulnerabilities); `mix sobelow --config` (exit 0); `npm --prefix assets run test:e2e` (19 tests incl. the new repository-access protected-route check); `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release`.
- Failed checks: None.
- Carried to Task 9 (integration): the authenticated end-to-end browser scenarios for the catalog, `Add project`, and empty-workspace continuation need a live GitHub-backed session, which is environment-blocked locally (same constraint Task 3 recorded); Playwright covers the protected-route redirects and Task 9 orchestrates the authenticated flow once the full onboarding chain exists.
- Seam handoffs: Task 5 replaces the `RepositoryAccessLive` placeholder with the grant screen and repository picker and writes the selected repository into the attempt via the Task 4 context; Task 6 writes storage-selection and device-setup return state; Task 7 consumes the attempt inside the registration transaction and extends the `projects` table; Task 8 adds per-row connection-state indicators to the catalog. No auth-controller change was needed: workspace restoration is lazy and idempotent at the catalog, so the existing `/projects` redirect from the callback is unchanged.
- Local engineering decisions (non-behavioral): the routing decision lives in `ProjectsLive.mount/3` (empty → `push_navigate` to the repository-access check, non-empty → catalog), so it applies to both a fresh sign-in redirect and direct navigation; the onboarding attempt is carried by id in the repository-access path so the picker task receives a validated, workspace-scoped input; abandoned attempts expire after 24 hours (matching the approved privacy contract) and the `expires_at` index supports the retention pruner; catalog rows show only the project name for now because per-row connection status is owned by Task 8.
