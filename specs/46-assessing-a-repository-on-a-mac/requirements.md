# Assessing A Repository On A Mac

## Status

Draft

## Outcome

An owner of a hosted project whose repository is a Git repository on their Mac can assess that repository and approve its execution profile. Today the assessment screen redirects them away with no explanation, so the profile has nothing to approve and development can never start. The project is created, connected, and useless.

## Users

- Local repository owner: a person whose hosted project's repository is on their own Mac. They reach this screen from the project, having already connected the machine that holds the repository.
- GitHub project owner: named only because their assessment must not change.

## In Scope

- Opening the assessment for a hosted project whose repository is on a Mac, through the same screen a GitHub project uses.
- Naming that repository on the screen without inventing a second wording for a fact the product already states.
- Telling the person what is missing when their Mac is not reachable, instead of turning them away.
- Approving the execution profile that a completed assessment of such a repository proposes.

## Out of Scope

- What the scan reads and how it is proposed, which is unchanged and owned by `specs/14-repository-execution-profile/`.
- The accountless device route of the same screen, which already serves a local repository and stays exactly as it is.
- Connecting, reconnecting, or moving the Mac, owned by `specs/37-hosted-local-repository-connection/`.
- Starting development, owned by `specs/41-feature-delivery-from-the-ui/`. This slice removes the precondition that blocks it; it does not press the button.
- Any other screen that assumes a project has a GitHub repository connection.

## Primary Workflow

1. The owner opens a hosted project whose repository is on their Mac and chooses `Assessment`.
2. The screen opens and names the repository it is about.
3. When the Mac that holds the repository is reachable, the owner confirms the processing boundary and starts the assessment, exactly as a GitHub owner does.
4. When that Mac is not reachable, the screen says so and offers no start, and the project is unchanged.
5. The completed assessment produces a proposal, and the owner approves the execution profile from it.

## Business Rules

- A hosted project is assessable when its repository is reachable, whether that repository is on GitHub or on a Mac. Having a GitHub repository connection is one way to satisfy that, not the definition of it.
- Authorization does not change. The assessment is for the owner of the project, and every check that runs today still runs.
- A repository on a Mac is never described as a GitHub repository, and the screen states no repository name the product does not hold.
- A person is told what is missing rather than turned away with no reason. Being unable to start is a state the screen shows, not a redirect.
- The scan runs on the Mac. Nothing about the repository's path, remote, history, file names, or source content is stored or shown by making this screen reachable.

## Acceptance Criteria

- [AC-01] Given an owner of a hosted project whose repository is on a reachable Mac, when they open the assessment, then the screen renders and names that repository.
- [AC-02] Given that screen is open and the Mac is reachable, when the owner confirms the processing boundary and starts the assessment, then it starts exactly as it does for a GitHub project.
- [AC-03] Given the Mac holding the repository is not reachable, when the owner opens the assessment, then the screen renders, says the machine is not reachable, offers no start, and leaves the project unchanged.
- [AC-04] Given an assessment of such a repository completes, when the owner opens the execution profile, then the proposal is there to approve and approving it works.
- [AC-05] Given an owner of a GitHub project, when they use the assessment and the execution profile, then everything they see and can do is unchanged.
- [AC-06] Given a person who does not own the project, when they open its assessment, then they are refused exactly as they are today and nothing about the project is disclosed.

## Open Questions

- None.
