# Assessing A Repository On A Mac Design

## Context

`SddOrchestratorWeb.RepositoryAssessmentLive` serves two routes. Its `:device` action assesses a Git repository on the machine in front of the person, for an accountless device project, and it works. Its `:hosted` action assesses a hosted project's repository, and it gates on `active_hosted_project?/1`, which requires `match?(%{state: "connected"}, project.repository_connection)`.

`SddOrchestrator.RepositoryAssessments.authorize_project/2` carries the same requirement at the domain boundary for `{:hosted, account_id}`.

It is not two gates. Implementation found the same GitHub-shaped requirement in five places across four modules, each one refusing the project a step further along the flow: the screen's gate, the domain's `authorize_project/2`, `AssessmentStore.Hosted.put/2`, that store's `lock_project_binding/1`, and the profile store's `active_binding?/2` together with its own `lock_project_binding/1`. The two `lock_project_binding/1` functions return `nil` unless a `RepositoryConnection` row exists, so they refuse by failing to find the project at all. Fixing only the first gates moves the refusal later rather than removing it.

A hosted project whose repository is on a Mac falls between the two. It is hosted, so the device route does not serve it, and it has no `RepositoryConnection` row at all, because that row is GitHub-shaped and its repository id is a provider-issued integer such a repository never has. Both gates therefore refuse it, and the screen redirects to `/projects` with no explanation.

The consequence is not local to this screen. An approved execution profile is one of the five preconditions `specs/41-feature-delivery-from-the-ui/` requires before `Start development`, and the profile screen answers `No completed assessment with a verifiable minimized proposal envelope is available for this repository, so there is nothing to approve.` So a project created through `specs/44-hosted-local-repository-projects/` can never reach a run. That was proven by clicking, not inferred.

This is the same shape `specs/45-hosted-session-project-access/` removed from the project dashboard, where the GitHub connection presentation was keyed on the project actually having a connection rather than on its storage mode. The screen is different and the gate is an authorization rather than a presentation, but the mistaken assumption is identical: that a hosted project has a GitHub repository.

The machinery to assess a repository on a Mac already exists and is proven, because the device route uses it. What is missing is that the hosted route will not admit this project shape.

## Proposed Approach

Redefine assessability by what the screen actually needs, and change nothing else.

- A hosted project is assessable when its repository is reachable. A GitHub repository is reachable through a connected `RepositoryConnection`, which is today's rule and is unchanged. A repository on a Mac is reachable through the worker binding `specs/37-hosted-local-repository-connection/` already maintains and `specs/44-hosted-local-repository-projects/` writes at creation.
- Both gates move together. The LiveView's `active_hosted_project?/1` and the domain's `authorize_project/2` express one rule, so they are changed as one and neither becomes more permissive than the other. The domain gate stays the authority.
- Reachability of the Mac is a state the screen shows, not a reason to redirect. The screen opens for a bound project whose worker is not currently reachable, says so, and offers no start. That mirrors how `specs/41` already presents its own unmet start preconditions, and it is the opposite of the silent redirect that made this hard to find.
- The repository label reuses the wording the same screen's device route already renders for this exact fact, rather than adding a second phrasing that can drift from it.
- Nothing about the scan, the proposal, the disclosure digest, or the profile approval changes. Once such a project can be assessed, the existing path produces the proposal and the profile screen approves it.

## Components Affected

- `SddOrchestratorWeb.RepositoryAssessmentLive`: the hosted route's assessability gate, the repository label for a project whose repository is on a Mac, and the not-reachable state.
- `SddOrchestrator.RepositoryAssessments` (`authorize_project/2`): the same assessability rule at the domain boundary, and the one place that owns it.
- `SddOrchestrator.RepositoryAssessments.AssessmentStore.Hosted`: its own copy of the rule in `put/2`, and its `lock_project_binding/1`, which finds no project without a connection row.
- `SddOrchestrator.RepositoryAssessments.ProfileStore.Hosted`: `active_binding?/2` and its `lock_project_binding/1`, which block proposing and approving the profile.

## Data and Access Boundaries

- No new stored record. This slice changes which existing projects two gates admit, and what one screen renders.

Required boundaries:

- Authorization is unchanged. The acting person must still own the project, and every check that runs today still runs. Widening what counts as reachable must not widen who may act.
- A repository on a Mac is admitted only through its own worker binding. A hosted project with neither a connected GitHub connection nor a binding stays refused.
- Nothing this slice renders or stores may carry a repository path, remote, commit, file name, or source content. The label names the project, not the repository's location.
- The `:device` route and the accountless flow behind it are untouched.

## Interfaces

- `RepositoryAssessments.authorize_project/2` admitting a hosted project whose repository is on a Mac, and refusing one that is reachable by neither route.
- Compatibility that must hold: the GitHub assessment and its profile approval, the device route, the disclosure digest and the proposal envelope, and every refusal for a person who does not own the project.

## Decisions and Tradeoffs

### Assessability is reachability, not a GitHub connection

- Choice: A hosted project is assessable when its repository is reachable, by a connected GitHub connection or by a worker binding.
- Reason: The screen exists to scan a repository. Requiring a `RepositoryConnection` asked whether the repository is on GitHub, which was the same question only while GitHub was the only source. `specs/44` made it a different question.
- Consequence: Two gates now name two ways of being reachable instead of one, and a third source would add a third. That is the honest shape: the alternative is a screen that silently serves some hosted projects and not others.

### The unreachable Mac is a state, not a redirect

- Choice: The screen opens for a bound project whose Mac is not reachable, names that, and offers no start.
- Reason: The redirect is what made this defect expensive to find, and the product already prefers naming an unmet requirement: `specs/41`'s start section lists each one with the link that resolves it.
- Consequence: The screen has one more state to render and to prove. A person who cannot start still learns why, which is what the business rule asks for.

### The label is the device route's existing wording

- Choice: A repository on a Mac is named the way the same screen's device route already names one.
- Reason: The product holds no repository name for such a project, only the folder name that became the project name. One wording for one fact is this repository's rule, and a second phrasing on the hosted route would drift from the device route saying the same thing.
- Consequence: The two routes share a sentence, so changing it changes both, which is the intent.

## Risks

- Five gates in four modules can drift. They must read one predicate and be proven together, or a project will be admitted at one step and refused at the next, which is exactly the shape of the defect being fixed.
- The two `lock_project_binding/1` functions refuse by answering `nil`, which reads as a missing project rather than a refused one. Widening them must keep the provider and repository-identity checks that sit beside them, so a project is still matched to its own assessment.
- Widening an authorization gate is the kind of change that can quietly admit more than intended. The proof has to include a hosted project that is reachable by neither route, and a person who does not own the project.
- The proposal envelope and the profile approval are assumed to work once an assessment completes, because nothing in them reads a `RepositoryConnection`. That is checked by the slice, not assumed.

## Open Questions

- None.
