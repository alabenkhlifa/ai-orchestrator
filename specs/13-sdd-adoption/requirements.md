# SDD Adoption Coordination

## Status

Approved

## Outcome

Repository adoption presents one coherent path from repository assessment to autonomous SDD execution while keeping mature-repository enablement, optional permanent kit installation, and empty-repository initialization as independently deliverable workflows with explicit trust boundaries.

## Users

- Project owners deciding how SDD Orchestrator may inspect or change a repository.
- Technical and non-technical contributors who need clear readiness and limitation states before asking an agent to work.
- Security and platform reviewers evaluating repository access, external workflow material, and release evidence.

## In Scope

- Shared product rules and release coordination across `specs/14-repository-execution-profile/`, `specs/15-repository-sdd-kit-integration/`, and `specs/16-empty-repository-initialization/`.
- One common meaning of SDD readiness: authoritative complete specification revisions plus managed runtime workflow skills, without mandatory repository installation.
- Separate visible readiness for assistant use, specification quality, autonomous agent execution, and deployment or release.
- Cross-child capability sequencing and combined release evidence.

## Out of Scope

- Repository scanning, execution-profile persistence, or pilot-feature implementation, owned by `specs/14-repository-execution-profile/`.
- Repository file mutation, kit installation, update, or removal, owned by `specs/15-repository-sdd-kit-integration/`.
- Product and technical foundation discovery, Git initialization, application scaffolding, or first-commit creation, owned by `specs/16-empty-repository-initialization/`.
- Project-assistant conversation and tools, owned by `specs/12-project-assistant/`.
- A second specification store, bidirectional repository synchronization, or automatic backlog import.

## Primary Workflow

1. A project owner encounters the SDD adoption entry point for an existing or empty repository.
2. The product routes a mature repository to execution-profile assessment and routes an empty repository to initialization without combining their trust or verification paths.
3. A mature repository can use managed runtime SDD without repository mutation and may later receive a separate optional permanent-kit offer.
4. Each child workflow reports assistant, specification, agent-execution, and release readiness independently.
5. Release coordination confirms that child capability contracts agree and that no child creates another authoritative specification source.

## Business Rules

- The umbrella coordinates child contracts and release evidence only; it must not own duplicate application implementation.
- Uniform SDD behavior means authoritative complete `requirements.md`, `design.md`, and `tasks.md` revisions plus versioned managed runtime skills.
- Permanent repository installation is optional and cannot be a prerequisite for managed Orchestrator execution.
- Existing-repository assessment, permanent repository mutation, and empty-repository initialization remain separate user decisions and separately verifiable workflows.
- A child may be implementation-ready while another remains blocked; readiness must not be collapsed into one adoption score.
- Repository contents, cached indexes, generated profiles, kit provenance, initialization plans, and resulting files remain governed by their owning child contracts and the selected project or runtime boundary.
- Release coordination must reject a child contract that introduces a second authoritative specification store, automatic bidirectional synchronization, silent repository mutation, or an undisclosed processing boundary.

## Acceptance Criteria

- [AC-01] Given a mature or empty repository reaches SDD adoption, when routing is evaluated, then the user enters the matching child workflow without being required to install a permanent repository kit.
- [AC-02] Given any adoption child reports status, when readiness is presented, then assistant, specification, agent-execution, and release readiness are shown separately with the earliest blocking reason.
- [AC-03] Given the three child capabilities are ready, when adoption release coordination runs, then their capability graph is acyclic, their source-of-truth and trust rules agree, and no implementation surface is duplicated by this umbrella.

## Open Questions

- None.
