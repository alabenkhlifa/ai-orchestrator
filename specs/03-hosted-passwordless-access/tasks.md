# Hosted Passwordless Access Tasks

## Status

Not Started

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

## Tasks

- [ ] Define the approved passwordless authentication and session contracts.
  - Purpose: Resolve token, attempt, delivery, abuse, session, recovery, and privacy behavior before coding.
  - Proof: Requirements, design, data contracts, schemas, failure states, and test commands are approved with no blocking questions.

- [ ] Implement account-neutral magic-link requests and delivery.
  - Purpose: Send a one-time credential without exposing account existence or secrets.
  - Proof: Integration and security tests cover new and existing emails, provider failure, rate limits, redaction, and equivalent responses.

- [ ] Implement atomic magic-link verification and consumption.
  - Purpose: Establish identity only from a valid attempt-bound unused token.
  - Proof: Tests cover success, expiry, replay, mismatch, tampering, concurrency, and no partial identity creation.

- [ ] Create or restore stable hosted identity and workspace.
  - Purpose: Give the verified user one durable hosted ownership boundary.
  - Proof: Tests cover new identity, restoration, retry, concurrency, and cross-user isolation.

- [ ] Implement protected hosted sessions and sign-out.
  - Purpose: Authorize hosted access independently from token delivery and coding agents while giving users control over every active device.
  - Proof: Session tests cover browser restart, multiple independent devices, expiry, renewal, current-device sign-out, individual revocation, all-device revocation, concurrency, and rejected access.

- [ ] Build passwordless authentication UX and recovery states.
  - Purpose: Make success, waiting, resend, expiry, and failure actionable for non-technical users.
  - Proof: Desktop and mobile browser scenarios cover the complete flow, identify the verified email as the access method, explain the first-release recovery limit, expose no account or unsupported support-recovery path, and provide active-session, current-device sign-out, individual-revocation, and all-device sign-out states.

- [ ] Enforce the feature GDPR data contract and security review.
  - Purpose: Govern email, tokens, sessions, logs, processors, retention, rights, and allowed anonymous metrics.
  - Proof: Lifecycle, access, redaction, deletion, processor, transfer, and anonymisation checks pass with required review recorded.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Request, delivery, verification, replay, concurrency, and session tests pass.
- [ ] Account-enumeration and abuse-control review passes.
- [ ] Token, credential, client-payload, analytics, and log exposure review passes.
- [ ] Lost-email scenarios preserve access only through a sign-in method linked beforehand and never authorize verified-email replacement.
- [ ] Browser-restart, multiple-device, current-session, individual-session, and all-session revocation scenarios pass.
- [ ] Required desktop and mobile browser scenarios pass.
- [ ] GDPR data contract, retention, rights, processor, transfer, and privacy-review gates are complete.
- [ ] Build, formatting, lint, static checks, and failure diagnostics pass.

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
