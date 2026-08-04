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
- Production passwordless magic-link origin: `runtime.exs` derives the GitHub origin from `APP_ORIGIN` in `:prod` but does not set `:passwordless` `app_origin`, so a prod build would fall back to the `config.exs` `http://localhost:4000` default. Wire the passwordless origin from `APP_ORIGIN` (as GitHub does) as part of the production delivery configuration before release. Not an implementation or local-verification blocker; dev and e2e resolve their own origin.

## Progress Log

See [progress.md](progress.md).
