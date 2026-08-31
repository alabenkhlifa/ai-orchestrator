# Feature Delivery From The Product UI Progress Log

### 2026-08-31 - Task 1 complete: a feature owns its specification from creation

- `Features.create/3` runs one `Repo.transaction`: it validates the title, resolves the project owner's `PersonalWorkspace` from the project, creates the specification through `SpecificationStore.create/4` under that authority with the acting person as the revision actor, inserts the feature, then links it. A refused specification rolls the whole thing back, so no feature is left behind.
- The empty requirements document is built at runtime from `Readiness.guided_structure/0`, so the four headings cannot drift from the structure readiness judges: `## The outcome`, `## Who it is for`, `## Rules that must hold`, `## How you will know it works`. Design and tasks documents are placeholders stating they belong to the coding agent.
- `Repo.transaction` was chosen over `Ecto.Multi` because the Multi form trips the known `Ecto.Multi` plus MapSet `call_without_opaque` dialyzer false positive, which would have needed an entry in the shared `.dialyzer_ignore.exs`.
- `@spec` for `create/3` widened to `{:error, atom() | Ecto.Changeset.t()}` to match `SpecificationStore`'s own refusals now surfacing through it.
- Rollback proved on the nested path too: `SpecificationStore.create/4` opens its own transaction, so the test forces a failure inside it and asserts a real `{:error, %Ecto.Changeset{}}` rather than `{:error, :rollback}`, with the feature count unchanged.
- Proof receipt: `Task 1` — scope `Focused` — command `mix test test/sdd_orchestrator/delivery/feature_specification_creation_test.exs test/sdd_orchestrator/delivery/feature_lifecycle_test.exs` — exit `0`.
- Confirmed on the main thread by real exit status. 19 tests passed.

### 2026-08-28 - Specification created after tracing the core loop to no UI

- Found by clicking through `http://localhost:4000` and grepping callers: `Delivery.Start.start/4` has no caller under `lib/`, `Features.transition/5` is called only by the browser-suite bootstrap, `FeatureBoardLive` has one event, `FeatureDetailLive` dead-ends at `Start development when you're ready.` with no control, `Readiness` is never called from the web layer, and no LiveView creates or revises a specification. Slice 07 is `Verified` on proofs that drive domain functions and `/_e2e/session` seeding.
- Diagnosis: a feature holds no text; readiness judges the project's first specification rather than one tied to the feature; `Start` builds its manifest from `:delivery_execution`, which only the bootstrap sets; the readiness guidance adapter is `Unconfigured` everywhere; a Mac-paired worker joins no project run topic, so `deliver/1` would find no worker.
- Product decisions taken with the user: each feature owns its specification; a structural check gates readiness and a configured model adds findings on top; `Start development` requires an approved execution profile; the hosted local-repository project is the first target and the accountless board is deferred.
- Engineering decisions recorded in `design.md`: the four-part guided document with fixed headings; structural findings merged with adapter findings and a not-configured flag; the manifest from the approved profile with `:delivery_execution` removed; `project_bound` over the Mac-scoped attachment with an on-demand project topic join; the preconditions readout shared with the start check.
- Scope: classified `focused specification`. One outcome, one workflow, one verification gate, nine tasks, longest `Depends on:` path of seven. `Task 6` and `Task 7` are blocked until `specs/40` and `specs/39` deliver their capabilities; `Task 1` through `Task 5` are executable now.
- No code changed in this update.
