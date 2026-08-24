# Guided Delivery Operational Retention Progress Log

### 2026-08-24 — Task plan reconciled with the authoritative processing inventory; slice unblocked

- Status transition: `Blocked` to `Not Started`. All three required capabilities are ready — `project-storage-governance`, `guided-delivery-data-surfaces`, and `guided-delivery-processing-controls` — so the recorded blocker and Task 1's `Blocked until` line no longer applied and were cleared.
- Implementation preflight found the plan disagreed with `specs/18-guided-delivery-data-protection-controls`' processing inventory, which is the authoritative classification of what this specification's lifecycle owns. Two problems, both confirmed in the code before any change: AC-01 promised deletion of "provider-thread references" and "transient logs", neither of which is a record — the provider-thread reference exists only in the worker's local run state (`lib/sdd_orchestrator/worker/run_state.ex:39`), and there is no transient-log entity at all, that content being carried by `run_command.result`/`failure_code` and `text/plain` evidence artifacts. Meanwhile `preview_deployment` and `run_attempt`'s three lease fields are tagged `:specs_19_operational_retention` in the inventory (`lib/sdd_orchestrator/privacy/delivery_processing_inventory.ex:160,203,207,211`) but were owned by no task here.
- Accepted decisions: retarget both categories to the records that actually hold them rather than inventing entities to delete, and own preview deployments and the lease-field clearing in this slice as the inventory already says. The privacy commitment is unchanged; only the records it is expressed against are now real. Recorded as a design decision, not left in conversation.
- Task plan restructured from five tasks to nine. The hosted rule (Task 1), the device rule (Task 6), and the worker-local rule (Task 7) are separate because a row delete, a tombstone commit, and a local file rewrite fail and are proved independently. New Tasks 8 and 9 own preview-deployment expiry and attempt-lease clearing. Slice size stays `Standard`: nine tasks, longest `Depends on:` path four (`Task 1 → Task 2 → Task 3 → Task 5`).
- New criteria AC-06 through AC-09 added with stable IDs; AC-01 narrowed to the hosted command and checkpoint case it can actually prove. No criterion was weakened to fit the code.
- Design records two mechanisms discovered in preflight: retention now follows the records that exist rather than the category names, and Task 3 gains a durable `RetentionRuleOutcome` record because the existing shared pruner returns in-memory counts only, so an interrupted or failing rule is currently invisible and its restart and reconciliation behaviour is unprovable.
- Failed checks: None. `validate_spec.py specs/19-guided-delivery-operational-retention`, `validate_spec.py --all specs`, and `split_progress_log.py --check` all pass, confirmed by real exit status.
- Proof receipts: None. No implementation was performed; this is a specification change only.
- Spec updates: `requirements.md` in-scope, business rules, AC-01 and new AC-06 through AC-09; `design.md` context, components, the `RetentionRuleOutcome` entity, interfaces, two new decisions and three new risks; `tasks.md` status, slice-size justification, task-size reasoning, implementation boundary, the nine-task plan, verification gate, and cleared blocker; this entry.

### 2026-08-02 — Focused child specification created

- Completed: Moved unfinished temporary execution-data and security-log retention out of the Slice 07 umbrella without changing approved lifecycle behavior.
- Remaining: Publish the data-surface and processing-control capabilities, then implement Tasks 1 through 5 and the verification gate.
- Failed checks: None. The individual specification validator and global capability graph pass; implementation has not started because required provider capabilities are unavailable.
- Proof receipts: None.
- Spec updates: Added focused ownership for temporary data, artifact expiry, retention reconciliation, structured security logs, and log expiry.
