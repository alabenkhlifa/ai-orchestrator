# Repository Execution Profile Completion Tasks

## Status

Blocked

The product and technical agreements are approved. Task 1 is blocked until Slice 14 publishes both the approved-pilot and independent-readiness capabilities. The storage and specification governance prerequisites are already ready.

## Active Slice

Enforce the privacy, lifecycle, storage, and no-secondary-use contract over the completed repository assessment and profile workflow, then publish one deterministic allowlisted managed-runtime capability without copying specifications or changing repository files.

## Cross-Specification Dependencies

Requires:

- `capability:repository-approved-pilot` — provider `specs/14-repository-execution-profile#Task 4` — required before `Task 1`.
- `capability:repository-profile-readiness` — provider `specs/14-repository-execution-profile#Task 12` — required before `Task 1`.
- `capability:project-storage-governance` — provider `specs/05-project-storage-lifecycle#Task 6` — required before `Task 1`.
- `capability:project-specification-governance` — provider `specs/09-project-specification-storage#Task 5` — required before `Task 1`.

Provides:

- `capability:repository-execution-profile` — ready after `Task 2`.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Both tasks are standard, each owns one independently provable governance or publication invariant, has no new data entity, and has focused proof expected to run in about ten minutes.
- The slice contains two tasks and its longest `Depends on:` path contains two tasks.
- No exception is required.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- Hosted and device-authoritative privacy, security, access, lifecycle, processor, transfer, logging, backup, analytics, and secondary-use controls for Slice 14 values.
- Worker-local cache and raw-index locality enforcement.
- Deterministic allowlisted managed-runtime profile serialization, digest, compatibility proof, and final capability publication.

Excluded:

- Repository scanning, cache-key behavior, assessment-result creation, profile proposal or approval, pilot selection, and readiness behavior owned by Slice 14.
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

- [ ] Task 1 — Enforce privacy, lifecycle, and storage-boundary controls.
  - Status: Blocked until both Slice 14 capabilities named for Task 1 are ready.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Keep every assessment, cache, profile, pilot, readiness, and disclosure value inside its approved purpose, authority, access, and lifecycle boundary.
  - Owned surfaces: Processing inventory and field-purpose map, hosted and device-authoritative parity, project and role access, raw-source and index locality, minimized result allowlist, worker-cache lifecycle, changed-boundary records, retention, project and account deletion, rights behavior, backup expiry, structured log redaction, processor and transfer controls, analytics absence, secondary-use prohibition, and no durable hosted copy for device-authoritative data.
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

- [ ] Both Slice 14 capability providers are complete with matching focused proof and readiness write-back.
- [ ] AC-01 and AC-02 pass in hosted and device-authoritative modes.
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

- Task 1 is implementation-blocked on `capability:repository-approved-pilot` and `capability:repository-profile-readiness`; no product or technical decision is unresolved.

## Progress Log

### 2026-08-03 - Focused completion continuation approved

- Completed: Moved independently verifiable privacy and lifecycle enforcement plus final managed-runtime serialization and capability publication out of oversized Slice 14 work. Preserved Slice 14 authority for assessment, cache, profile, pilot, and readiness behavior and changed downstream provider edges to this final completion task.
- Scope classification: Focused standard completion specification with two tasks and a two-task critical path.
- Remaining: Wait for both Slice 14 capabilities, implement Task 1 and Task 2 with focused proof and task-boundary commits, run the full slice verification gate, and publish final readiness.
- Failed checks: None. The slice begins blocked only on unavailable implementation capabilities; deployment-specific evidence remains release-blocked.
- Spec updates: Created the approved requirements, design, capability edges, task ownership, proof scope, traceability, verification gate, and release boundary without implementing application code.
