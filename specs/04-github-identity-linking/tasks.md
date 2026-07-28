# GitHub Identity Linking Tasks

## Status

In Progress

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

- [ ] Implement identity candidate resolution and complete merge preflight.
  - Purpose: Detect one valid candidate without account disclosure and identify every project-name or repository conflict before mutation.
  - Proof: Tests cover zero, one, multiple, retry, concurrency, name conflict, repository conflict, candidate secrecy, and unchanged state after abort.

- [ ] Implement fresh two-method proof and explicit initial-link confirmation.
  - Purpose: Prevent an email match from authorizing an irreversible account merge.
  - Proof: Security and browser tests cover successful proof, invalid, expired, mismatched, replayed, cancelled, and unconfirmed attempts; only a freshly proven and explicitly confirmed attempt may reach commit.

- [ ] Implement atomic conflict-free identity and project consolidation.
  - Purpose: Preserve the passwordless identity and every hosted project exactly once.
  - Proof: Persistence and fault-injection tests prove confirmation binding, idempotency, rollback, stable identities, complete data movement, GitHub sign-in to the surviving workspace, and no partial workspace state.

- [ ] Revoke absorbed-workspace worker credentials after commit.
  - Purpose: Prevent silent transfer of machine trust.
  - Proof: Tests show successful merge revokes old credentials without changing workers or files, while failed merge preserves them.

- [ ] Reduce the absorbed workspace to the approved minimal record.
  - Purpose: Retain only lawful merge evidence with enforced deletion.
  - Proof: Schema, access, retention, rights, deletion, and negative-field tests pass with required privacy or legal approval.

- [ ] Implement disclosure, audit, security, and account-neutral failure behavior.
  - Purpose: Make linking understandable and diagnosable without exposing identities or secrets.
  - Proof: Browser, security, audit, notification, and log reviews pass for success and every failure path.

## Verification Gate

- [ ] Active-slice acceptance criteria pass.
- [ ] Provider retrieval and secondary-address non-retention tests pass.
- [ ] Normalization registry, collision, ambiguity, Unicode, and IDNA tests pass.
- [ ] Candidate secrecy, fresh two-method proof, explicit confirmation, cancellation, expiry, mismatch, and replay tests pass.
- [ ] Preflight, idempotency, concurrency, atomicity, and rollback tests pass.
- [ ] Project preservation and worker-pairing tests pass.
- [ ] Linked-GitHub access restores only the surviving workspace and cannot authorize verified-email change, unlinking, or re-linking alone.
- [ ] Merge-record data contract, access, retention, deletion, and privacy review pass.
- [ ] Account-neutral UX, notification, audit, and secret-exposure reviews pass.
- [ ] Build, formatting, lint, static checks, integration tests, and browser scenarios pass.

## Blocked Decisions

- None.

## Release Gate

- Final legal confirmation of the lawful basis and exact retention for the minimal merge record and the unlink-suppression policy, and the required privacy review.
- Governed provider-normalization registry changes beyond the Gmail launch entry, each requiring official provider evidence and security review.

## Progress Log

### 2026-07-23 - Extracted from project onboarding

- Completed: Kept automatic matching as non-mutating candidate detection and required fresh proof of both sign-in methods, complete preflight, and explicit confirmation before the initial atomic merge.
- Remaining: Resolve confirmed-merge recovery, no-primary re-link behavior, launch provider rules, privacy approvals, transaction architecture, and verification.
- Failed checks: None; implementation has not started.
- Spec updates: Replaced automatic merge with explicit proven linking across workflow, boundaries, proof, tasks, and blockers while preserving the minimal post-merge record.

### 2026-07-27 - Product forks resolved and design unblocked

- Completed: Resolved the two product forks — a disputed confirmed merge is support-assisted only, and explicit re-link may proceed with no verified primary GitHub email — and recorded the launch provider-normalization registry and governance, GitHub permission scope, merge transaction and idempotency mechanism, notification and audit behavior, verification strategy, and the merge-record and unlink-policy data contract in `design.md`.
- Remaining: Implement the slice on the approved contracts; complete the release-gate final privacy or legal review and any governed registry additions.
- Failed checks: None; implementation has not started.
- Spec updates: Moved requirements from `Draft` to `Approved`, cleared the product, technical-design, and privacy blockers, replaced `Blocked Decisions` with a `Release Gate`, and moved tasks from `Blocked` to `Not Started`.

### 2026-07-28 - Slice implementation started; approval gate confirmed

- Completed: Task 1. Readiness preflight confirmed the approval gate has no unresolved slice blockers: requirements `Approved` with no open questions, design decisions and the merge-record and unlink-policy data contract recorded, `Blocked Decisions: None`, and `validate_spec.py` passing. Foundation slices 01/02/03 have their implementation tasks complete, so the GitHub identity, passwordless magic-link proof, personal workspace, project, worker-pairing, and repository-connection surfaces this slice builds on exist in the baseline. Created branch `slice/04-github-identity-linking` from up-to-date `main`.
- Remaining: Tasks 2-9 (verified-primary retrieval, canonicalization, candidate resolution and preflight, two-method proof and confirmation, atomic consolidation, worker-credential revocation, minimal merge record, disclosure and audit) and the verification gate.
- Failed checks: None. Environment ready: Elixir 1.20.2/OTP 29, Postgres 17 healthy on 5433.
- Spec updates: Status `Not Started` to `In Progress`; checked Task 1.
- Release gate: Unchanged — final legal confirmation of lawful basis and exact retention plus the privacy review, and governed provider-registry additions beyond the Gmail launch entry, remain release-gate items and do not block implementation or local verification.

### 2026-07-28 - Task 2: verified-primary email retrieval

- Completed: Task 2. Added a `get_verified_primary_email/1` provider callback that resolves at most one primary-and-verified address inside the adapter, with the real `ReqProvider` reading `GET /user/emails` (filters primary && verified, fails closed to `:none` on missing, unverified, or more-than-one primary; 403/404 → `:none`; 401 → error) and the deterministic `FakeProvider` modelling every case. Added `GitHubIntegration.verified_primary_email/1`, which passes through `{:ok, email}` / `{:ok, :none}` and normalizes provider read failures to `{:error, :provider_failure}`. Recorded the approved minimum email permission (`approved_email_permission: %{"email" => "read"}`).
- Non-retention: secondary addresses are reduced away inside the adapter and never returned, so no caller can retain or disclose them; proven at the adapter (raw list → only the primary) and context (single-binary return, never a secondary) levels.
- Proof: `mix test test/sdd_orchestrator/github_integration_test.exs test/sdd_orchestrator/github_integration/req_provider_test.exs` — 38 passed, exit 0. Covers primary, unverified, missing, multiple, secondary, permission, and provider-failure. `mix compile --warnings-as-errors` clean.
- Failed checks: None.

### 2026-07-28 - Task 3: conservative automatic-match canonicalization

- Completed: Task 3. Added `IdentityLinking.EmailMatch.comparison_key/1` and `match?/2` implementing the pipeline in business-rule order: trim and structural validation (internal whitespace rejected), ASCII eligibility for both parts, `xn--` IDNA label exclusion (case-insensitive), base normalization (lowercase domain, preserve local case), then approved exact-provider rules applied in the canonical order case-fold → dot-removal → `+tag`-stripping. Added the versioned `IdentityLinking.ProviderRegistry` whose launch entry is Gmail personal only (`gmail.com`, `googlemail.com`) with cited evidence and account-type scope; every other domain, including Google Workspace and custom domains, gets no alias rules. The key is comparison-only and never rewrites a stored verified address.
- Engineering mechanism: the registry lives in code as the single source of truth so a change is a reviewed code change with a version bump, matching the governance decision; no runtime config indirection was added.
- Dependency: added `{:stream_data, "~> 1.1", only: [:dev, :test]}` (design-approved verification tool) for the normalization/eligibility property tests.
- Proof: `mix test test/sdd_orchestrator/identity_linking/` — 24 passed (5 properties, 19 unit), exit 0. Covers whitespace, domain case, local-part case, Gmail dot/tag/case, custom-domain fail-closed, Unicode, IDNA, the ambiguity collision mechanism, and registry versions. `mix compile --warnings-as-errors` clean.
- Failed checks: None.
