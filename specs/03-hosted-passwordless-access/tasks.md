# Hosted Passwordless Access Tasks

## Status

In Progress

Tasks 1–7 are implemented and locally verified. The slice remains short of
`Verified` because the production delivery processor evidence, final retention
approval, and privacy or legal and anonymisation review remain in the release
gate below.

## Active Slice

Deliver passwordless hosted sign-in from magic-link request through verified session and stable workspace restoration, with account-neutral failure behavior and the approved lost-email boundary.

## Implementation Boundary

Included:

- Magic-link request, delivery, verification, and single-use consumption.
- Stable hosted identity and workspace creation or restoration.
- Persistent independent device sessions, current-device sign-out, active-session management, and all-device sign-out.
- Verified-email access disclosure and first-release lost-email boundary.
- Enumeration resistance, abuse controls, audit, and security logging.
- GDPR data contracts for the introduced processing.
- Browser and automated proof for success and failure paths.

Excluded:

- GitHub identity linking, local worker implementation, storage migration, portability, and collaboration.
- Password authentication and unrelated account-management features.

Deferred after this slice:

- Combined catalog integration that preserves separate project identities and shows one authoritative entry after explicit migration or resynchronization.
- Verified-email change UI and recovery beyond a sign-in method linked before email access was lost.
- Deferred criteria: AC-13, AC-20, AC-21, AC-22, AC-23
- Deferred entities: none.

## Tasks

- [x] Task 1 - Approve the passwordless authentication, session, identity, and privacy contracts.
  - Status: Complete.
  - Purpose: Resolve token, attempt, delivery, abuse, session, recovery, and privacy behavior before coding.
  - Owned surfaces: Active-slice identity, workflow, token, attempt, delivery, abuse, session, recovery, privacy, release-gate, task-ownership, traceability, and verification agreement.
  - Owns: none (agreement gate)
  - Depends on: none
  - Proof: Approved requirements, design decisions, data contracts, active and deferred traceability, task sequence, and canonical test commands have no unresolved implementation or local-verification blockers.

- [x] Task 2 - Establish the hosted identity and workspace foundation.
  - Status: Complete.
  - Purpose: Give every verified passwordless address one stable hosted identity and personal workspace without case-variant duplication.
  - Owned surfaces: `HostedIdentity`, email `ExternalIdentity`, case-insensitive email comparison key with preserved verified spelling, identity lookup and concurrent creation, one-to-one `PersonalWorkspace` restoration, database constraints, context interfaces, and fixtures.
  - Owns: AC-03, AC-07, AC-08, entity:HostedIdentity, entity:ExternalIdentity, entity:PersonalWorkspace
  - Depends on: Task 1
  - Proof: Domain and database tests cover trimmed case-insensitive uniqueness, preserved delivery and display spelling, new identity creation, existing identity restoration, stable workspace identity, retry, concurrency, and cross-user isolation.

- [x] Task 3 - Implement account-neutral magic-link requests, delivery, resend, and abuse controls.
  - Status: Complete.
  - Purpose: Send one protected credential without exposing account existence, secrets, or throttling state.
  - Owned surfaces: Magic-link request and resend service boundary, `MagicLinkAttempt`, raw-token generation and delivery-only handoff, salted token digest persistence, 15-minute expiry, newest-only invalidation, per-email and per-IP token buckets, global send cap, Swoosh mailer behaviour and local/test adapter, account-neutral acknowledgement, redacted delivery diagnostics, and attempt fixtures.
  - Owns: AC-02, AC-06, entity:MagicLinkAttempt
  - Depends on: Task 1, Task 2
  - Proof: Integration, concurrency, adapter-contract, and security tests cover new and existing emails, equivalent acknowledgements, resend invalidation, expiry setup, throttling, provider failure, retry, token non-persistence, redaction, and no identity disclosure.

- [x] Task 4 - Implement atomic magic-link verification, identity restoration, and initial session creation.
  - Status: Complete.
  - Purpose: Establish hosted access only from one valid attempt-bound unused token and leave no partial identity, workspace, or session.
  - Owned surfaces: Verification service and return endpoint, token-digest lookup, attempt and intended-email binding, expiry and integrity validation, atomic compare-and-set consumption, `HostedSession` persistence and initial signed-cookie issuance contract, identity and workspace restoration through Task 2, transaction rollback, replay handling, and verification fixtures.
  - Owns: AC-01, AC-04, AC-05, entity:HostedSession
  - Depends on: Task 2, Task 3
  - Proof: Transaction, constraint, concurrency, and security tests cover success, invalid token, expiry, replay, mismatch, tampering, concurrent consumption, stable restoration, signed-cookie issuance, and rollback without partial identity, workspace, attempt, or session state.

- [x] Task 5 - Implement protected hosted-session lifecycle, revocation, and pre-linked recovery.
  - Status: Complete.
  - Purpose: Authorize hosted access independently per device while preserving the approved lost-email and verified-email-change boundaries.
  - Owned surfaces: Hosted-session lookup and authorization plug or LiveView hook, signed HttpOnly Secure cookie handling, 30-day absolute lifetime and sliding renewal, coarse device recognition fields, protected hosted routing, browser-restart restoration, current-device sign-out, active-session listing, individual and all-device revocation, concurrent revocation, coding-agent credential exclusion, pre-linked `ExternalIdentity` authentication seam, no-support-override failure, and verified-email-change denial.
  - Owns: AC-10, AC-11, AC-12, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-24
  - Depends on: Task 2, Task 4
  - Proof: Session, authorization, recovery-seam, and concurrency tests cover browser restart, independent devices, expiry, renewal, protected-route denial, current-only sign-out, one-session and all-session revocation, simultaneous revocation, pre-linked restoration, missing-method failure, unchanged verified email, unaffected on-device access, and absence of session credentials from coding-agent boundaries.

- [x] Task 6 - Deliver the passwordless authentication and session-management experience.
  - Status: Complete.
  - Purpose: Make success, waiting, resend, expiry, and failure actionable for non-technical users.
  - Owned surfaces: Hosted-access disclosure; email request, neutral acknowledgement, waiting, resend, verification-result, expiry, and safe-failure LiveViews; current-session sign-out; active-device session-management UI; individual and all-device revocation feedback; pre-linked recovery and no-override copy; focus, responsive, keyboard, non-color, and accessible browser behavior; and source-specific return handoff to the caller without combined-catalog ownership.
  - Owns: AC-09
  - Depends on: Task 3, Task 4, Task 5
  - Proof: LiveView and desktop/mobile Playwright scenarios cover the complete flow, approved access and lost-email disclosure, account-neutral request and failure presentation, waiting, resend, success, expiry, replay, recovery, browser restart, current-device sign-out, individual and all-device revocation, responsive layout, keyboard use, focus, and accessibility.

- [x] Task 7 - Enforce the passwordless privacy and security contract.
  - Status: Complete.
  - Purpose: Govern email, tokens, sessions, logs, processors, retention, rights, and allowed anonymous metrics.
  - Owned surfaces: Processing inventory, attempt and expired-session retention pruning, identity and authentication-data export and erasure, access boundaries, delivery-processor configuration seam, transfer and release-gate enforcement, log and inspection redaction, raw-token and cookie-secret exposure checks, Content-Security-Policy review, prohibited product analytics and stable pseudonym detection, and security diagnostics.
  - Owns: AC-25
  - Depends on: Task 2, Task 3, Task 4, Task 5, Task 6
  - Proof: Data-inventory, retention, deletion, rights, access, provider-configuration, transfer-gate, redaction, failure-injection, token, cookie, client-payload, log, analytics, secret-scanning, Sobelow, and security-review checks pass without weakening account-neutral behavior.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Every active acceptance criterion and data entity has one clear primary task owner; deferred criteria remain outside the active implementation.
- [x] Request, delivery, verification, replay, concurrency, and session tests pass.
- [x] Account-enumeration and abuse-control review passes.
- [x] Token, credential, client-payload, analytics, and log exposure review passes.
- [x] Lost-email scenarios preserve access only through a sign-in method linked beforehand and never authorize verified-email replacement.
- [x] Browser-restart, multiple-device, current-session, individual-session, and all-session revocation scenarios pass.
- [x] Required desktop and mobile browser scenarios pass.
- [ ] GDPR data contract, retention, rights, processor, transfer, and privacy-review gates are complete.
- [x] `mix check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` pass.
- [x] `npm --prefix assets ci`, `npm --prefix assets run test:e2e`, `MIX_ENV=prod mix assets.deploy`, and `MIX_ENV=prod mix release` pass.

## Blocked Decisions

- None.

## Release Gate

- The production email delivery provider and its data-processing agreement, sender domain, region, and transfer safeguards.
- Final retention durations for attempts, sessions, delivery records, and security logs recorded in `design.md`.
- Required privacy or legal review and anonymisation confirmation for the authentication data-protection contract.

## Progress Log

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
