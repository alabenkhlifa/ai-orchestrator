# Hosted Projects From A Local Repository Design

## Context

The storage step already offers both modes for a local repository and refuses one of them. `LocalOnboardingLive` handles the confirmed attempt, matches `%{storage_mode: "hosted"}`, and answers a flash reading `Saving local projects to a hosted account is coming soon. On-device projects are ready now.` Its own comment records the reason: hosted storage for accountless local projects belongs to the atomic-registration task, and nothing is created there yet. The device branch beside it calls `Devices.register_project/2` and routes to `/local/projects/:id`.

`specs/05-project-storage-lifecycle/` is `Verified` and its AC-06 and AC-07 already require that choosing hosted storage creates a project under an authorized identity, with the project, repository connection, and exactly one authoritative storage mode committing together. Its business rule says repository source does not restrict project-data storage, and it defers nothing. Its release boundary expects both source-owned onboarding integrations to pass; the local one never landed. `specs/02-local-project-onboarding/` is `Verified` and its Task 7 delivered only the accountless branch of the same step.

The pieces this needs are already built. `ProjectOnboardingAttempt` carries `origin_kind`, and for a device-origin attempt it also carries `hosted_prerequisite_workspace_id`, described in the schema as the hosted workspace proven by a verified sign-in on that attempt. That is the hook `specs/05`'s AC-14 sign-in handoff already writes. `Projects.register_project/3` takes a `%PersonalWorkspace{}` and an attempt and commits a hosted project with its repository connection and storage mode, and it already refuses a `device` storage mode rather than guessing. `HostedLocalRepositoryBindings.put_validated_binding/6` commits a validated worker binding, and `PortableRepositoryIdentity` is the value the worker generated when it proved the folder.

`HostedLocalRepositoryConnection.connect/6` accepts only a project that is `storage_mode: "hosted"` and `repository_provider: "local"`, which is the combination nothing creates. `specs/41-feature-delivery-from-the-ui/`'s start path requires a worker bound to the project, so its AC-07 and AC-08 cannot be proven against a real worker until this exists. That is this slice's release consequence, not its purpose.

## Proposed Approach

Deliver the hosted branch of the step that already exists, and bind the worker in the same commit.

- `LocalOnboardingLive`'s `%{storage_mode: "hosted"}` clause stops answering a flash and creates the project. It resolves the hosted workspace from the attempt's `hosted_prerequisite_workspace_id`, so the identity comes from the sign-in the person already completed rather than from the session alone.
- Creation goes through `Projects.register_project/3` with that workspace, so the hosted project, its repository connection, and its single authoritative storage mode commit exactly as they do for a GitHub repository. The attempt's `selected_repository` supplies `repository_provider: "local"` and the portable identity as the canonical repository id.
- The worker binding commits with them. The worker that proved the repository during selection is the one named, taken from the attempt rather than from whatever is attached at that moment, so a different Mac cannot be substituted between selection and confirmation. `put_validated_binding/6` is the existing writer and its contract does not change.
- One transaction covers the project, the connection, the storage mode, and the binding. A failure anywhere leaves none of them, which is what AC-07 of `specs/05` already requires and what AC-03 here restates for the binding.
- On success the person goes to the hosted project's dashboard, which already renders the repository, the storage mode, and the live connection state for a hosted local project.
- A device project for the same repository is not consulted and not touched. The uniqueness that applies is per account and per repository identity, inside hosted storage.

## Components Affected

- `SddOrchestratorWeb.LocalOnboardingLive`: the hosted branch of the confirmed attempt, its refusal copy, and the routing that follows.
- `SddOrchestrator.Projects` (`register_project/3`): accepting a device-origin attempt whose storage mode is hosted, and resolving its proven hosted workspace.
- `SddOrchestrator.Portability.HostedLocalRepositoryBindings` (`put_validated_binding/6`): the binding written inside the creation transaction.
- `SddOrchestrator.Projects.ProjectOnboardingAttempt`: reading `hosted_prerequisite_workspace_id` and the selected worker on a device-origin attempt.
- `SddOrchestratorWeb.ProjectDashboardLive`: unchanged, and the screen the person lands on.

## Data and Access Boundaries

- `HostedLocalRepositoryProject`: a `Project` with `storage_mode: "hosted"` and `repository_provider: "local"`, whose `canonical_repository_id` is the portable identity the worker generated. Owned by the person's `PersonalWorkspace`, readable by that account and by members it later invites, and following the hosted project lifecycle `specs/05-project-storage-lifecycle/` defines. It holds no path, remote, history, or file name.

Required boundaries:

- The hosted workspace comes from the attempt's proven `hosted_prerequisite_workspace_id`, so a project cannot be created for an identity the attempt never proved.
- The binding names the worker recorded in the attempt's selection. A worker that did not prove this repository cannot be bound, and neither can one on another Mac.
- Nothing this slice writes may carry a repository path, remote, commit, file name, or source content. The portable identity is the only repository value stored.
- A device project for the same repository is neither read as authority nor modified. The two records stay separate, as `specs/02-local-project-onboarding/` AC-25 and `specs/05-project-storage-lifecycle/` AC-11 require.
- No product-analytics event names the project, the repository, or the person.

## Interfaces

- `Projects.register_project/3` accepting a device-origin attempt with `storage_mode: "hosted"`, answering the created project or a refusal, and adding a reason for an attempt whose hosted workspace was never proven.
- `LocalOnboardingLive`'s confirmed-attempt handling answering a created hosted project instead of a not-yet-available flash.
- Compatibility that must hold: the accountless device branch and its `/local/projects/:id` routing, the GitHub hosted path through the same `register_project/3`, `HostedLocalRepositoryConnection.connect/6` and its refusals, the storage step's availability and sign-in handoff, and the device store's one-project-per-repository rule.

## Decisions and Tradeoffs

### The binding commits with the project

- Choice: The worker binding is written in the same transaction as the project, its connection, and its storage mode.
- Reason: The worker proved this exact repository moments earlier in order to offer the folder picker. Creating the project unconnected would make the person prove the same repository twice in a row and land them on a project that cannot start a run.
- Consequence: Creation depends on the selection still naming a usable worker, so a worker that disappeared between selection and confirmation refuses the whole creation rather than producing an unconnected project. `specs/37-hosted-local-repository-connection/` keeps owning reconnection and moving machines.

### The identity comes from the attempt, not the session

- Choice: The hosted workspace is resolved from the attempt's `hosted_prerequisite_workspace_id`.
- Reason: The schema already records the workspace proven by the sign-in on that attempt, which is what `specs/05-project-storage-lifecycle/` AC-14 writes when an accountless person signs in mid-flow. Reading the session instead would let a session change between the sign-in and the confirmation decide who owns the project.
- Consequence: An attempt that never proved a hosted workspace is refused rather than falling back, and the storage step's own availability rules stay the only thing that decides whether the choice is offered.

### A device project for the same repository is left alone

- Choice: Creation neither consults nor changes a device project for the same repository. Both exist separately.
- Reason: `specs/02-local-project-onboarding/` AC-25 requires distinct on-device and hosted projects for one repository to remain separate entries, and `specs/05-project-storage-lifecycle/` AC-11 forbids merging, reassigning, migrating, or changing the storage mode of either.
- Consequence: A person can hold two projects for one repository. That is the accepted shape, and moving between modes stays with the migration specification `specs/05-project-storage-lifecycle/` already defers.

## Risks

- The device store and hosted PostgreSQL are separate authorities. The binding and the project are both hosted, so one transaction covers them, but the surrounding flow is the same LiveView that also writes device projects. The hosted branch must not reach into the device store at all.
- A worker that detaches between folder selection and confirmation makes the binding unwritable. The refusal must leave nothing behind rather than a project without a worker.
- `Projects.register_project/3` is the GitHub path's committed writer. Widening it to a device-origin attempt must not change what a hosted-origin attempt does.

## Open Questions

- None.
