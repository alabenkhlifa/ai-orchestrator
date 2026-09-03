# Assessing A Repository On A Mac Progress Log

### 2026-09-03 - Specification created after a delivered project could not reach a run

- Found by driving `specs/41-feature-delivery-from-the-ui/`'s release proof in a real browser, on a hosted project created by clicking through `specs/44-hosted-local-repository-projects/` and reached through `specs/45-hosted-session-project-access/`.
- Four of the five start preconditions were met by clicking: `ready`, `boundary`, `worker`, and `ai_connection`. The fifth reported `This project has no approved execution profile. Assess the repository, then approve one.`, the profile screen answered `No completed assessment with a verifiable minimized proposal envelope is available for this repository, so there is nothing to approve.`, and the assessment screen redirected away with no explanation.
- Root cause confirmed in code rather than inferred, and it sits in two places. `RepositoryAssessmentLive`'s `active_hosted_project?/1` and `RepositoryAssessments.authorize_project/2` both require `match?(%{state: "connected"}, project.repository_connection)`. A hosted project whose repository is on a Mac has no such row at all, because that row is GitHub-shaped and its repository id is a provider-issued integer such a repository never has.
- It is not a session problem and not caused by the two slices just merged. The same screen refuses a GitHub-signed-in owner of such a project in exactly the same way.
- The machinery already exists. The same screen's `:device` route assesses a Git repository on the machine in front of the person and works, so what is missing is only that the hosted route will not admit this project shape.
- Product decisions taken with the user: the screen names such a repository by reusing the device route's existing wording rather than adding a second phrasing for one fact, and an unreachable Mac is a state the screen shows with no start offered rather than a redirect. The redirect is what made this defect expensive to find.
- Engineering decisions recorded in `design.md`: assessability is redefined as reachability, satisfied by a connected GitHub connection or by a worker binding, and the two gates are changed as one so the screen and the domain cannot disagree about who may assess.
- Scope: classified `focused specification`. One outcome, one workflow, one verification gate, three tasks, longest `Depends on:` path of three. `Task 1` records a size exception because the two gates are one authorization rule.
- Consequence: `specs/41-feature-delivery-from-the-ui/`'s release gate stays open on this. Its remaining click path is add a feature, press `Start development`, and see the worker acknowledge, and the feature and its other four preconditions are already reachable.
- No code changed in this update.
