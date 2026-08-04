# Hosted Passwordless Access Progress Log

### 2026-07-23 - Extracted from project onboarding

- Completed: Approved the hosted-access product requirements, including verified-email access, account-neutral responses, combined catalog behavior, pre-linked recovery, deferred two-proof email change, and persistent independently revocable device sessions.
- Remaining: Resolve token, delivery, abuse, session mechanism, privacy implementation, architecture, and verification decisions.
- Failed checks: None; implementation has not started.
- Spec updates: Product requirements moved from `Draft` to `Approved`; tasks remain `Blocked` at technical design, privacy implementation, and verification readiness.

### 2026-07-27 - Technical design and privacy contract resolved

- Completed: Resolved the magic-link token and consumption mechanism, email delivery adapter, account-neutral abuse controls, persistent session mechanism, pre-linked sign-in seam, application architecture, verification strategy, and the authentication data-protection contract in `design.md`.
- Remaining: Implement the slice on the approved contracts; complete the release-gate delivery-provider, retention-duration, and privacy-review items.
- Failed checks: None; implementation has not started.
- Spec updates: Cleared the technical-design and privacy blockers, replaced `Blocked Decisions` with a `Release Gate`, and moved tasks from `Blocked` to `Not Started`.

### 2026-07-27 - Implementation ownership and sequence approved

- Completed: Classified the slice as focused; approved trimmed case-insensitive email identity with preserved verified spelling; assigned every active acceptance criterion, data entity, delivery surface, and proof to one primary task; made the dependency graph explicit; and marked the already-resolved agreement gate complete.
- Remaining: Implement Tasks 2–7 in order, run the complete verification gate, and complete the production delivery-provider, retention-duration, and final privacy or legal release gates.
- Failed checks: None; implementation has not started.
- Spec updates: Added stable acceptance-criterion and task labels, explicit owned surfaces, traceability, dependencies, deferred-criterion classification, and canonical verification commands without expanding the active behavior.

### 2026-07-27 - Hosted identity and workspace foundation complete (Task 2)

- Completed: Added stable `HostedIdentity` and email `ExternalIdentity` records, a trimmed case-insensitive comparison key with separately preserved verified spelling, atomic account/common-workspace/personal-workspace creation, idempotent restoration, unique destination constraints, and isolated fixtures.
- Architecture: `SddOrchestrator.HostedAccess` is the Slice 03 context boundary; it accepts only successfully verified addresses and keeps request, delivery, token verification, and session lifecycle in later tasks. The new rows attach to the existing `Account` and hosted `Workspace` roots without changing GitHub identity behavior or persisting device-authoritative data.
- Proof: The migration applies, rolls back, and reapplies on the `_slice03` database; focused domain and constraint tests pass (7); `mix check` passes with 234 tests and one tagged live test excluded; specification validation and `git diff --check` pass.
- Parallel coordination: Work remains isolated in the dedicated Slice 03 worktree, with local server port `4003` reserved; no Slice 02 worker, repository, or device-workspace surface was changed.

### 2026-07-27 - Task 3 implementation started

- In progress: Implementing account-neutral magic-link request and resend, protected attempt storage, testable Swoosh delivery, newest-only invalidation, and non-disclosing abuse controls.
- Preflight: Tasks 1 and 2 are complete; Task 3 introduces its own request, persistence, delivery, and limiter prerequisites and has no forward dependency.

### 2026-07-27 - Magic-link request and delivery controls complete (Task 3)

- Completed: Added the `MagicLinkAttempt` lifecycle and constraints; 256-bit raw-token generation with only a per-attempt salted SHA-256 digest persisted; 15-minute expiry; advisory-lock plus database-enforced newest-only invalidation; account-neutral request and resend behavior; Swoosh local/test delivery adapters; redacted failure diagnostics; and process-secret HMAC token buckets for per-email, per-IP, and global send limits.
- Architecture: `SddOrchestrator.HostedAccess.MagicLinks` never queries or creates an identity. It returns the same acknowledgement for invalid, throttled, existing, new, database-failed, and delivery-failed requests. The raw token is passed directly into the delivery-only email and is neither returned nor stored.
- Proof: The Task 3 migration applies, rolls back, and reapplies on the `_slice03` database; 10 focused request, concurrency, delivery, and limiter tests pass; the combined hosted-access suite passes with 17 tests; `mix check` passes with 244 tests and one tagged live test excluded; `mix deps.audit`, specification validation, and `git diff --check` pass.
- Remaining: Task 4 owns atomic attempt verification, single-use consumption, identity restoration, and initial hosted-session creation; production delivery provider and final retention and privacy decisions remain in the release gate.

### 2026-07-27 - Task 4 implementation started

- In progress: Implementing attempt-bound token verification, atomic single-use consumption, transaction-safe identity restoration, initial hosted-session persistence, and a signed-cookie issuance contract.
- Preflight: Tasks 2 and 3 are complete; Task 4 owns the verification and first-session transaction and does not depend on the later authorization, revocation, or LiveView surfaces.

### 2026-07-27 - Atomic verification and initial hosted session complete (Task 4)

- Completed: Added `HostedSession` persistence; constant-time salted-digest verification; UUID and 256-bit token-shape validation; delivered, unexpired, newest, unused attempt enforcement; row locking plus compare-and-set consumption; transaction-safe identity/workspace restoration; coarse device recognition; a signed 30-day hosted-session cookie contract; and the public magic-link return endpoint with `no-store` and `no-referrer` response controls.
- Failure behavior: Invalid identifiers, malformed or mismatched tokens, expiry, invalidation, undelivered attempts, replay, concurrent consumption, and session-persistence failure all return the same safe result. Session-persistence failure proves that identity, workspace, session, and attempt-consumption writes roll back together.
- Proof: The Task 4 migration applies, rolls back, and reapplies on the `_slice03` database; 9 focused verification and return-endpoint tests pass; the combined hosted-access suite passes with 26 tests; `mix check` passes with 253 tests and one tagged live test excluded; specification validation and `git diff --check` pass.
- Remaining: Task 5 owns hosted-session resolution, sliding activity updates, protected authorization, browser restart behavior, current, individual, and all-device revocation, and the pre-linked recovery boundary.

### 2026-07-27 - Task 5 implementation started

- In progress: Implementing hosted-cookie resolution and renewal, protected hosted authorization, independent device-session visibility and revocation, current and all-device sign-out, and the pre-linked sign-in recovery seam.
- Preflight: Tasks 2 and 4 are complete; Task 5 owns the persisted-session lifecycle and authorization boundary and leaves the complete user-facing session-management experience to Task 6.

### 2026-07-27 - Hosted-session lifecycle and recovery seam complete (Task 5)

- Completed: Added hosted-session creation and signed-cookie resolution; a persistent `Secure`, `HttpOnly`, `SameSite=Lax` browser session; 30-day database-enforced absolute expiry; sliding `last_seen_at` activity with browser-cookie renewal; controller and LiveView authorization hooks; active-device listing; current, individual, and all-device deletion; scoped and concurrent revocation; protected revocation routes; and disabled-account denial.
- Recovery boundary: Added a server-only seam that restores the same identity and workspace only from a persisted, verified, non-email `ExternalIdentity` supplied by an upstream authentication boundary. Missing, unpersisted, and email-only methods fail without a support override, and every attempted email replacement is denied pending the deferred two-proof flow.
- Isolation: Hosted authorization remains separate from GitHub application sessions and is not copied into worker or coding-agent capabilities. Tests prove hosted sign-out and revocation leave device-authoritative project ownership and storage mode unchanged.
- Proof: 15 focused lifecycle, authorization, revocation, recovery, immutable-email, and local-boundary tests pass; the combined hosted-access suite passes with 41 tests; `mix check` passes with 268 tests and one tagged live test excluded; specification validation and `git diff --check` pass.
- Remaining: Task 6 owns the complete accessible request, waiting, resend, verification-result, recovery, and active-device LiveView experience plus desktop and mobile browser proof.

### 2026-07-27 - Task 6 implementation started

- In progress: Implementing the hosted-access disclosure, neutral request acknowledgement, waiting and resend flow, safe verification results, current sign-out and device-session management, recovery-boundary copy, accessible interaction states, and desktop/mobile browser proof.
- Preflight: Tasks 3, 4, and 5 are complete; Task 6 consumes their public interfaces and owns presentation and browser behavior without taking combined-catalog ownership.

### 2026-07-27 - Passwordless and session-management experience complete (Task 6)

- Completed: Added the hosted-access entry and recovery disclosure; email request, account-neutral acknowledgement, waiting, resend, and use-another-email states; safe verified and invalid, expired, replayed, or replaced result states; caller-scoped local return paths; active-device visibility; individual, current, and all-device sign-out actions and feedback; and explicit pre-linked recovery and no-support-override copy.
- Accessibility and privacy: Request and result focus moves to the actionable heading or field; all controls are keyboard-operable and carry visible focus; status and failure meaning uses icon plus text; responsive layouts avoid horizontal overflow; submitted email is never echoed after request; active-session UI exposes only coarse browser and OS families and no IP or fingerprint.
- Parallel environment: Browser proof runs on the reserved Slice 03 port `4003` with isolated database `sdd_orchestrator_dev_slice03`; Playwright prebuilds assets before server readiness and covers desktop Chrome plus a Pixel 7 profile.
- Proof: 14 focused LiveView and return-controller tests pass; 58 combined hosted request, verification, session, and UI tests pass; `mix check` passes with 281 tests and one tagged live test excluded; all 56 Playwright scenarios pass across desktop and mobile, including request, resend, old-link invalidation, newest-link verification, browser restart, active-session display, current sign-out, safe failure, focus, responsive, and axe checks; specification validation and `git diff --check` pass.
- Remaining: Task 7 owns attempt and expired-session retention, export and erasure integration, processor and release-gate enforcement, full secret and analytics review, CSP review, failure injection, Sobelow, and the final slice verification gate.

### 2026-07-27 - Task 7 implementation started

- In progress: Extending retention, rights, processing inventory, provider and transfer release-gate enforcement, redaction and secret-exposure checks, analytics exclusions, CSP review, security diagnostics, and the final local and production verification gates.
- Preflight: Tasks 2–6 are complete; Task 7 may tighten their privacy and security controls but must preserve their account-neutral behavior, atomic rollback, and verified-session boundaries.

### 2026-07-27 - Passwordless privacy and security contract complete (Task 7)

- Completed: Extended the processing inventory across hosted identities, verified sign-in methods, magic-link attempts, passwordless delivery, hosted sessions, and in-memory abuse controls; added configurable attempt and expired-session pruning; extended credential-free account export and atomic erasure; and added export and erasure for attempts that never produced an account.
- Release enforcement: Added runtime delivery-module and mailer-adapter seams, rejected local and test delivery configurations for public release, and extended the deployment privacy profile with provider, processor agreement, sender domain, region, transfer safeguards, retention approval, privacy review, and anonymisation evidence. The local adapter remains valid only for development and test.
- Security: Removed linkable attempt IDs from delivery-failure logs; proved magic-link and session credentials stay out of inspection, logs, redirect bodies, assigns, and analytics; retained `Secure`, `HttpOnly`, `SameSite=Lax`, signed cookie handling; reviewed the same-origin CSP and no-referrer verification boundary; and fixed hosted-session Dialyzer typing without changing authorization behavior. Narrow `Ecto.Multi` opaque-type suppressions cover only the established false positive.
- Proof: 39 focused privacy, rights, retention, processor, redaction, cookie, token, CSP, and failure tests pass; `mix check` passes with 294 tests and one tagged live test excluded; `mix deps.audit`, `mix sobelow --config`, and `mix dialyzer` pass; npm reports no vulnerabilities; all 56 Playwright scenarios pass across desktop and mobile; production assets and release assembly pass; specification validation and `git diff --check` pass.
- Readiness: Product requirements remain approved; technical design, implementation, and local verification are complete. Public release remains blocked only by the production email provider and DPA, sender domain, region and transfer evidence, final retention-duration approval, and required privacy or legal and anonymisation review recorded in the release gate.

### 2026-07-28 - Fix: e2e resend scenario navigated off the server under test

- Reported symptom: the Task 6 desktop and mobile Playwright resend scenario (`assets/e2e/hosted-access.spec.js:68`, "resend invalidates the old link and the newest link survives browser restart") failed deterministically on chromium and mobile-chromium, though the Verification Gate browser items were checked. This under-cut the recorded gate: "Required desktop and mobile browser scenarios pass" and the `npm --prefix assets run test:e2e` line were `[x]` while this scenario was red.
- Root cause: the delivered magic-link URL is built from `:passwordless` `app_origin` (`lib/sdd_orchestrator/hosted_access/magic_link_email.ex`). The git-ignored dev `.env` sets `APP_ORIGIN=http://localhost:4000` (local GitHub App), and `config/dev.exs` loaded `.env` with an unconditional `System.put_env`, overwriting the `APP_ORIGIN=http://localhost:4003` that `assets/playwright.config.js` exports for its own server. So links pointed at `:4000`; `page.goto(firstLink)` left the e2e server (`:4003`) for the developer's `:4000` server, which had pending migrations and rendered `Phoenix.Ecto.PendingMigrationError` instead of the expected result. The scenario only passed when a correctly-migrated app happened to serve `:4000`; on a clean or mismatched environment it failed.
- Fix: `config/dev.exs` now applies each `.env` value only when the variable is not already exported (`System.get_env(key) == nil`), so an explicit caller env wins over the file — standard dotenv precedence. The Playwright server's `APP_ORIGIN`/`PORT` survive, magic links resolve on `:4003`, and the scenario stays on the server under test. A normal `mix phx.server` with no exported `APP_ORIGIN` still takes the `.env` `:4000` value, unchanged. Change is confined to the dev-only config loader; no application code, test-env, or prod-env config changed.
- Over-claim correction: the Verification Gate browser items were genuinely failing when checked; they are now truthfully passing after the fix rather than left mischecked. Evidence below.
- Proof (real exit status): `npm --prefix assets run test:e2e` = 68 passed, 0 failed (previously 66 passed / 2 failed — the two resend projects); `hosted-access.spec.js` alone = 6 passed with the resend scenario green on both projects while the broken `:4000` server was still running, confirming independence from `:4000`. `APP_ORIGIN=http://localhost:4003 MIX_ENV=dev` resolves passwordless `app_origin` to `http://localhost:4003`; plain `MIX_ENV=dev` resolves to `http://localhost:4000`. `mix check` exit 0 (format, `compile --warnings-as-errors`, `credo --strict` no issues, `test` 376 passed / 1 excluded `:live`); `mix deps.audit` (no vulnerabilities), `mix sobelow --config`, and `mix dialyzer` (7 documented skips) each exit 0; `git diff --check` clean.
- Not re-run: `MIX_ENV=prod mix assets.deploy` and `mix release`. The change is in `config/dev.exs`, which `config_env() == :prod` never loads, so prod builds are unaffected; they were green at the Task 7 gate.
- Discovered (routed to the Release Gate, not fixed here): production `runtime.exs` wires `:github` `app_origin` from `APP_ORIGIN` but not `:passwordless`, so a prod build would use the `config.exs` `:4000` default for magic links. Recorded as a release-gate item to wire before public release.
- Spec updates: added the production passwordless-origin release-gate item and this entry. Status stays `In Progress`; the open GDPR/retention/privacy verification-gate item and the release gate are unchanged.

### 2026-07-28 - Review checkpoint (review-spec)

- Verdict: The recorded state is accurate and no longer over-claims. After commit `a645871` the previously-red Task 6 resend scenario is genuinely green, so the checked browser-scenario gate items (lines 107, 110) are now truthful. All completed task proofs and the full verification gate reproduce with real exit status. No scope drift, forward dependency, or over-claim found. Implementation faithfully realizes `requirements.md`/`design.md`.
- Re-run evidence (HEAD `a645871`, real exit codes): `mix format --check-formatted` 0; `mix compile --warnings-as-errors --force` 0; `mix credo --strict` 0 (no issues); `mix dialyzer` 0 (passed, 7 documented `Ecto.Multi` skips); `mix deps.audit` 0 (no vulnerabilities); `mix sobelow --config` 0; `mix test` 0 (376 passed, 1 excluded `:live`); `npm --prefix assets run test:e2e` 0 (68 passed, 0 failed, resend green on chromium and mobile-chromium); `MIX_ENV=prod mix assets.deploy` 0; `MIX_ENV=prod mix release` 0; `python3 .agents/scripts/validate_spec.py specs/03-hosted-passwordless-access` 0; `git diff --check` clean; `cmp -s AGENTS.md CLAUDE.md` identical.
- Code inspection (security-critical, spot-checked against claims): magic-link token is 256-bit `:crypto.strong_rand_bytes`, persisted only as a salted SHA-256 `token_digest` (`redact: true`), raw token reaching email delivery alone (`magic_links.ex`, `magic_link_attempt.ex`); verification consumes under `FOR UPDATE` lock with a compare-and-set `update_all` guarded on `is_nil(consumed_at) and is_nil(invalidated_at)`, and requests invalidate prior unconsumed attempts under an email lock (`verification.ex`, `magic_links.ex`); the session cookie is `Phoenix.Token`-signed with `http_only`/`secure`/`same_site: "Lax"`/30-day max-age and persists only a digest (`session_cookie.ex`); `request_magic_link` returns a single neutral `{:ok, %{status: :accepted}}` (`hosted_access.ex`); device recognition retains only `user_agent_family`/`os_family`, explicitly no IP, version, or fingerprint (`device_recognition.ex`).
- Finding (Minor, release-gated, already recorded): production `runtime.exs` derives `:github` `app_origin` from `APP_ORIGIN` but not `:passwordless`, so a prod build would fall back to the `config.exs` `http://localhost:4000` default for magic-link emails. Confirmed by code (no `:passwordless` runtime wiring; `config/dev.exs` is not loaded in `:prod`). Route: `implement-spec` when the production delivery configuration is wired; it is not an implementation or local-verification blocker. Already listed in the Release Gate.
- Readiness: product requirements approved; implementation and local verification complete and independently reproduced. Release remains blocked by the GDPR/retention/privacy-and-legal review, the production email provider and DPA/sender-domain/region/transfer evidence, final retention-duration approval, and the passwordless-origin wiring above. No task-status change; slice stays `In Progress`.
