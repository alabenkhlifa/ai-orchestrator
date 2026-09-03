# Live Repository Metadata Binding

## Status

Approved

## Outcome

A person who owns a project whose repository sits on their own Mac can confirm the processing boundary on the assessment screen and see the repository's real identity, its normalized relative root, and its exact current commit, read from that Mac by their own worker. The screen prepares the binding and saves a pending assessment without a test stub, an `/_e2e` seed, or a development stand-in.

This is the binding half of the repository assessment. The scan that turns a pending assessment into a completed one still has no live path, and a named follow-on specification owns it.

## Users

- The owner of a hosted project whose repository lives on their Mac.
- The owner of a device-authoritative project on the machine in front of them.

## In Scope

- Preparing a repository binding against a real attached worker, for both the hosted route and the device route.
- Asking the person to point at the repository folder on their Mac when a binding is prepared.
- Reusing that same folder for the revalidation that runs when the assessment starts, without asking a second time.
- Refusing clearly when no worker is attached, when the folder is not the project's repository, when the person cancels, and when the repository is not on the Mac at all.
- Making the live adapter the configured one outside tests, so nothing but a test may fall back to the unavailable stand-in.

## Out of Scope

- The repository scan, its result, and the completion that follows. No command carries a scan today and this slice adds none.
- Approving an execution profile, which needs a completed assessment.
- Assessing a repository that lives only on GitHub. The worker cannot prove that a folder on the Mac is that GitHub repository without sending the folder's remote, and the privacy boundary forbids that.
- Changing what a binding holds, what the disclosure says, or how the assessment is stored. Those are `specs/14-repository-execution-profile/`'s and stay as verified.

## Primary Workflow

1. The owner opens the assessment screen for a project whose repository is on their Mac, and their worker is attached.
2. They read the processing boundary, choose one relative root, choose their Mac, and confirm.
3. The screen says it is waiting and offers to stop. A folder panel opens on that Mac.
4. The person picks the repository folder. The worker checks that the folder is this project's repository, resolves the chosen root inside it, and reads the current commit.
5. The screen shows the repository, the normalized root, and the full commit, and offers to start the assessment.
6. Starting revalidates the same folder without a second panel and saves one pending assessment.

## Business Rules

- A binding may be prepared only through a worker that is attached now and paired to the workspace that owns it, which is the rule `specs/14-repository-execution-profile/` already enforces.
- The worker answers only for a folder whose repository identity matches the identity the project holds. Any other folder is refused, and nothing is saved.
- The chosen folder never leaves the Mac. No request, result, log line, stored record, or analytics event holds a path, a remote, Git history, a file name, or file content.
- The worker keeps the chosen folder in memory only, only for the life of the binding it answered, and forgets it when that expires or the release stops. It is never written to disk beyond the answer file `specs/40-worker-repository-selection/` already deletes on read.
- One panel opens per binding. The revalidation that runs at start reuses the folder the worker is holding, and refuses as stale when it no longer has one.
- The screen never claims the worker app is installed, running, or reachable. It states what the control plane knows and offers the rest as a branch the person picks.
- A project whose repository is not on a Mac is refused with a reason that names that fact, not with a message about a repository connection.

## Acceptance Criteria

- [AC-01] Given a hosted project whose repository is on the owner's Mac and whose worker is attached, when the owner confirms the processing boundary, then the screen shows a waiting state with a way to stop, and a folder request reaches that Mac.
- [AC-02] Given a waiting request, when the person picks the project's repository folder, then the screen shows the repository identity, the normalized relative root, and the exact full commit that folder is on.
- [AC-03] Given a waiting request, when the person picks a folder that is not this project's repository, then the screen refuses with a reason, no binding is prepared, and no assessment is saved.
- [AC-04] Given a prepared binding, when the owner starts the assessment, then the worker revalidates the same folder without opening a second panel, and exactly one pending assessment is saved.
- [AC-05] Given no worker is attached for the chosen Mac, when the owner confirms the processing boundary, then the screen says no worker is available, and no request leaves the control plane.
- [AC-06] Given a waiting request, when the person cancels on the screen or dismisses the panel, then the panel closes, no binding is prepared, and the screen offers another try.
- [AC-07] Given any prepare or revalidate, then no filesystem path, remote URL, Git history, file name, or file content appears in the request, the result, any log line, or any stored record on either side.
- [AC-08] Given the worker release stops while it holds a folder, when it starts again, then no held folder survives, and a revalidation for that binding is refused as stale.
- [AC-09] Given a device-authoritative project on the machine in front of the person, when its owner confirms the processing boundary, then the same live path prepares its binding and saves its pending assessment in the device store.
- [AC-10] Given a project whose repository lives on GitHub, when the owner opens the assessment screen, then the refusal names that this assessment needs a repository on a paired Mac, and offers no start.

## Open Questions

- None.
