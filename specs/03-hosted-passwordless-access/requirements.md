# Hosted Passwordless Access

## Status

Approved

## Outcome

A user who does not use GitHub can choose hosted project-data storage, verify an email address through a passwordless magic link, and securely create or restore hosted workspace access without managing a password.

## Users

- BA, PO, and PM users who need hosted projects or later collaboration without a GitHub account.
- Developers and contributors using local repositories with hosted SDD project data.

## Primary Workflow

1. A user enters through `Work without GitHub` and selects hosted project-data storage.
2. The product identifies the verified email as the access method and explains that losing access to it is not recoverable in the first release unless another sign-in method was linked beforehand.
3. The product requests an email address and returns an account-neutral acknowledgement.
4. The product sends a short-lived, single-use magic link bound to the current authentication attempt.
5. The user opens the valid link before expiry.
6. The product verifies the email, consumes the link once, and establishes a protected hosted session.
7. The product creates or restores the stable hosted identity and personal workspace.
8. Authorized hosted projects are shown alongside on-device projects available to the current device without uploading or reassigning them.

## In Scope

- Verified email as the non-GitHub hosted identity.
- Passwordless magic-link request, delivery, verification, consumption, resend, abuse protection, and recovery boundaries.
- Hosted session creation, restoration, expiry, revocation, and sign-out.
- Persistent independent device sessions and user-controlled session revocation.
- Stable hosted identity and personal workspace creation or restoration.
- Account-enumeration resistance.
- First-release lost-email access and recovery boundary.
- Combined presentation of authorized hosted and locally available on-device projects without implicit migration.
- GDPR data contracts for email, authentication events, sessions, delivery processors, logs, support, and security data.

## Out of Scope

- GitHub sign-in and repository discovery, defined in `specs/01-github-project-onboarding/`.
- Local worker and repository validation, defined in `specs/02-local-project-onboarding/`.
- GitHub and passwordless identity merging, defined in `specs/04-github-identity-linking/`.
- Storage migration, retention, and resynchronization, defined in `specs/05-project-storage-lifecycle/`.
- Password-based accounts.
- Verified-email change UI and recovery beyond a sign-in method linked before email access was lost.
- Collaboration invitations, memberships, roles, or permissions.
- Shared-device isolation beyond the current operating-system boundary.

## Business Rules

- Hosted storage must establish an authorized identity before hosted project data is created or exposed.
- The non-GitHub hosted path uses a verified email and must not require or store a password.
- For identity uniqueness and passwordless sign-in, trim surrounding whitespace and compare the complete email address case-insensitively. Preserve the successfully verified spelling for delivery and user-visible display.
- A magic link must be short-lived, single-use, bound to the intended authentication attempt, and invalid after successful use.
- Magic-link tokens and equivalent secrets must not appear in persisted application data beyond the approved protected representation, client-visible payloads, analytics, or logs.
- Requesting a magic link must return the same user-facing response whether or not the email already has an account.
- Invalid, expired, used, replayed, or mismatched links must not establish a session or expose whether an account exists.
- Resend behavior must not leave multiple uncontrolled valid links; the approved invalidation rule must be enforced.
- Delivery and verification endpoints require approved rate limits and abuse controls without creating account-enumeration signals.
- A successful verification creates or restores one stable hosted identity and personal workspace for the verified email under the approved identity rules.
- The first hosted-access slice must identify the verified email as the access method and must not promise recovery that the release does not support.
- If the user loses access to the verified email, another sign-in method linked to the same hosted identity before the loss may still restore access to that identity and workspace.
- If no other sign-in method was linked before email access was lost, the first release provides no self-service or support override that bypasses proof of an existing sign-in method.
- Access through an already linked sign-in method must not replace or change the verified email.
- Changing the verified email requires fresh proof through the current verified email and verification of the new email. An existing session or another linked sign-in method alone is insufficient.
- The verified-email change interface is deferred beyond the first hosted-access slice.
- Hosted sessions must be protected, revocable, and unavailable to coding-agent processes unless a later specification grants a narrow capability.
- A hosted session must remain valid across browser restarts until the user signs out, the session is revoked, or it reaches its approved security expiration.
- The same hosted identity may have independent active sessions on multiple devices.
- Normal sign-out must revoke only the current device session.
- Account settings must show active device sessions and allow the user to revoke one session or all sessions.
- Revoking one session must not end other active sessions. `Sign out all devices` must revoke every active session for the hosted identity.
- Exact expiration periods, renewal mechanics, device-identification fields, and presentation details are technical and privacy decisions constrained by this behavior.
- Signing out removes access to hosted projects from the affected client without deleting or hiding on-device projects.
- On-device projects remain available under the device boundary after authentication and sign-out; authentication must not upload, synchronize, duplicate, reassign, or change their storage mode.
- A combined catalog must identify each project's storage mode and current availability.
- Different stable projects must remain separate catalog entries even when they link to the same repository. A shared repository alone must not merge or deduplicate them.
- One stable project that has been explicitly migrated or resynchronized must appear once with its authoritative storage mode.
- Combined-catalog presentation must not automatically merge projects, link identities, upload data, synchronize data, or change a project's storage mode.
- The verified email, authentication events, delivery records, sessions, and security logs are personal data with approved purposes, lawful bases, access, retention, deletion, rights behavior, processors, transfers, and required review.
- Analytics may retain only aggregate genuinely anonymous metrics; email hashes, stable pseudonyms, IP addresses, and linkable delivery or session identifiers are personal data, not anonymous analytics.

## Acceptance Criteria

- [AC-01] Given a non-GitHub user selects hosted storage, when they continue, then email verification is required before hosted data is created or exposed.
- [AC-02] Given any email is submitted, when the request is acknowledged, then the response does not reveal whether an account exists.
- [AC-03] Given email addresses differ only by case or surrounding whitespace, when either address is successfully verified, then both restore the same hosted identity and workspace while delivery and display preserve the successfully verified spelling.
- [AC-04] Given a valid unused magic link for the current attempt, when it is opened before expiry, then the email is verified and a protected hosted session is established without a password.
- [AC-05] Given a link is invalid, expired, already used, replayed, or bound to another attempt, when it is opened, then no session or hosted access is created and the response remains account-neutral.
- [AC-06] Given resend is requested, when a new link is issued, then the approved invalidation and rate-limit rules prevent uncontrolled concurrent credentials.
- [AC-07] Given verification succeeds for an existing identity, when the session starts, then the same stable hosted workspace and projects are restored.
- [AC-08] Given verification succeeds for a new identity, when workspace creation completes, then exactly one stable hosted workspace exists.
- [AC-09] Given hosted setup begins, when the access method is explained, then the user is told that losing the verified email is not recoverable in the first release unless another sign-in method was linked beforehand.
- [AC-10] Given the user loses access to the verified email and another sign-in method was linked beforehand, when that method authenticates successfully, then the same hosted identity and workspace are restored without changing the verified email.
- [AC-11] Given the user loses access to the verified email and no other sign-in method was linked beforehand, when recovery is requested, then no self-service or support override grants access.
- [AC-12] Given only an existing session or another linked sign-in method is proven, when a verified-email change is attempted, then the email remains unchanged.
- [AC-13] Given the future verified-email change flow is used, when both the current email is freshly proven and the new email is verified, then the change may continue under its approved implementation contract.
- [AC-14] Given a valid hosted session exists, when its browser restarts, then the same session restores hosted access without another magic link unless it was signed out, revoked, or expired.
- [AC-15] Given the same hosted identity signs in on another device, when the new session starts, then both device sessions remain independently valid.
- [AC-16] Given the user signs out normally, when another device session is checked, then only the session that signed out is revoked.
- [AC-17] Given account settings shows active device sessions, when the user revokes one session, then that session loses hosted access and the other sessions remain valid.
- [AC-18] Given the user selects `Sign out all devices`, when revocation completes, then every active hosted session for that identity loses access.
- [AC-19] Given a session is revoked or expired, when it requests protected hosted data, then access is denied without affecting on-device projects available under the current operating-system boundary.
- [AC-20] Given a signed-in user has on-device projects on the current device, when the catalog loads, then those projects appear with hosted projects without upload, reassignment, duplication, or storage-mode change.
- [AC-21] Given distinct on-device and hosted projects link to the same repository, when the combined catalog loads, then both remain separate entries with their own storage mode and current availability.
- [AC-22] Given one stable project has been explicitly migrated or resynchronized, when the combined catalog loads, then it appears once with its authoritative storage mode.
- [AC-23] Given catalog entries refer to the same repository, when the catalog is composed, then no project merge, identity link, upload, synchronization, or storage-mode change occurs automatically.
- [AC-24] Given the user signs out, when protected views are revisited, then hosted projects require authentication while on-device projects remain available under the local OS boundary.
- [AC-25] Given a token, delivery, session, or provider failure occurs, when the flow ends, then no secret is exposed and no partial identity or workspace is created.

## Open Questions

- None.
