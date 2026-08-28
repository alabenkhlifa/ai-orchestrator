# Feature Delivery From The Product UI

## Status

Draft

## Outcome

From a hosted project's own pages, a person can create a feature, write what it should do in a guided form, see what is still missing, make it ready, press `Start development`, and watch the run begin on this Mac's worker. Every step is a click in the product. Today each of those steps exists only as a domain function that tests and the browser-suite seed call directly, and the feature page dead-ends after the boundary confirmation with the sentence `Start development when you're ready.` and no control.

## Users

- Project owner: a signed-in person who owns a hosted project whose repository is a local Git repository connected to this Mac's worker. Not assumed to be comfortable with a terminal.
- Project participant: a person the owner invited with a content role. Writes requirements and starts development on the owner's behalf, as `specs/07-guided-specification-delivery/` already allows.
- Local worker and coding agent: the paired worker app on this Mac and the coding agent it was set up with, which begin the run.

## In Scope

- A specification created with each feature and linked to it, so the feature has somewhere to hold what it should do.
- A guided requirements form on the feature page with four parts: the outcome, who it is for, the rules that must hold, and how you will know it works. Saving stores a new revision of the feature's specification.
- Readiness on the feature page: each empty part is a blocking finding; when a guidance model is configured its findings apply on top; suggestions can be dismissed; a feature with no open blocker can be made ready; a ready feature can go back to draft.
- A `Start development` action on the feature page that names every unmet precondition with a way to resolve it, and starts the run when all are met.
- The beginning of the run made visible: the feature moves to `In development`, and the page shows that the worker acknowledged the run and its first progress.
- The run's execution manifest derived from the project's approved execution profile, including its assessed base revision, instead of from test configuration.

## Out of Scope

- A feature board for accountless device projects. This slice serves hosted projects; the device board is its own follow-on.
- A separate specifications page, and editing the design or tasks documents by hand. They are created as empty placeholders with the feature and are the coding agent's to fill.
- A working AI guidance model. The guidance adapter contract stays as it is; when none is configured, readiness is structural only and the page says so.
- Everything after the run begins: progress, blocking questions, retries, evidence, review, and preview, which `specs/07-guided-specification-delivery/` and `specs/33-local-worker-run-execution/` already deliver.
- Pilot selection (`specs/30-repository-execution-profile-completion/`). Start needs the approved execution profile, not a pilot.
- Connecting the project to a worker, owned by `specs/37-hosted-local-repository-connection/` and `specs/40-worker-repository-selection/`.

## Primary Workflow

1. The owner opens a hosted project that is connected to this Mac's worker and has an approved execution profile, opens `Features`, and creates a feature by title. The feature's own specification is created with it and linked to it.
2. The feature page shows the guided requirements form. The person fills the four parts and saves. Each save stores a new revision of the feature's specification.
3. The readiness section lists what is still missing. An empty part is blocking. When a guidance model is configured, its findings appear too, blocking or as suggestions. The person resolves blockers by editing and may dismiss a suggestion.
4. With no open blocker, the person makes the feature ready. It moves to `Ready for development`. Editing the requirements again after that marks the readiness stale until it is checked again.
5. The start section shows where the run will execute (this Mac's worker and its coding agent), the AI connection it will use when one is set, and whether project content leaves its store. The person confirms that boundary. The section names any unmet precondition: not ready, boundary not confirmed, no approved execution profile, no connected worker, or an AI connection to choose, each with a link to resolve it.
6. When every precondition is met, the person presses `Start development`. One run is created, the feature moves to `In development`, and the page shows that the worker acknowledged the run and its first progress.
7. If the start is refused, nothing changes and the reason is shown.

## Business Rules

- Every feature has exactly one specification of its own, created with the feature and linked through the link `specs/35-guided-delivery-feature-specification-link/` defines. Readiness and start read the feature's linked specification and never another specification of the project.
- A saved requirements form is a new immutable revision. A readiness verdict is bound to the revision it judged. A newer revision makes the previous verdict stale, and a stale verdict never allows making ready or starting.
- A blocking finding is any empty guided part, or a guidance finding the model marks blocking. Suggestions may be dismissed; blockers may not. Making ready requires a current verdict with no open blocker.
- Owner and participant may write requirements, dismiss suggestions, make ready, return to draft, confirm the boundary, and start. No new owner-only action is introduced.
- Start requires all of: the feature is ready with a current verdict, the boundary is confirmed for the current configuration, the project has an approved execution profile, the project is connected to a worker that is attached now, and when more than one active AI connection could govern the run, one has been chosen. Each missing item is named. Nothing is substituted silently, and a missing item is never skipped.
- The run's manifest takes its required checks, commands, allowed scope, root, and base revision from the approved execution profile. No manifest value comes from test or seed configuration.
- Starting creates exactly one run for the feature and moves it to `In development` in the same transaction, as `specs/07-guided-specification-delivery/` already defines. A second start while a run is live is refused.
- Starting never changes repository content in place; the worker works on its isolated branch under `specs/33-local-worker-run-execution/`.
- The board keeps no column control. A feature moves only through the actions on its own page.
- Copy states what the control plane knows. The page never claims a model judged the feature when no model is configured.

## Acceptance Criteria

- [AC-01] Given a hosted project, when a person creates a feature by title, then a specification of its own exists, is linked to it, and the feature page shows the empty guided form with its four parts.
- [AC-02] Given the guided form, when the person saves it, then a new revision of the feature's specification holds the four parts and the form shows them back on the next visit.
- [AC-03] Given a saved revision, when readiness is checked, then each still-empty part is a blocking finding and none remains when all are filled; given a configured guidance model, then its blocking findings block and its suggestions can be dismissed; given no configured model, then the page says no guidance model is configured.
- [AC-04] Given a current verdict with no open blocker, when the person makes the feature ready, then it moves to `Ready for development`; given an open blocker, then it is refused and the blocker is named.
- [AC-05] Given a ready feature, when its requirements are saved again, then the verdict is stale, `Start development` is not offered until readiness is checked again, and the person can return the feature to draft.
- [AC-06] Given a ready feature with any unmet start precondition, when the person opens the start section, then each unmet item is named with a link to resolve it and `Start development` is not offered.
- [AC-07] Given every precondition met, when the person presses `Start development`, then one run is created, the feature is `In development`, and the page shows the worker's acknowledgement and first progress from this Mac.
- [AC-08] Given a start that is refused, including a worker that detached between the check and the press, when the press happens, then no run exists, the feature column is unchanged, and the reason is shown.
- [AC-09] Given a started run, when its manifest is inspected, then its required checks, commands, allowed scope, root, and base revision come from the approved execution profile, with no value from test or seed configuration.
- [AC-10] Given an invited participant, when they write requirements, make the feature ready, and start it, then each action succeeds as for the owner; given a person who is not a member, then none of these pages or actions is reachable.

## Open Questions

- None.
