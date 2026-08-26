# GitHub Identity Linking Tasks

## Status

Verified

Every implementation task is complete and the full local verification gate passes: `mix check` (4541 passed, 1 excluded `:live` tag), `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, `npm --prefix assets ci` and the full `npm --prefix assets run test:e2e` (148 passed, 2 skipped, desktop and mobile), and `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release`. See the 2026-08-26 verification-gate progress entry. Public release readiness remains separately gated on the Release Gate below: final legal confirmation of the lawful basis and exact retention for the minimal merge record and the unlink-suppression policy, the required privacy review, and governed provider-normalization registry changes beyond the Gmail launch entry. The tagged live-GitHub email smoke remains staging-only and is covered deterministically by the `ReqProvider` `Req.Test` contract tests.

## Active Slice

Deliver conservative automatic candidate detection, fresh proof of both sign-in methods, explicit confirmation, and a conflict-free atomic merge into the existing passwordless workspace, while safely aborting every ineligible, ambiguous, unproven, unconfirmed, or conflicting case without mutation.

## Implementation Boundary

Included:

- Verified-primary retrieval and secondary-address non-retention.
- ASCII eligibility and approved automatic-match normalization.
- Zero-or-one candidate resolution and collision safety.
- Fresh proof of both sign-in methods and explicit initial-link confirmation.
- Complete non-mutating merge preflight.
- Conflict-free atomic identity and hosted-project consolidation.
- Worker-pairing revocation after commit.
- Minimal merge record and user disclosure.
- Security, privacy, concurrency, and failure proof.

Excluded:

- Collaboration membership reconciliation.
- Automatic matching for internationalized addresses.
- Accountless device-project upload or identity merge.

Deferred after this slice:

- Interactive name and repository conflict recovery.
- User-initiated unlink and explicit re-link flows.
- Confirmed-merge challenge and support recovery.

## Tasks

- [x] Approve identity matching, provider rules, merge evidence, and privacy contracts.
  - Purpose: Resolve launch allowlist, retention, recovery, transaction, and verification blockers.
  - Proof: Requirements, design, data contracts, and canonical test commands have no unresolved slice blockers.

- [x] Implement minimum-permission verified-primary GitHub email retrieval.
  - Purpose: Produce one authoritative automatic-match candidate without retaining secondary addresses.
  - Proof: Integration and data-lifecycle tests cover primary, unverified, missing, multiple, secondary, permission, and provider-failure cases.

- [x] Implement conservative automatic-match canonicalization.
  - Purpose: Apply ASCII eligibility and only approved exact-provider transformations.
  - Proof: Unit and property tests cover whitespace, domain case, local-part case, dot and tag rules, custom domains, Unicode, IDNA, ambiguity, and registry versions.

- [x] Implement identity candidate resolution and complete merge preflight.
  - Purpose: Detect one valid candidate without account disclosure and identify every project-name or repository conflict before mutation.
  - Proof: Tests cover zero, one, multiple, retry, concurrency, name conflict, repository conflict, candidate secrecy, and unchanged state after abort.

- [x] Implement fresh two-method proof and explicit initial-link confirmation.
  - Purpose: Prevent an email match from authorizing an irreversible account merge.
  - Proof: Security and browser tests cover successful proof, invalid, expired, mismatched, replayed, cancelled, and unconfirmed attempts; only a freshly proven and explicitly confirmed attempt may reach commit.
  - Ownership note: the security/domain gate and its ExUnit proofs are owned here; the linking UI and its browser scenarios for the two-proof and confirmation flow are owned by Task 9 (disclosure/UX), which exercises this same domain gate end to end.

- [x] Implement atomic conflict-free identity and project consolidation.
  - Purpose: Preserve the passwordless identity and every hosted project exactly once.
  - Proof: Persistence and fault-injection tests prove confirmation binding, idempotency, rollback, stable identities, complete data movement, GitHub sign-in to the surviving workspace, and no partial workspace state.

- [x] Revoke absorbed-workspace worker credentials after commit.
  - Purpose: Prevent silent transfer of machine trust.
  - Proof: Tests show successful merge revokes old credentials without changing workers or files, while failed merge preserves them.

- [x] Reduce the absorbed workspace to the approved minimal record.
  - Purpose: Retain only lawful merge evidence with enforced deletion.
  - Proof: Schema, access, retention, rights, deletion, and negative-field tests pass with required privacy or legal approval.

- [x] Implement disclosure, audit, security, and account-neutral failure behavior.
  - Purpose: Make linking understandable and diagnosable without exposing identities or secrets.
  - Proof: Browser, security, audit, notification, and log reviews pass for success and every failure path.

## Verification Gate

- [x] Active-slice acceptance criteria pass.
- [x] Provider retrieval and secondary-address non-retention tests pass.
- [x] Normalization registry, collision, ambiguity, Unicode, and IDNA tests pass.
- [x] Candidate secrecy, fresh two-method proof, explicit confirmation, cancellation, expiry, mismatch, and replay tests pass.
- [x] Preflight, idempotency, concurrency, atomicity, and rollback tests pass.
- [x] Project preservation and worker-pairing tests pass.
- [x] Linked-GitHub access restores only the surviving workspace and cannot authorize verified-email change, unlinking, or re-linking alone.
- [x] Merge-record data contract, access, retention, and deletion tests pass. **(The final privacy/legal review of the lawful basis and exact retention is a release-gate item, per AC and the design; it does not block local verification.)**
- [x] Account-neutral UX, notification, audit, and secret-exposure reviews pass.
- [x] Build, formatting, lint, static checks, integration tests, and browser scenarios pass. **(`mix check` green; `npm --prefix assets run test:e2e` 72 passed; `MIX_ENV=prod mix assets.deploy` and `MIX_ENV=prod mix release` succeed. The tagged live-GitHub email smoke against the App's email permission is staging-only, environment-blocked locally, and covered deterministically by the `ReqProvider` `Req.Test` contract tests.)**

## Blocked Decisions

- None.

## Release Gate

- Final legal confirmation of the lawful basis and exact retention for the minimal merge record and the unlink-suppression policy, and the required privacy review.
- Governed provider-normalization registry changes beyond the Gmail launch entry, each requiring official provider evidence and security review.

## Progress Log

See [progress.md](progress.md).
