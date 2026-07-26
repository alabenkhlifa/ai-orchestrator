# Hosted Passwordless Access Design

## Context

Hosted project data requires a recoverable authorization boundary for users who do not use GitHub. Passwordless email access avoids a second password system but creates token-delivery, replay, enumeration, session, recovery, and privacy responsibilities.

## Proposed Approach

Explain the verified-email access and recovery boundary, accept an email through an account-neutral endpoint, create a protected authentication attempt, deliver a short-lived single-use token, consume it exactly once for the intended attempt, and establish an independently revocable hosted device session for one stable identity and workspace. Preserve valid sessions across browser restarts, support multiple devices, and provide current-device, individual-session, and all-session revocation. A sign-in method linked before email access is lost may restore the same identity, but it cannot change the verified email. Compose hosted and local catalog references without changing local ownership or storage.

Exact token format, delivery provider, storage representation, and session mechanism remain deferred.

## Components Affected

- Hosted-storage authentication entry.
- Magic-link request, delivery, verification, resend, and recovery surfaces.
- Hosted identity and personal workspace service.
- Protected session and sign-out behavior.
- Active-device session management.
- Email delivery integration and abuse controls.
- Combined project catalog.
- Audit, security logs, privacy governance, and data-subject-rights workflows.

## Data and Access Boundaries

- `HostedIdentity`: the stable passwordless identity for one verified email boundary.
- `ExternalIdentity`: the verified email sign-in method attached to that stable identity.
- `MagicLinkAttempt`: short-lived attempt state with a protected token representation, intended email, expiry, consumption state, and approved diagnostic metadata.
- `HostedSession`: revocable authorization to hosted workspace data.
- `PersonalWorkspace`: the hosted ownership boundary restored after authentication.

Required boundaries:

- No hosted data is exposed before successful verification and session establishment.
- Token secrets remain inside the accepted credential boundary and are never available to analytics or ordinary logs.
- Request and failure responses are account-neutral.
- Verification consumption is atomic and replay-safe.
- Sessions are separated from coding-agent credentials and capabilities.
- Each device session is independently revocable and may coexist with other sessions for the same hosted identity.
- Browser restart does not end a valid session; sign-out, explicit revocation, and approved security expiration do.
- Active-session device details are personal data and require an approved minimum-field, access, retention, deletion, and rights contract.
- A sign-in method linked before email loss may authenticate the same hosted identity but does not authorize verified-email replacement.
- Without proof of the verified email or another previously linked sign-in method, neither self-service nor support can bypass the authentication boundary in the first release.
- Device project references can be composed into the catalog but are not attached to the hosted identity or copied to hosted storage.
- Catalog composition uses stable project identity, not repository similarity, to distinguish one migrated or resynchronized project from separate projects linked to the same repository.
- Delivery providers and logs are included in the personal-data processing and retention inventory.

## Interfaces

- Magic-link request interface: accept an email, create a protected attempt, apply abuse controls, and return an account-neutral acknowledgement.
- Delivery interface: send the one-time link through an approved processor without exposing token secrets to unrelated systems.
- Verification interface: validate attempt binding, expiry, single use, and integrity before consuming the token atomically.
- Hosted identity interface: create or restore the stable passwordless identity and workspace.
- Session interface: establish and restore a persistent device session, enforce approved expiry, revoke the current session on normal sign-out, and deny expired or revoked sessions before exposing hosted data.
- Session-management interface: list active device sessions and revoke one session or all sessions without affecting on-device projects.
- Catalog interface: combine authorized hosted and locally available device projects, preserve separate project identities even when repositories match, and show one authoritative entry for an explicitly migrated or resynchronized stable project.
- Lost-email access interface: restore the same hosted identity through a sign-in method linked before the loss, or fail without a support override when none exists.
- Future verified-email change interface: require fresh proof of the current email and verification of the new email; do not accept an existing session or another linked method as a substitute.

## Decisions and Tradeoffs

### Passwordless Verified Email

- Choice: Use a verified email and magic link for non-GitHub hosted access.
- Reason: Users can access hosted projects without a GitHub account or another password.
- Consequence: Email delivery becomes an authentication dependency and requires explicit token, abuse, session, recovery, and privacy controls.

### Account-Neutral Responses

- Choice: Return the same acknowledgement and safe failure shape regardless of account existence.
- Reason: Authentication must not become an account-enumeration interface.
- Consequence: Diagnostics must remain useful internally without leaking identity state to the requester.

### Combined Catalog Without Implicit Upload

- Choice: Show authorized hosted and current-device projects together after authentication without changing either boundary. Keep different stable projects separate even when they share a repository, and show an explicitly migrated or resynchronized stable project once with its authoritative storage mode.
- Reason: Users need one working catalog while retaining deliberate storage choices.
- Consequence: Catalog composition uses stable project identity and cannot be treated as identity merge, migration, or synchronization. Every entry shows storage mode and current availability; exact labels and visual grouping remain a design decision.

### Pre-Linked Sign-In Recovery Only

- Choice: After verified-email access is lost, allow account access only through another sign-in method linked to the same identity before the loss. Do not provide a first-release support override.
- Reason: A newly asserted recovery identity would create an account-takeover path without an approved proof model.
- Consequence: The first hosted-access slice must explain the limitation and restore the same workspace through a valid pre-linked method without changing the verified email.

### Two-Proof Email Change After The First Slice

- Choice: Defer verified-email change UI and require future changes to prove the current email and verify the new email.
- Reason: An existing session or linked provider may be compromised and must not replace independent control of the current email.
- Consequence: Linked-provider access preserves account use but cannot change the email. A future recovery method for users who cannot prove the current email requires a separate specification update.

### Persistent Independent Device Sessions

- Choice: Keep valid sessions across browser restarts and allow independent sessions on multiple devices.
- Reason: Requiring a new magic link after every browser restart would make normal use unnecessarily disruptive.
- Consequence: Every session needs independent protection, expiry, visibility, and revocation. Exact lifetimes and renewal mechanisms remain technical decisions.

### Current-Device And All-Device Sign-Out

- Choice: Normal sign-out revokes only the current device session. Account settings allow revoking one active session or selecting `Sign out all devices`.
- Reason: Users need predictable daily sign-out and a separate recovery action for lost or unknown devices.
- Consequence: Session management must clearly identify the affected scope, revoke atomically, and leave on-device projects unchanged.

### Magic-Link Token And Consumption

- Choice: A magic link carries a high-entropy random token (256-bit) stored server-side only as a salted hash on a `MagicLinkAttempt` bound to the intended email. Default lifetime is 15 minutes. Consumption is an atomic compare-and-set on the unconsumed state, so a token verifies exactly once and replays fail closed. Requesting or resending a link invalidates prior unconsumed links for that email so only the newest is valid.
- Reason: Single-use atomic consumption and newest-only validity remove replay and concurrent-credential risk without a password.
- Consequence: The raw token exists only inside the delivered link; it never appears in persisted data, client payloads, analytics, or logs. Lifetime and resend windows are tunable defaults confirmed at security review.

### Email Delivery Adapter

- Choice: Deliver through a pluggable mailer behaviour (Swoosh adapter). Local and CI verification use a test or local adapter; the production delivery provider and its data-processing agreement, sender domain, and region are a release-gate decision. Delivery failure never changes the account-neutral acknowledgement, is logged internally with redaction, and is retriable; a provider outage does not weaken verification.
- Reason: Decoupling delivery keeps the authentication contract and its tests independent of any single vendor.
- Consequence: Implementation and local verification proceed against the adapter contract; the concrete processor is selected and reviewed at the release gate.

### Account-Neutral Abuse Controls

- Choice: Apply per-email and per-IP token-bucket rate limits plus a global send cap, returning the identical account-neutral acknowledgement whether or not a request is throttled or the email exists. Repeated requests back off; limits are tunable defaults.
- Reason: Abuse controls must not become an account-enumeration or unwanted-mail channel.
- Consequence: Throttling is invisible to the requester; internal diagnostics remain redacted. Final limit values are confirmed at security review.

### Persistent Session Mechanism

- Choice: Sessions are server-side records (Ecto-backed) referenced by a signed, HttpOnly, Secure cookie, independent per device and persistent across browser restarts. Default absolute lifetime is 30 days with sliding renewal on activity; revocation deletes the server record so the cookie is rejected. Device identification stores only coarse recognition fields (user-agent family, OS family, first-seen and last-seen timestamps) with no IP retention and no fingerprinting. Single sign-out deletes the current session record; `Sign out all devices` deletes every session record for the identity.
- Reason: Server-side records make each device session independently visible, renewable, and revocable while keeping device data minimal.
- Consequence: Coding-agent processes receive no session credential. Exact lifetime, inactivity, and renewal values are tunable defaults confirmed at security review.

### Pre-Linked Sign-In Seam

- Choice: A `HostedIdentity` may carry multiple `ExternalIdentity` sign-in methods; authenticating through any of them restores the same identity and workspace. The verification path never grants verified-email-change authority. In this slice the only additional sign-in method is GitHub, delivered by `specs/04-github-identity-linking/`; this slice implements the seam and the account-neutral failure when no pre-linked method exists.
- Reason: Recovery through a pre-linked method must reuse the identity boundary without becoming an email-change or account-takeover path.
- Consequence: The deferred two-proof email-change flow is the only route to change the verified email; no first-release support override exists.

### Application Architecture

- Choice: Implement on the existing Phoenix application: Phoenix and Ecto over Postgres, LiveView for the request, waiting, resend, and session-management flows, Swoosh for delivery, and a rate limiter for abuse controls, with tokens and session references handled by signed, hashed representations.
- Reason: The authentication and session boundaries fit the established Slice 01 stack with no new platform.
- Consequence: No implicit new technology is introduced; the architecture is an engineering decision within the approved behavior.

### Verification Strategy

- Choice: Verify with the Slice 01 toolchain: ExUnit for request, delivery, verification, replay, concurrency, session, restoration, and cross-user isolation; Sobelow and targeted security tests for enumeration, abuse, and secret exposure; and Playwright (`npm --prefix assets run test:e2e`) desktop and mobile scenarios for the complete flow, resend, expiry, failure, multi-device, and revocation, all under `mix check`.
- Reason: Every observable authentication and session behavior is locally verifiable with the established gate.
- Consequence: Only the production delivery provider and final privacy or legal review remain release-gate items.

### Authentication Data-Protection Contract

- Choice: Personal data is the verified email, `ExternalIdentity`, `MagicLinkAttempt` (hashed token, intended email, expiry, consumption state, minimal diagnostic), `HostedSession` (coarse device fields and timestamps), delivery records, and security logs. Purposes are authentication, session management, and abuse and security protection. Lawful basis is contract necessity for authentication and sessions and legitimate interest for abuse and security logging. Retention: attempts expire in minutes and are purged shortly after, sessions until revoked or expired then purged, delivery records short and redacted, and security logs bounded. Erasure removes the identity, its sessions, and attempts; analytics stay aggregate and anonymous with no email hash, IP address, pseudonym, or session or delivery identifier.
- Reason: Applies data minimization, purpose limitation, storage limitation, and least privilege across primary, derived, and processor storage.
- Consequence: Final retention durations, the delivery processor and its region and transfer safeguards, and the required privacy review are release-gate items; the recorded contract is sufficient to build and locally verify.

## Risks

- Magic links can be stolen, replayed, leaked through referrers, or logged. Use protected token storage, short lifetime, single-use atomic consumption, and surface reviews.
- Request endpoints can enumerate accounts or send unwanted email. Keep responses account-neutral and apply approved abuse controls.
- Email compromise can grant hosted access. Define session visibility, revocation, notifications, and recovery safeguards.
- A session, linked provider, or support process could be misused to replace the verified email. Enforce the two-proof boundary and provide no first-release override.
- Users can permanently lose access if they lose their only sign-in method. Explain that limitation before hosted account creation without implying unavailable recovery.
- Persistent sessions increase exposure when a device is lost or shared. Make active sessions visible and independently revocable, and enforce the approved security expiration.
- Device descriptions can be inaccurate or reveal excessive personal data. Treat them as hints and approve only the minimum fields needed for recognition and revocation.
- Delivery outages can block access. Define provider failure behavior and recovery without weakening verification.
- Long-lived authentication records can exceed their purpose. Apply field-level retention and deletion across primary and derived storage and processors.
- Catalog composition can accidentally upload local projects. Enforce explicit ownership and storage boundaries in service and integration tests.
- Repository-based deduplication can hide an independent project or imply an unsafe merge. Use stable project identity and preserve separate entries when identities differ.

## Open Questions

- Deferred after this slice: How does combined-catalog composition prove stable project identity and present separate same-repository projects clearly without implicit identity or storage mutation? Owned by the catalog integration deferred after this slice.
- Release gate: The production delivery provider and its processor agreement, sender domain, region, and transfer safeguards; final retention durations; and the required privacy or legal review of the authentication data-protection contract.
