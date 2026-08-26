# Project Specification Storage Progress Log

### 2026-08-26 - Verification gate re-run and slice marked Verified

- All seven implementation tasks, both provided capabilities, and every verification-gate item were already recorded complete; the slice was held at `In Progress` only by deployment-specific evidence that belongs in the release gate. Per the project rule that deployment-dependent evidence blocks release rather than implementation or local verification, that is not a `Verified` blocker. Re-ran the full gate on `main` first, because it last ran before `specs/25-` through `specs/37-` landed.
- Proof receipts, all confirmed on the main thread by real exit status:
  - `python3 .agents/scripts/run_proof.py slice -- mix check` — exit `0` (4541 passed, 6 properties, 1 excluded `:live` tag; `MIX_TEST_PARTITION=463620` passed explicitly because the runner injects it only for a bare `mix test`).
  - `python3 .agents/scripts/run_proof.py slice -- mix dialyzer` — exit `0`.
  - `python3 .agents/scripts/run_proof.py slice -- mix deps.audit` — exit `0` (no vulnerabilities).
  - `python3 .agents/scripts/run_proof.py slice -- mix sobelow --config` — exit `0`.
  - `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets ci` — exit `0`.
  - `python3 .agents/scripts/run_proof.py slice -- npm --prefix assets run test:e2e` — exit `0` (148 passed, 2 skipped, `chromium` and `mobile-chromium`).
  - `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix assets.deploy` — exit `0`.
  - `python3 .agents/scripts/run_proof.py slice -- env MIX_ENV=prod mix release --overwrite` — exit `0`.
- Validators: `python3 .agents/scripts/validate_spec.py specs/09-project-specification-storage`, `python3 .agents/scripts/validate_spec.py --all specs` (37 specifications), and `python3 .agents/scripts/split_progress_log.py --check` all pass.
- The three exceptions `specs/29-participation-completion` accepted at its own gate no longer reproduce and were not needed: `SddOrchestrator.Delivery.LocalWorkerRuntimeProjectionTest` and `SddOrchestrator.Delivery.RevocationConsumerTest` pass, and `e2e/repository-kits.spec.js` passes after dropping the stale `sdd_orchestrator_e2e_desktop` and `sdd_orchestrator_e2e_mobile` databases, which is the known non-idempotent fixed-digest kit-package seed, not a product defect.
- Failed checks: None.
- Status: `In Progress` to `Verified`.
- Corrected a stale line under `## Blocked Decisions` that still claimed `Task 2` was the next executable task; every task is complete.
- Release readiness is unchanged and remains blocked on the deployment-specific controller, processor, region, transfer, notice, retention-enforcement, incident, and final accountable privacy or legal review evidence in the release gate.
- Spec updates: `tasks.md` status and the stale blocked-decision line only. No requirement, design decision, acceptance criterion, task boundary, or verification expectation changed.

### 2026-07-28 - Slice implementation and local verification complete

- Completed: Delivered the shared hosted and device-authoritative specification store with stable specification identity, immutable complete revisions, optimistic expected-head append, consistent allowlisted snapshots, destination-local restoration transaction contributions, cross-operation idempotency and concurrency enforcement, project deletion and rights propagation, privacy inventory and field purposes, fixed redacted security outcomes, consumer compatibility, and both published capabilities.
- Verification: `mix check` passes with 557 tests (5 properties and 552 example tests) and one intentionally excluded live test. The explicit `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, `mix sobelow --config`, and `mix test` commands pass. The specification validator suite passes 38 tests; the Slice 09 validator and global nine-specification graph pass. `npm --prefix assets ci` reports no vulnerability, the final desktop and mobile Chromium matrix passes 74 tests, `MIX_ENV=prod mix assets.deploy` passes, and `MIX_ENV=prod mix release --overwrite` creates the current production release.
- Remaining: Complete the deployment privacy profile and final accountable privacy or legal review before public release. These release-stage items do not block the implemented capabilities or local verification.
- Failed checks: The first browser-matrix run passed 73 of 74 tests; the unrelated Chromium hosted-access sign-out scenario remained on the safe signed-out-required state while its mobile-Chromium equivalent passed. The exact Chromium scenario passed immediately on isolated rerun, and the complete 74-test matrix then passed. The first non-interactive `mix release` invocation found an existing local release and stopped at its overwrite prompt; `mix release --overwrite` rebuilt the current branch successfully. No implementation or verification failure remains.
- Spec updates: Checked every local verification item and recorded the separate release-stage blocker. The slice remains `In Progress` rather than `Verified` until its release gate is complete.
- Readiness: Product requirements are approved; technical design is approved; implementation is complete; local verification is complete; both shared capabilities are ready; public release is blocked only at the deployment privacy and accountable-review gate.

### 2026-07-28 - Task 5 complete: lifecycle, privacy, and consumer compatibility

- Completed: Added the specification-processing inventory and exact persisted-field purpose map; complete hosted revision-history rights export; account, hosted-project, and device-project deletion propagation; fixed outcome-only security logs that exclude identifiers and user content; programmatic 30-day operational-log and 35-day encrypted-backup release ceilings; hosted and device processor boundaries; cache, index, analytics, secondary-use, and content-redaction proof; direct Slice 06 snapshot-to-restore compatibility; and the additive Slice 07 participant-authorization policy seam. The local privacy and security review found the implementation consistent with the approved purpose, access, minimization, lifecycle, rights, processor, transfer, logging, backup, and no-secondary-use contract. Deployment-specific controller, processors, regions, transfer safeguards, notice, enforcement evidence, and final accountable review remain release gates only.
- Capability readiness: `capability:project-specification-governance` is ready after Task 5; its focused lifecycle, rights, privacy, security, and consumer-compatibility evidence is recorded here.
- Remaining: Run and record the full slice verification gate. Public release remains blocked by the deployment privacy profile named under Release gates.
- Failed checks: Dialyzer initially reported the established Elixir 1.20/OTP 29 `Ecto.Multi` opaque-`MapSet` false positive in the hosted specification module. The same narrow file-specific `call_without_opaque` suppression already documented for the repository's transaction modules was added, and Dialyzer then passed with no unsuppressed warning. Final proof passes: the focused governance suites (19 tests), relevant privacy, specification, device, and security regressions (137 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`, and `mix sobelow --config`.
- Spec updates: Marked Task 5 complete and recorded `capability:project-specification-governance` readiness; requirements, design, ownership, and dependency edges are unchanged.
- Local engineering decision: Reused the repository's narrow Dialyzer suppression for the known first-`Ecto.Multi.insert/3` opaque-`MapSet` analysis mismatch; no runtime behavior or verification requirement changed.

### 2026-07-28 - Task 8 complete: cross-operation concurrency and idempotency

- Completed: Made identical hosted and device create retries return the committed aggregate while rejecting the same stable identities with changed content or actor data. Added deterministic hosted and device races across create and restoration plus concurrent hosted append and snapshot observation, proving uniqueness, one complete current head, stale-writer rejection, replay convergence, and no duplicate or partial state.
- Capability readiness: `capability:project-specification-store` is ready after Task 8; create, append, current read, current snapshot, and destination-local restoration preparation are available to Slice 06 and Slice 07 through the shared `SpecificationStore` interface.
- Remaining: Complete lifecycle, privacy, and consumer compatibility in Task 5, record governance readiness, and run the slice verification gate.
- Failed checks: The first focused run exposed an invalid DETS lookup condition in the new device retry path; it was replaced with an exhaustive project-and-specification lookup. The combined suite also exposed the superseded Task 2 expectation that an identical committed create must fail; the regression now requires idempotent return and still rejects conflicting identity reuse. Final proof passes: the focused race suite (5 tests across 10 repeated seeds), the combined specification suite (34 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 8 complete and recorded `capability:project-specification-store` readiness; requirements, design, ownership, and dependency edges are unchanged.

### 2026-07-28 - Task 7 complete: restoration transaction participation

- Completed: Added strict shared restoration-value validation, stable input ordering and digesting, caller idempotency-key binding, hosted `Ecto.Multi` contribution, and a typed worker-owned device transaction contribution. Hosted commits preserve project, specification, and revision identities in one caller transaction; device commits preserve the specification set in one serialized batch without a hosted copy. Exact committed replays return the existing result, while malformed values, duplicate identities, conflicting state, foreign authority, changed reuse of an idempotency key, and injected failure leave no partial state.
- Remaining: Enforce cross-operation concurrency and record `capability:project-specification-store` readiness in Task 8, then complete governance and the verification gate.
- Failed checks: Strict Credo initially identified one nested callback and two complex semantic comparisons; they were simplified into a focused callback and one shared current-value comparison. Final proof passes: the focused hosted and device restoration suite (6 tests), the combined specification suite (29 tests), device transaction and registration regressions (24 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 7 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Task 4 complete: consistent current-project snapshots

- Completed: Added one strict transient `SpecificationSnapshot` allowlist, deterministic specification-id ordering, configured count and byte limits, a single joined hosted current-head query, and a worker-serialized device snapshot read. Snapshots contain only stable specification and current revision identities, titles, and the three approved documents; concurrent append proof observes either complete revision without mixing document fields.
- Remaining: Implement restoration transaction participation in Task 7, then cross-operation readiness, governance, and verification.
- Failed checks: Strict Credo initially rejected one alias ordering in the focused test; it was corrected. Final proof passes: `MIX_ENV=test mix test test/sdd_orchestrator/specifications/snapshot_test.exs` (5 tests), the combined specification suite (23 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 4 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Task 3 complete: device-authoritative specification adapter

- Completed: Extended the worker-owned `DeviceStore` contract and development DETS adapter with atomic one-record specification aggregates, device value shapes matching the shared stable specification and immutable revision contract, create, optimistic append, current retrieval, capacity enforcement, restart durability, cross-device and cross-project authorization, serialized concurrency, and idempotent retry. Device specifications never create a hosted Ecto row or cache copy.
- Remaining: Implement consistent current-project snapshots in Task 4, then restoration participation, cross-operation readiness, governance, and verification.
- Failed checks: None. Final proof passes: the shared hosted and device specification suites (18 tests), existing device-store and registration regressions (18 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 3 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Task 6 complete: hosted optimistic revision append

- Completed: Added `SpecificationStore.append_revision/5` and the hosted locked transaction that requires the expected current revision, inserts one immutable complete revision, atomically advances the current pointer and optional title, preserves the earlier revision, rejects stale or conflicting revision identities, and returns the committed revision on an identical retry.
- Remaining: Implement the device-authoritative adapter and shared contract in Task 3, then snapshots, restoration participation, cross-operation readiness, governance, and verification.
- Failed checks: Strict Credo initially rejected one alias ordering in the focused test; it was corrected. Final proof passes: `MIX_ENV=test mix test test/sdd_orchestrator/specifications/hosted_append_test.exs` (6 tests), the combined hosted suite (14 tests), `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 6 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Task 2 complete: hosted specification creation and current retrieval

- Completed: Added the hosted `ProjectSpecification` and immutable `SpecificationRevision` schemas and migration, configured document and aggregate limits, complete-document validation and stable SHA-256 digesting, fail-closed owner authorization, the shared `SpecificationStore` facade, one `Ecto.Multi` for first-revision creation and current-pointer assignment, current retrieval, and focused fixtures. The stored revision accepts hostile-looking text only as inert content and rejects extra path fields, incomplete sets, oversize data, cross-workspace access, and email actor references.
- Remaining: Implement hosted optimistic append in Task 6, then the device adapter, consistent snapshots, restoration participation, concurrency readiness, governance, and the slice verification gate.
- Failed checks: The first focused run exposed an unhandled primary-key constraint and a fixture repository collision; both were corrected. Final proof passes: `MIX_ENV=test mix test test/sdd_orchestrator/specifications/hosted_store_test.exs` (8 tests), migration rollback and reapply, `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix credo --strict`.
- Spec updates: Marked Task 2 complete; requirements, design, ownership, dependencies, and capability readiness are unchanged.

### 2026-07-28 - Provider readiness and task size reconciled

- Completed: Confirmed the Slice 05 authority and governance capabilities are ready, applied the Task Size Gate, preserved Tasks 1–5, split hosted append, restore participation, and cross-operation concurrency into Tasks 6–8, and moved the specification-store readiness boundary to Task 8.
- Remaining: Implement Tasks 2, 6, 3, 4, 7, 8, and 5 in dependency order, publish both capabilities at their named task boundaries, validate the Slice 06 and Slice 07 consumer contracts, and run the verification gate.
- Failed checks: The first global graph check rejected missing Slice 05 capability readiness write-backs; those write-backs are now explicit and the graph passes.
- Spec updates: Moved the slice from `Blocked` to `Not Started`, removed stale provider blockers, added standard size declarations with no exception, split independently provable state transitions, and changed the `capability:project-specification-store` provider from Task 4 to Task 8 without changing approved behavior.

### 2026-07-28 - Shared specification-storage foundation approved

- Completed: Extracted stable project-specification identity, immutable complete revisions, current-head updates, hosted and device adapters, consistent snapshots, and restoration transaction participation from the portability and guided-delivery consumers into one focused shared capability.
- Remaining: Complete Slice 05 Task 4 to start Tasks 2–4, complete Slice 05 Task 6 before Task 5, validate both consumer contracts, and run the verification gate.
- Failed checks: None; implementation has not started.
- Spec updates: Approved the product, technical, privacy, capability, task-sequence, and verification contracts; separated project-storage authority from governance prerequisites and project-specification store readiness from governance readiness.
