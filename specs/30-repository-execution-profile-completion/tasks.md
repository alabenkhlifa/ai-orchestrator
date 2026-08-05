# Repository Execution Profile Completion Tasks

## Status

In Progress

The product and technical agreements are approved and every required capability is ready. `specs/14-repository-execution-profile/` is `Verified` and merged, so `capability:repository-profile-review` is available. Task 4 is complete with focused proof, so `capability:repository-approved-pilot` is ready and Task 12 is the next executable task. The storage and specification-store governance prerequisites remain ready.

## Active Slice

Select one authoritative pilot and present independent readiness for an owner-reviewed repository profile, enforce the privacy, lifecycle, storage, and no-secondary-use contract, then publish one deterministic allowlisted managed-runtime capability without copying specifications or changing repository files.

## Cross-Specification Dependencies

Requires:

- `capability:repository-profile-review` — provider `specs/14-repository-execution-profile#Task 11` — required before `Task 4`.
- `capability:project-specification-store` — provider `specs/09-project-specification-storage#Task 8` — required before `Task 4`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 1`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 1`.

Provides:

- `capability:repository-approved-pilot` — ready after `Task 4`.
- `capability:repository-profile-readiness` — ready after `Task 12`.
- `capability:repository-execution-profile` — ready after `Task 2`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- All four tasks are standard, each owns one independently provable pilot, readiness, governance, or publication outcome and has focused proof expected to run in about ten minutes.
- The slice contains four tasks and its longest `Depends on:` path contains four tasks: Task 4, Task 12, Task 1, then Task 2.
- No exception is required.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- One current authoritative specification and revision pilot reference with owner-only selection, participant read access, and no specification copy or backlog import.
- Independent assistant, specification, agent-execution, and release readiness with stable reason codes, earliest blocked stage, stale-state checks, conflict and multi-root behavior, and reliable required-check enforcement.
- Hosted and device-authoritative privacy, security, access, lifecycle, processor, transfer, logging, backup, analytics, and secondary-use controls for Slice 14 values.
- Worker-local cache and raw-index locality enforcement.
- Deterministic allowlisted managed-runtime profile serialization, digest, compatibility proof, and final capability publication.

Excluded:

- Repository scanning, cache-key behavior, assessment-result creation, proposal-payload derivation or caching, current-assessment envelope generation or persistence, and profile proposal, review or approval behavior owned by Slice 14.
- Slice 07 manifest changes, managed-run execution, repository mutation, kit installation, backlog import, deployment, merge, or release execution.

Deferred after this slice:

- Slice 07 `update-spec` work that consumes `capability:repository-execution-profile` before a managed run.
- Permanent repository integration through `specs/15-repository-sdd-kit-integration/`.

Release gates:

- Live configured worker smoke proof for each supported deployment profile.
- Deployment-specific controller, processor, model, worker, region, transfer, notice, retention-enforcement, incident, and accountable privacy or legal evidence.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 4 — Select one authoritative pilot specification revision.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Bound adoption to one current authoritative Orchestrator feature without copying specifications or importing repository backlog items.
  - Owned surfaces: Profile-review capability consumer, shared-store specification and current revision selector, owner-only pilot selection, stable pilot reference, stale-revision refusal, no specification-document copy, no repository issue or backlog import, hosted and device-authoritative persistence parity, participant read-only access, focused LiveView interaction, `capability:repository-approved-pilot` provider, and readiness write-back.
  - Owns: AC-10
  - Proof: Focused profile-review and specification-store consumers, current and stale revision, owner, participant read-only, hosted/device adapter, stable-reference, no-copy, no-import, LiveView, and browser tests pass.

- [ ] Task 12 — Present independent repository readiness and verification blockers.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 4
  - Purpose: Explain separately what the assistant, specification workflow, autonomous agent, and release may safely do without inventing a reliable check contract.
  - Owned surfaces: Profile-review capability consumer, assistant, specification, agent-execution and release readiness value and UI, earliest blocking stage and actionable reason codes, stale commit and changed-root behavior, unresolved instruction and safety conflict behavior, unsupported multi-root behavior, reliable required-check contract gate, verified-completion and `Ready for review` denial, read-only assistant independence, participant read-only access, `capability:repository-profile-readiness` provider, and readiness write-back.
  - Owns: AC-08, AC-09, AC-11
  - Proof: Focused profile-review consumer, stale-commit, changed-root, conflict, safety-conflict, multi-root, missing and unreliable check, assistant independence, participant read-only, earliest-stage reason, LiveView, and browser tests pass.

- [ ] Task 1 — Enforce privacy, lifecycle, and storage-boundary controls.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 12
  - Purpose: Keep every assessment, worker-local proposal-payload, proposal-envelope, cache, profile, pilot, readiness, and disclosure value inside its approved purpose, authority, access, and lifecycle boundary.
  - Owned surfaces: Processing inventory and field-purpose map, hosted and device-authoritative parity, project and role access, raw-source, index and proposal-payload locality, minimized result and current-assessment proposal-envelope allowlists, worker-cache lifecycle, changed-boundary records, retention, project and account deletion, rights behavior, backup expiry, structured log redaction, processor and transfer controls, analytics absence, secondary-use prohibition, and no durable hosted copy for device-authoritative data.
  - Owns: AC-01
  - Proof: Focused inventory, field-purpose, hosted/device parity, project isolation, role access, raw-content and index negative, cache lifecycle, deletion, retention, rights, backup, log-redaction, processor, transfer, no-hosted-copy, no-analytics, and no-secondary-use tests pass.

- [ ] Task 2 — Publish the deterministic execution-profile capability.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Give separately approved managed-runtime consumers one exact allowlisted profile and pilot reference only after all required local proof succeeds.
  - Owned surfaces: Managed-runtime profile value, exact recursive allowlist, immutable profile and readiness version binding, authoritative pilot specification and revision reference, versioned runtime-skill references, deterministic serialization and digest, stale and unknown-field refusal, no-specification-copy fixture, no-repository-mutation fixture, downstream compatibility fixture, implementation, local-verification and release readiness write-back, `capability:repository-execution-profile` provider, and final readiness publication after slice receipts.
  - Owns: AC-02
  - Proof: Focused allowlist, deterministic serialization, digest, immutable-version, stale-profile, stale-revision, unknown-field, specification-reference, runtime-skill, no-copy, no-repository-write, staged-readiness, gated-publication, and downstream compatibility tests pass.

## Verification Gate

- [x] Slice 14 `capability:repository-profile-review` is complete with matching focused proof and readiness write-back.
- [ ] AC-01, AC-02, and AC-08 through AC-11 pass in their applicable hosted and device-authoritative modes.
- [ ] Pilot-selection, stale-revision, no-copy, no-import, four-axis readiness, conflict, multi-root, missing-check, participant-read, and browser scenarios pass.
- [ ] Privacy inventory, access, lifecycle, deletion, rights, processor, transfer, redaction, cache-locality, no-analytics, and no-secondary-use suites pass.
- [ ] Managed-runtime allowlist, serialization, digest, specification-reference, runtime-skill, no-copy, no-repository-mutation, and downstream compatibility suites pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix check` passes.
- [ ] `python3 .agents/scripts/run_proof.py slice -- mix format --check-formatted`, `python3 .agents/scripts/run_proof.py slice -- mix compile --warnings-as-errors`, `python3 .agents/scripts/run_proof.py slice -- mix credo --strict`, `python3 .agents/scripts/run_proof.py slice -- mix dialyzer`, `python3 .agents/scripts/run_proof.py slice -- mix deps.audit`, `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config`, and `python3 .agents/scripts/run_proof.py slice -- mix test` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` and `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` pass.
- [ ] `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` and `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release` pass.
- [ ] Individual specification validation and the global capability graph pass.
- [ ] Implementation, local-verification, and release readiness are recorded separately; deployment-only evidence remains in the release gate.
- [ ] `capability:repository-execution-profile` is published exactly once only after every deterministic gate receipt is recorded.

## Blocked Decisions

- None. Every required capability is ready, so Task 4 is executable and the remaining tasks follow their `Depends on:` order. Deployment-specific evidence stays in the release gate and blocks release only.

## Progress Log

See [progress.md](progress.md).
