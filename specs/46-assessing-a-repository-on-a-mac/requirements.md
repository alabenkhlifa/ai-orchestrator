# Assessing A Repository On A Mac

## Status

Approved

## Outcome

An owner of a hosted project whose repository is a Git repository on their Mac can assess that repository and approve its execution profile.

The first slice made the screen reachable. It stopped one step short of the point. Pressing `Start assessment` saves a request and sends nothing, and the screen says so. No repository is ever scanned outside the test bootstrap, so no assessment ever completes, no proposal is ever produced, and the profile still has nothing to approve. This slice runs the scan on the Mac that holds the repository and stores its answer, so the assessment finishes for real.

## Users

- Local repository owner: a person whose hosted project's repository is on their own Mac. They reach this screen from the project, having already connected the machine that holds the repository.
- GitHub project owner: named only because their assessment must not change.

## In Scope

- Opening the assessment for a hosted project whose repository is on a Mac, through the same screen a GitHub project uses.
- Naming that repository on the screen without inventing a second wording for a fact the product already states.
- Telling the person what is missing when their Mac is not reachable, instead of turning them away.
- Sending the saved assessment to the Mac that holds the repository, and running the existing worker-local scan there.
- Showing the scan running, and letting the person stop it.
- Storing the answer as a completed assessment with its proposal, or as a failed one with a plain reason.
- Approving the execution profile that a completed assessment of such a repository proposes.

## Out of Scope

- What the scan reads, and how a proposal is derived from what it found. Both are unchanged and owned by `specs/14-repository-execution-profile/`. This slice sends the scan and stores its answer.
- Scanning a repository connected through GitHub. `specs/47-live-repository-metadata-binding/` records why a worker cannot verify one, and owns the screen's wording for it.
- Running a scan the person is not watching, and telling them later that it finished.
- The accountless device route of the same screen, which already serves a local repository and stays exactly as it is.
- Connecting, reconnecting, or moving the Mac, owned by `specs/37-hosted-local-repository-connection/`.
- Starting development, owned by `specs/41-feature-delivery-from-the-ui/`. This slice removes the precondition that blocks it. It does not press the button.
- Any other screen that assumes a project has a GitHub repository connection.

## Primary Workflow

1. The owner opens a hosted project whose repository is on their Mac and chooses `Assessment`.
2. The screen opens and names the repository it is about.
3. When the Mac that holds the repository is reachable, the owner confirms the processing boundary and starts the assessment, exactly as a GitHub owner does.
4. When that Mac is not reachable, the screen says so and offers no start, and the project is unchanged.
5. The screen shows the scan running on the Mac, and offers to stop it.
6. The Mac scans the repository its worker already verified, and answers.
7. The assessment is stored as completed, the screen says so, and it offers the execution profile.
8. When the scan is stopped, refused, or never answered, the assessment is stored as failed with a plain reason, and the owner can start a new one.
9. The owner approves the execution profile from the proposal.

## Business Rules

- A hosted project is assessable when its repository is reachable, whether that repository is on GitHub or on a Mac. Having a GitHub repository connection is one way to satisfy that, not the definition of it.
- Authorization does not change. The assessment is for the owner of the project, and every check that runs today still runs.
- A repository on a Mac is never described as a GitHub repository, and the screen states no repository name the product does not hold.
- A person is told what is missing rather than turned away with no reason. Being unable to start is a state the screen shows, not a redirect.
- The scan runs on the Mac. Only its minimized answer crosses back: repository-relative anchors, sizes, line counts, and content digests, which is the evidence `specs/14-repository-execution-profile/` already approved. No absolute or filesystem path, no remote URL, no Git history, and no file content is sent, stored, logged, or shown.
- The scan reads the repository the binding already verified. The Mac is not asked to find it again, and no folder panel opens unless the person asked for one.
- A verified binding the Mac no longer holds has expired. The person is told to verify it again.
- An assessment that does not finish is stored as failed with a plain reason. No saved request stays pending forever.
- The person can stop the wait. Stopping ends that assessment and starts nothing new.

## Acceptance Criteria

- [AC-01] Given an owner of a hosted project whose repository is on a reachable Mac, when they open the assessment, then the screen renders and names that repository.
- [AC-02] Given that screen is open and the Mac is reachable, when the owner confirms the processing boundary and starts the assessment, then it starts exactly as it does for a GitHub project.
- [AC-03] Given the Mac holding the repository is not reachable, when the owner opens the assessment, then the screen renders, says the machine is not reachable, offers no start, and leaves the project unchanged.
- [AC-04] Given an assessment of such a repository completes, when the owner opens the execution profile, then the proposal is there to approve and approving it works.
- [AC-05] Given an owner of a GitHub project, when they open the assessment, then the screen still renders, names the repository, and does not redirect, exactly as before. Starting an assessment for a GitHub-connected repository is a separate, later limitation this slice does not decide: `specs/47-live-repository-metadata-binding/` records why (a worker can only verify a repository identity it can match against a local folder, and a GitHub identity has none yet) and owns the screen's wording for it.
- [AC-06] Given a person who does not own the project, when they open its assessment, then they are refused exactly as they are today and nothing about the project is disclosed.
- [AC-07] Given an owner whose Mac is reachable and whose binding is verified, when they press `Start assessment`, then the scan runs on that Mac and the screen shows it running with a way to stop it.
- [AC-08] Given that scan answers, when it finishes, then the assessment is stored as completed with its proposal, and the screen says so and offers the execution profile.
- [AC-09] Given the Mac no longer holds the folder the binding verified, when the scan reaches its worker, then it is refused as expired, no folder panel opens on that Mac, and nothing is scanned.
- [AC-10] Given the worker refuses the scan, the Mac drops, or nobody answers in the wait window, when the request ends, then the assessment is stored as failed with a plain reason and the owner can start a new one.
- [AC-11] Given a scan is running, when the owner stops the wait, then the assessment does not complete and nothing keeps running on their behalf.
- [AC-12] Given any of these outcomes, when the answer crosses back and is stored, rendered, or logged, then it carries no absolute or filesystem path, no remote URL, and no file content, and anything else it names is refused whole.

## Open Questions

- None.
