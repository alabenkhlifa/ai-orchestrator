# GitHub Project Onboarding Design

## Context

SDD Orchestrator has no application runtime yet. This slice establishes the first production application boundary as a single Elixir/Phoenix service with a Phoenix LiveView web interface and PostgreSQL persistence.

This specification owns only the first GitHub-backed project-registration path. Local repositories, passwordless access, identity linking, storage lifecycle, and portability have separate specifications.

OpenAI Symphony remains the orchestration foundation for later coding-agent work. Its language-independent specification is an architectural reference, while its experimental Elixir prototype is not imported as product code. Onboarding owns durable product and identity state; future agent execution must connect through a separate supervised orchestration boundary.

## Proposed Approach

1. Resolve the current protected session before rendering the shared entry surface.
2. Route a valid GitHub-backed session directly to the restored personal workspace and project catalog.
3. Present the shared two-action entry surface only when no valid protected session exists.
4. Authenticate the GitHub user and establish a protected application session.
5. Create or restore one personal workspace for the stable GitHub identity.
6. Route a restored non-empty workspace to its project catalog and expose an explicit `Add project` action.
7. Route an empty workspace, or an explicit `Add project` action, through a repository-access check.
8. When no accessible `Orchestra-workflow` installation exists, show a dedicated grant screen and hand the user to GitHub through `Continue to GitHub`.
9. Represent an organization installation request awaiting approval on the grant screen and let the user recheck without treating the request as access.
10. Validate the returning or refreshed grant against the authenticated user and continue directly to repository selection.
11. Retrieve every repository available under the granted GitHub access and expose searchable loading, empty, and failure states.
12. Accept one explicit repository selection and continue to the shared storage-selection step.
13. If on-device storage requires setup, preserve the selected repository and onboarding state while guiding the user through device setup, then return to the same storage step without selecting a mode.
14. Explain the device and hosted storage consequences and require one explicit choice before final confirmation.
15. Derive and validate the project display name under workspace-scoped rules.
16. Confirm the repository, project name, and storage choice.
17. Create the project, canonical repository connection, and selected storage mode in one transaction.
18. Open the new project's dashboard and show its repository, storage mode, and connection state without modifying the repository or starting an agent.

Implement the flow with server-rendered LiveViews and explicit domain contexts. A dedicated GitHub provider adapter owns OAuth, GitHub App authentication, installation checks, repository pagination, token refresh, and provider error translation. A storage adapter owns availability and idempotent preparation so hosted initialization can commit in the database transaction and on-device initialization can be supplied by `specs/02-local-project-onboarding/` without coupling project registration to a worker implementation.

## Components Affected

- Elixir/Phoenix application runtime, release configuration, and PostgreSQL persistence.
- Phoenix LiveView entry, GitHub sign-in, session restoration, sign-out, project-catalog, onboarding, and new-project dashboard surfaces.
- Shared onboarding theme tokens, typography, responsive behavior, and accessible interaction states.
- `Accounts` context for GitHub identities, personal workspaces, credentials, and application sessions.
- `GitHubIntegration` context for OAuth, GitHub App authentication, installation access, repository discovery, and provider status.
- `Projects` context for project registration, repository connections, naming, catalogs, and connection state.
- `ProjectStorage` boundary for shared storage selection, availability, preparation, and atomic hosted initialization from `specs/05-project-storage-lifecycle/`.
- Credential storage, audit, diagnostics, and privacy controls.
- ExUnit, Ecto sandbox, provider-contract, LiveView, security, accessibility, and browser verification.
- OCI image and Phoenix release for deployment with an external PostgreSQL service.

## Data and Access Boundaries

Use UUIDs for internal identities and keep provider identifiers and display values separate:

- `Account`: the internal authenticated subject and lifecycle state.
- `GitHubIdentity`: the unique GitHub numeric user ID, current login, and optional avatar URL. Email is neither requested nor stored by this slice.
- `PersonalWorkspace`: the one-to-one account ownership boundary for projects and repository connections.
- `GitHubAuthorizationAttempt`: a short-lived single-use state digest, browser-flow nonce digest, encrypted PKCE verifier, intended return route, expiry, and consumption time.
- `GitHubCredential`: encrypted user access and refresh tokens, provider expiry, granted permissions, and refresh state.
- `ApplicationSession`: a digest of an opaque browser token, account, idle expiry, absolute expiry, last-used time, and revocation time.
- `ProjectOnboardingAttempt`: short-lived server-side workflow state, selected repository metadata, selected storage mode, device-setup return state, and one idempotency key.
- `Project`: the stable SDD Orchestrator project identity, editable display name, canonical comparison key, workspace, storage mode, and lifecycle state.
- `RepositoryConnection`: provider `github`, stable GitHub numeric repository ID, mutable owner/name/URL/visibility metadata, installation scope, last validation time, and connected or disconnected state.
- `HostedProjectStorage`: the hosted root initialized in the same database transaction as its project.
- `DeviceStorageReceipt`: an opaque, expiring readiness receipt supplied by the local-device boundary; it does not grant repository or control-plane access.
- `ClientThemePreference`: an optional current-device light or dark choice held only in browser-local storage and never represented by a server record.
- `DataProcessingRecord`: the approved specification-level purpose, lawful basis, fields, access, lifecycle, rights behavior, processors, transfers, and review for each processing activity.
- `DeploymentPrivacyProfile`: release evidence identifying the hosted deployment's controller contact, processors, regions, transfer safeguards, privacy notice, incident path, and completed reviews; it is deployment configuration and governance evidence, not project data.

Required boundaries:

- Every project and repository connection belongs to one personal workspace.
- Project names are enforced by a unique `(workspace_id, name_key)` database constraint.
- Repository connections are enforced by a unique `(workspace_id, provider, provider_repository_id)` database constraint. Repository owner, name, URL, and installation ID are mutable access and display metadata, not identity.
- Project identity is independent from its display name and repository display metadata.
- Repository location and content remain independent from the selected project-data storage mode.
- GitHub access tokens, refresh tokens, PKCE verifiers, client secrets, private keys, and application-session digests remain in the protected server boundary. Encrypted database fields use authenticated encryption with runtime-supplied keys and planned key rotation.
- The browser receives only an opaque `HttpOnly`, `SameSite=Lax` application-session cookie plus authorized presentation data for the active workspace. The cookie is `Secure` outside local development, and JavaScript cannot read provider or session credentials.
- Coding agents and future workers never receive GitHub user credentials, application-session credentials, or the GitHub App private key.
- Repository catalogs are fetched on demand and are not persisted. Only metadata for the repository confirmed by the user is retained.
- Repository content is outside the onboarding write boundary.
- Lost provider access changes connection state without deleting project state.
- Manual theme preference remains inside the current client storage boundary and is not sent to the control plane, identity provider, analytics, or other devices.
- Product analytics is disabled for this slice. Operational and security events use internal correlation IDs, outcome classes, and minimum necessary timestamps; they exclude credentials, repository names, project names, URLs, and request bodies.
- Every personal-data field and processing path must have an approved GDPR data contract before implementation.

## Interfaces

- Web interface: Phoenix router and LiveViews expose the entry, project catalog, grant, repository picker, storage, confirmation, and project dashboard surfaces. Protected `on_mount` hooks resolve the server-side application session before protected content renders.
- GitHub authorization interface: `/auth/github` creates a ten-minute authorization attempt, binds it to an opaque browser-flow cookie, and redirects with random `state` plus PKCE `S256`; `/auth/github/callback` consumes the state once, verifies the same browser flow, exchanges the code, resolves the stable GitHub user, creates or restores the workspace, rotates the application session, and rejects expired, replayed, mismatched, canceled, or failed returns.
- Session interface: issue an opaque browser token whose digest is stored server-side, rotate it at authentication, expire it after 24 hours of inactivity or 30 days absolutely, revoke it on sign-out, and reject it before protected data is loaded. Provider-token refresh does not expose or replace the browser token.
- Theme interface: an early local script reads the current device preference before first paint, falls back to `prefers-color-scheme`, applies the selected token set, and never sends the value to LiveView.
- GitHub provider interface: a behaviour implemented with `Req` owns user authorization, identity retrieval, access-token refresh, accessible-installation discovery, repository pagination, pending-installation requests, and normalized provider errors. Requests use `Accept: application/vnd.github+json` and the pinned GitHub API version `2026-03-10`. Deterministic fakes implement the same behaviour in ordinary tests.
- GitHub App interface: generate short-lived `RS256` app JWTs from the runtime private key only for app-authenticated operations such as pending installation requests. Backdate `iat` by 60 seconds for clock drift, keep `exp` under ten minutes, and use the configured client ID as `iss`. The installation return and any `installation_id` are hints until access is re-read with the authenticated user's token and matched to the active onboarding attempt.
- Repository-access grant interface: use the registered `Orchestra-workflow` installation URL with a random one-time state value, represent a matched pending organization request with `Waiting for organization approval`, and re-run the same access check for the return and `Check again`.
- Repository catalog interface: use the authenticated user's GitHub App user access token to paginate `/user/installations` and each accessible installation's repositories, deduplicate by numeric repository ID, then search the complete in-memory result without persisting the catalog.
- Project-catalog interface: load projects only inside the restored workspace, include disconnected entries, and expose a non-mutating `Add project` transition into a new `ProjectOnboardingAttempt`.
- Storage-selection interface: reuse the behavior from `specs/05-project-storage-lifecycle/` and call a `ProjectStorage` adapter with `availability/2`, `prepare/3`, and `abort/2`. Hosted preparation joins the project `Ecto.Multi`; device preparation accepts only a valid readiness receipt supplied by `specs/02-local-project-onboarding/`. A failed database transaction aborts prepared storage, and retries use the onboarding idempotency key.
- Project registration interface: an `Ecto.Multi` locks the workspace naming boundary, validates the confirmed repository and storage preparation, inserts the project, repository connection, storage state, and consumed onboarding attempt, then returns the new project only after commit. A unique-conflict retry either returns the existing repository project or allocates the next default-name suffix.
- Project naming interface: trim boundary whitespace, reject blank or control-character input, preserve the accepted display text, and derive `name_key` with Unicode `NFKC` normalization followed by Unicode default case folding. Default-name allocation retries the lowest available suffix after a unique violation; an edited-name conflict returns inline validation instead of silently changing the user's value.
- Connection-status interface: revalidate access when the catalog or dashboard loads and when the user selects `Check again`. A missing installation, authorization failure, or failed refresh marks the connection disconnected without deleting the project; a transient provider outage shows an unavailable state without changing the last confirmed connection state.
- Post-creation navigation interface: redirect to the new project dashboard only after the registration transaction commits; a failure keeps the resumable onboarding attempt and exposes no partial project.
- Privacy-governance interface: enforce the approved development data contract in schema, services, logs, tests, and cleanup. Separately block public hosted release until the deployment privacy profile is complete.

## Decisions and Tradeoffs

### Two Entry Actions

- Choice: Present `Login with GitHub` and `Work without GitHub` as distinct primary actions.
- Reason: Repository location and GitHub account ownership are separate user choices.
- Consequence: The GitHub and local paths remain separate implementation slices, but the first usable release waits for both specified paths and their shared dependencies to pass. Neither primary action may be disabled, hidden, presented as a placeholder, or lead to an incomplete flow.

### Session-Aware Entry Routing

- Choice: Treat the two-action entry surface as the unauthenticated chooser, bypass it for a valid GitHub-backed application session, and return to it after sign-out or invalid session resolution.
- Reason: Returning users should resume their workspace without repeating provider authentication, while unauthenticated clients must not receive protected catalog data.
- Consequence: Session validation must complete before protected routing, invalid or revoked sessions must fail closed, and sign-out must preserve on-device project data while removing hosted access.

### Existing Workspace Before New Project

- Choice: Route a freshly authenticated non-empty workspace to its project catalog with an explicit `Add project` action, while an empty workspace continues directly to repository selection.
- Reason: Returning users should resume existing work instead of being forced through new-project onboarding, while a first-time user should reach the next required action without an empty intermediate page.
- Consequence: Workspace restoration must determine whether projects exist before routing, and `Add project` must be a non-mutating transition into the same repository-selection flow.

### Project Catalog Read Model Before Registration

- Choice: Introduce the stable base `Project` schema and catalog read model with project ID, workspace ID, display name, and timestamps in Task 4. Extend that same schema additively in Task 7 with the canonical name comparison key, workspace uniqueness, storage mode, lifecycle state, repository connection, and atomic registration behavior.
- Reason: Task 4 must prove the approved non-empty project catalog before Task 7 implements new-project registration.
- Consequence: Tasks 4 and 7 share `entity:Project` ownership at different delivery boundaries. Task 7 must extend the Task 4 schema without replacing its identity or invalidating existing catalog records.

### Open The New Project After Creation

- Choice: Open the newly created project's dashboard immediately after onboarding succeeds.
- Reason: The user should arrive at the project they just created instead of navigating back through the catalog.
- Consequence: The destination dashboard must show the linked repository, selected storage mode, and current connection status. Navigation occurs only after atomic creation commits; a failure remains in onboarding.

### Prototype As A Design Reference

- Choice: Preserve the generated prototype under `design-references/01-github-project-onboarding/claude-design/` as a visual and interaction reference only; do not import its generated design-canvas runtime, `support.js`, inline implementation, mock state controls, or sample data into the application.
- Reason: The prototype provides a useful UX direction, but its runtime and shortcuts are not production decisions.
- Consequence: Implementation must recreate approved patterns in the selected application stack and prove them through the canonical browser checks. The original ZIP remains ignored and untracked; the exported reference is review evidence, not a project source of truth.

### Graphite And Teal Dual Theme

- Choice: Use `Public Sans` with a system sans-serif fallback and a graphite-neutral, teal-primary visual system with light and dark modes.
- Reason: The combination keeps operational information readable and gives primary actions a distinct identity without using a one-color dashboard.
- Consequence: Self-host the approved `Public Sans` files as versioned application assets instead of copying the prototype's Google Fonts request. Theme preference is device-local and never synchronized to the hosted identity.

Core light tokens:

- Canvas `#F6F7F8`, surface `#FFFFFF`, raised surface `#EEF1F2`.
- Primary text `#182022`, secondary text `#566166`, subtle border `#D7DDDF`, control border `#7A878C`.
- Primary teal `#006D77`, on-primary `#FFFFFF`, primary tint `#D8F3F2`, focus `#0B6FDB`.

Core dark tokens:

- Canvas `#101415`, surface `#181D1F`, raised surface `#22282A`.
- Primary text `#F2F5F4`, secondary text `#AAB5B2`, subtle border `#343C3F`, control border `#6F7D80`.
- Primary teal `#55D6D2`, on-primary `#082021`, primary tint `#143638`, focus `#75B8FF`.

Semantic tokens:

- Connected: light `#1F7A4C` on `#E8F5ED`; dark `#66D28F` on `#153524`.
- Information: light `#1769AA` on `#EAF3FB`; dark `#78B9F2` on `#173149`.
- Blocked or attention: light `#8A5000` on `#FFF2D6`; dark `#FFC266` on `#3B2A12`.
- Failure: light `#B42318` on `#FDECEA`; dark `#FF8A82` on `#421F1D`.

### Device-Local Theme Preference

- Choice: Store a manual light or dark choice only on the current device and use the current operating-system preference when no local choice exists.
- Reason: Theme is a client presentation preference that should work before authentication and does not need hosted identity processing or cross-device synchronization.
- Consequence: Store the explicit value in browser `localStorage`, apply it before first paint, and listen to operating-system changes only while no explicit value exists. Sign-in and sign-out do not read or replace it.

### Compact Stateful Onboarding

- Choice: Use a focused entry surface, compact authentication state, dense single-selection repository list, explicit confirmation, a direct new-project dashboard handoff, and visible disconnected recovery across desktop and mobile.
- Reason: Non-technical and technical users need to scan repository choices and recovery actions without decorative dashboard noise.
- Consequence: Loading skeletons, search no-match, empty catalog, retrieval failure, restricted organization access, naming feedback, connected state, and disconnected state require stable responsive layouts and keyboard proof.

### Complete GitHub Repository Catalog

- Choice: Show every repository returned under the user's granted access and link only the confirmed selection.
- Reason: Non-technical users should not need repository URLs or terminal commands.
- Consequence: Fetch and paginate the complete authorized catalog through the GitHub App user token, deduplicate it by numeric repository ID, search it in memory, and keep retry, rate-limit, empty, and restricted states distinct.

### Registered Public GitHub App

- Choice: Use the registered public GitHub App `Orchestra-workflow` at `https://github.com/apps/orchestra-workflow` for GitHub user authorization and repository installation access.
- Reason: One public app identity gives users a GitHub-hosted authorization and installation surface for personal and organization repositories.
- Consequence: The App uses the repository permission `Metadata: read-only`; no other repository permission or write access is approved for this onboarding scope. Its exact callback is `${APP_ORIGIN}/auth/github/callback`, its setup URL is `${APP_ORIGIN}/github/setup`, OAuth during installation is disabled because sign-in happens first, and webhooks are inactive. App identifiers and secrets are runtime configuration and are never committed. The application revalidates access on use and through `Check again` and treats a pending request as the current user's only when its `requester.id` matches the authenticated GitHub user ID.

### Explicit Repository Access Grant

- Choice: When no accessible `Orchestra-workflow` installation exists, show a dedicated `Grant repository access` screen with `Continue to GitHub`, then open the repository picker directly after a valid grant returns.
- Reason: GitHub authentication and repository installation are distinct, and non-technical users need a clear next action instead of an empty or failed repository picker.
- Consequence: Repository retrieval cannot start until access is verified. A pending organization request remains on the grant screen with `Waiting for organization approval` and `Check again`; canceled, rejected, pending, or invalid access must not create a project or be treated as granted.

### Storage Choice Before Confirmation

- Choice: After repository selection, show the shared `Where should your project work be saved?` step and require an explicit device or hosted choice before final confirmation.
- Reason: Non-technical users need to understand that this choice affects where their project work is available and whether colleagues can collaborate, not the linked repository or agent location.
- Consequence: Final confirmation shows repository, project name, and storage mode. The hosted adapter initializes storage in the registration transaction; the device adapter requires a valid ready receipt before that transaction. Device setup remains owned by `specs/02-local-project-onboarding/`, returns to the same attempt, and never chooses a mode or creates a project implicitly.

### One Project Per Repository

- Choice: Enforce one repository per project and one project per canonical repository inside a personal workspace.
- Reason: Later specifications, runs, workers, and evidence need one unambiguous repository boundary.
- Consequence: Monorepo subprojects and multiple SDD configurations for one repository are deferred.

### Editable Workspace-Scoped Names

- Choice: Default the project name from the repository, allocate the lowest available numeric suffix case-insensitively, and allow later edits.
- Reason: The default minimizes setup while workspace scope permits independent users to organize the same repository differently.
- Consequence: Persistence must enforce concurrency-safe uniqueness while stable identities remain separate from the display name.

### Natural Display Names, Not Slugs

- Choice: Allow spaces and Unicode in project display names and preserve the user's display text instead of forcing lowercase or slug conversion.
- Reason: BA, PO, PM, and international users should be able to name projects in familiar language, while stable project and repository identities already serve machine requirements.
- Consequence: Project names are never used as identifiers, paths, or URLs. A separate `NFKC`-normalized, Unicode-case-folded comparison key and a workspace unique constraint enforce case-insensitive uniqueness without rewriting the stored display value.

### Disconnected Rather Than Deleted

- Choice: Keep a project visible when GitHub access is lost.
- Reason: Authorization and provider availability are recoverable connection states, not project existence.
- Consequence: Access is revalidated at protected repository-dependent reads and on explicit retry. Confirmed authorization loss marks the connection disconnected; transient GitHub failure does not overwrite the last confirmed state, and stale credentials are never passed to a worker or browser.

### Phoenix Application Foundation

- Choice: Bootstrap one Elixir 1.20 and Erlang/OTP 29 application with Phoenix 1.8, Phoenix LiveView 1.2, Ecto SQL 3.14, Bandit, and PostgreSQL. Pin exact patch versions in `mise.toml` and dependency lockfiles when the skeleton is created.
- Reason: The product needs a server-owned realtime workflow, durable transactions, supervised integrations, and later orchestration without requiring a separate frontend application for the first slice.
- Consequence: Keep `Accounts`, `GitHubIntegration`, `Projects`, and `ProjectStorage` as explicit contexts inside one Phoenix application. Do not introduce an umbrella, separate API, background-job system, or client-side state framework until an approved slice needs one.

### LiveView And Local Assets

- Choice: Build the responsive web interface with HEEx function components and LiveView, Tailwind CSS, local `Public Sans` files, and locally bundled Lucide icons.
- Reason: One server-rendered interface keeps authentication and onboarding state inside the protected application boundary while supporting the required interactive states.
- Consequence: JavaScript hooks are limited to device-local theme handling and browser behavior that LiveView cannot provide directly. The application makes no font, icon, analytics, or other optional third-party browser request.

### Symphony Orchestration Boundary

- Choice: Keep the Phoenix application as the product control plane and treat the Symphony specification as the future orchestration contract. Do not import or fork the experimental Symphony prototype in Slice 01.
- Reason: Symphony's prototype demonstrates agent supervision and reconciliation, but onboarding needs durable identity and project state and has no agent-execution responsibility.
- Consequence: Slice 01 adds no Symphony runtime dependency and starts no agent. A later approved slice may place orchestration in a supervised OTP application or separate service behind durable commands and events; it must not read GitHub user tokens or browser sessions.

### GitHub Authorization And Token Lifecycle

- Choice: Implement GitHub App user authorization directly through a narrow `Req` adapter using random state, PKCE `S256`, one exact callback route, and provider-reported token expiries.
- Reason: GitHub App authorization, installation access, refresh, and pending-organization behavior need one explicit provider contract rather than generic social-login assumptions.
- Consequence: Store only a state digest and encrypted PKCE verifier, consume each return once, refresh an expiring user token under a database lock, and retry one provider request after refresh. A failed refresh or confirmed authorization loss revokes the credential and disconnects affected repository connections without deleting projects.

### Installation Validation Without Webhooks

- Choice: Disable GitHub App webhooks for this slice and determine access through authenticated reads on onboarding, catalog/dashboard access, and `Check again`.
- Reason: Slice 01 does not need event-driven repository mutation or background synchronization, and polling only at user-driven boundaries avoids an unnecessary public ingestion surface.
- Consequence: Use a short-lived app JWT only to inspect installation requests. Never trust setup-return parameters by themselves; accept access only after the authenticated user's installations and repositories contain the returned selection. A later feature that needs timely provider events must specify webhook URL ownership, signature verification, replay protection, event retention, and failure recovery before enabling webhooks.

### Protected Credentials And Application Sessions

- Choice: Encrypt GitHub tokens and PKCE verifiers with `Cloak.Ecto` authenticated encryption, sign app JWTs with `Joken`, and use revocable opaque application sessions whose raw token exists only in a protected cookie.
- Reason: Provider credentials need key rotation and must remain isolated from the browser application, logs, local workers, and coding agents.
- Consequence: Supply encryption keys, `SECRET_KEY_BASE`, GitHub client secret, and GitHub private key only through runtime secrets. Session tokens are rotated at sign-in, expire after 24 hours idle or 30 days absolute, and are revoked on sign-out. Token refresh, app-JWT generation, and sensitive fields use redacted structured logging.

### Stable GitHub Repository Identity

- Choice: Use GitHub's numeric repository ID as the provider-stable identity and treat installation ID, owner, name, visibility, and URL as refreshable metadata.
- Reason: Repository names, owners, URLs, and installation scope can change without creating a different repository.
- Consequence: Enforce one `(workspace_id, github, repository_id)` connection, update display metadata after validated reads, and preserve the same project across renames and transfers when the authenticated user still has access.

### Atomic Storage Preparation

- Choice: Make storage readiness an idempotent prerequisite of the project-registration transaction. Hosted storage contributes database operations to the same `Ecto.Multi`; device storage contributes a validated readiness receipt created by the local-device slice.
- Reason: Project registration must not expose a project, repository connection, or storage selection that only partly committed, while device setup is a separate trust and runtime boundary.
- Consequence: The onboarding attempt supplies one idempotency key. A failed transaction aborts prepared storage and remains retryable. Slice 01 implements the hosted adapter and the shared behaviour; `specs/02-local-project-onboarding/` implements device setup and the production device adapter. The coordinated first release remains blocked until both adapters pass the shared contract.

### Unicode Name Comparison

- Choice: Preserve the validated display name and derive a separate comparison key with Unicode `NFKC` normalization followed by Unicode default case folding.
- Reason: Machine uniqueness must not turn human-facing names into slugs or make comparison dependent on database collation defaults.
- Consequence: Enforce the key with a database unique constraint, lock and retry default suffix allocation under concurrency, and maintain representative Unicode and case tests when the runtime or database Unicode version changes.

### No Product Analytics In Slice 01

- Choice: Do not collect product analytics for entry, GitHub authorization, repository discovery, storage selection, or project creation.
- Reason: Analytics is not required to deliver or verify onboarding and would introduce another processing purpose before the product has an approved anonymisation pipeline.
- Consequence: Verification rejects analytics requests, events, identifiers, and metrics. Minimum operational and security logs remain governed personal data and require the privacy approval below.

### Approved Development Privacy Contract

- Choice: Treat the operator of each hosted SDD Orchestrator deployment as controller for the identity, session, selected repository metadata, workspace, project, and operational-security records that deployment receives. GitHub governs its own platform processing; services acting on behalf of the deployment operator are processors where applicable.
- Purpose and basis: Process core records only as necessary to provide the user-requested hosted service. Process minimum security records only for the documented service-security purpose and legitimate-interest assessment. Do not reuse either category for analytics, advertising, model training, or unrelated product improvement.
- Lifecycle: Authorization attempts become unusable after ten minutes and are deleted within 24 hours; abandoned onboarding attempts are deleted after 24 hours; expired or revoked sessions are deleted within 24 hours; and operational-security logs are deleted after 30 days. Keep encrypted provider credentials and confirmed project metadata only while the connected account or project requires them.
- Enforcement: An hourly supervised pruner uses a PostgreSQL advisory lock so cleanup remains idempotent across application instances. Encrypted rolling backups expire within 35 days, and processor deletion follows the deployment's approved contract.
- Access and rights: Restrict data access to the authenticated user and authorized operations roles, exclude coding agents, and support verified access, correction, erasure, restriction, objection, and portability handling for applicable records. The first slice may use an authenticated operator workflow rather than adding self-service rights screens.
- Development consequence: Schema, backend, and local verification may proceed under this contract. Ordinary automated tests use the deterministic GitHub adapter and synthetic data; any live GitHub smoke test uses an access-controlled environment and the operator's authorized test account.

### Deployment Privacy Release Gate

- Choice: Separate deployment-specific legal and vendor evidence from the approved implementation contract.
- Reason: Framework, schema, lifecycle, access, and verification decisions are stable before a production host is selected, while controller contact details, vendors, regions, and transfer mechanisms vary by deployment.
- Consequence: A public hosted deployment cannot release until it records the actual controller identity and contact, processor list and agreements, hosting and backup regions, cross-border safeguards, privacy notice, incident path, retention enforcement, and the outcome of any required DPIA or other privacy or legal review. Missing deployment evidence blocks that release, not implementation or local verification.

### Portable Deployment

- Choice: Package a Phoenix release in an OCI image generated from the Phoenix release tooling, run it with an external PostgreSQL service, and keep deployment provider-neutral.
- Reason: The personal project needs one reproducible artifact that can run locally or in a hosted environment before cloud-specific operations are selected.
- Consequence: Local HTTP uses port `4000`. Runtime configuration includes `APP_ORIGIN`, `PORT`, `DATABASE_URL`, `SECRET_KEY_BASE`, field-encryption keys, `GITHUB_APP_ID`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_SLUG=orchestra-workflow`, and `GITHUB_API_VERSION=2026-03-10`; callback and setup URLs are derived from `APP_ORIGIN`.

### Canonical Verification Toolchain

- Choice: Use ExUnit and Ecto sandbox tests, Mox/Bypass provider-contract tests, Phoenix LiveView tests, Playwright browser tests, and axe accessibility checks.
- Reason: Provider behavior, transaction safety, responsive interaction, and accessibility require different proof layers without making normal CI depend on a live GitHub account.
- Consequence: The application-skeleton task must make these commands canonical:
  - `mise install`
  - `docker compose up -d postgres`
  - `mix setup`
  - `mix phx.server`
  - `mix format --check-formatted`
  - `mix compile --warnings-as-errors`
  - `mix credo --strict`
  - `mix dialyzer`
  - `mix deps.audit`
  - `mix sobelow --config`
  - `mix test`
  - `npm --prefix assets ci`
  - `npm --prefix assets run test:e2e`
  - `MIX_ENV=prod mix assets.deploy`
  - `MIX_ENV=prod mix release`
- Consequence: Add a `mix check` alias for the standard formatting, compilation, lint, and test loop. Normal CI uses the deterministic GitHub adapter; a tagged live GitHub App smoke test runs only in a secret-backed staging environment before release.

## Risks

- GitHub App permission drift could exceed the approved boundary. Assert `Metadata: read-only` in configuration and staging release checks and fail closed when additional permissions are required.
- GitHub return parameters can be replayed or attached to the wrong user. Bind short-lived state to the same browser flow, consume it once, and re-read access before accepting it.
- Repository names, owners, URLs, and installations can change. Keep numeric repository identity separate and refresh display metadata only after an authenticated read.
- Concurrent creation or rename can allocate duplicate names. Enforce database uniqueness and retry default-name suffix allocation inside the registration boundary.
- Unicode behavior can change across runtime or database upgrades. Pin the application comparison algorithm and rerun representative normalization and case tests before upgrading.
- GitHub outages, rate limits, SSO, and organization policy can interrupt onboarding. Preserve consistent state and expose actionable recovery.
- Access changes cannot arrive through webhooks in this slice. Revalidate before repository-dependent work and show the last confirmed state separately from transient provider availability.
- Credentials can leak through browser payloads, logs, or diagnostics. Keep them in encrypted server fields, redact structured events, and test every failure surface.
- Stale, expired, or revoked sessions can expose catalog data or create redirect loops. Resolve session state before protected rendering and test direct navigation, expiry, revocation, and sign-out transitions.
- Device preparation and database registration cross a process boundary. Require idempotent receipts, abort failed preparation, reconcile retries, and keep the first-release gate blocked until the production device adapter proves the shared contract.
- A non-technical user may confuse GitHub authentication with agent-provider authentication. Keep those concepts and statuses separate.
- Prototype behavior can silently become product behavior. Do not adopt its forced lowercase default names, letters-and-numbers-only validation, always-new-project routing, non-functional local-path toast, or prototype-only controls without an accepted specification update.
- An accidental external font, icon, or analytics request would violate the browser-data boundary. Test the network allowlist and serve approved assets locally.
- Theme and responsive variants can drift into different behavior. Test the same actions, state meaning, keyboard order, focus, and text fit across both themes and target viewports.
- Personal data can escape its lifecycle through logs, backups, or processors. Include every copy and transfer in the approved data contract and deletion evidence.
- Framework, dependency, and provider API versions will change. Pin exact versions, keep provider behavior behind one adapter, and review release notes before upgrades.
- The separate GitHub and local implementation slices can drift at their shared entry and dependency boundaries. The coordinated first-release gate must verify both complete paths from the same entry surface.

## Open Questions

- None.
