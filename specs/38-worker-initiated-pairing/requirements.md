# Worker-Initiated Pairing

## Status

Approved

## Outcome

Someone who has installed the worker app can pair it to their Mac's project space on their own, starting from the app rather than from a project that does not exist yet. The app shows a pairing code while it is unpaired, the person copies it from the menu bar, pastes it into the dashboard, and the worker comes online.

## Users

- The person who installed the worker app on the Mac that holds their repositories. They are comfortable installing an app and copying a code between two windows on the same machine. They are not expected to open a terminal, know what a device workspace is, or understand that a code has a scope.
- The project owner redeeming the code in the dashboard. On the accountless local path this is the same person in a browser on the same Mac.

## In Scope

- The worker app obtaining a pairing code while it is unpaired, without any prior knowledge of a project, workspace, or account.
- Showing the current pairing state and the code in the menu bar, and copying the code to the clipboard from there.
- Keeping the shown code live, so a code the person copies is one the dashboard will still accept.
- Redeeming a code in the dashboard, which is the moment it becomes attached to that browser's Mac project space and the worker is authorized.
- The worker noticing on its own that its code was taken, and saying so without the person returning to the app.
- Refusing, safely and legibly, every code that is expired, already used, canceled, or not a real code.
- Limiting how many codes an unidentified caller can obtain, and discarding codes nobody redeems.

## Out of Scope

- Replacing the existing `Open in App` deep link, which stays the shorter path for reconnecting a machine to a project that already exists.
- Pairing a worker to a hosted project, or to a machine other than the one running the app.
- Any change to what a paired worker is then allowed to do, which `specs/33-local-worker-run-execution/` owns.
- Configuring the worker that this pairing authorizes. A worker paired this way has no project, no repository folder, and no chosen coding agent, so it cannot connect or run anything yet. It exists so the dashboard can see a worker and let onboarding continue.
- Re-pairing or rotating the credential of a worker that is already paired.
- Pairing from a phone, from a second device, or by scanning anything.
- Windows and Linux workers.

## Primary Workflow

1. The person installs and opens the worker app. It has never been paired, so it holds no credential, no workspace, and no project.
2. The app asks the control plane for a pairing code and shows `Not paired` in the menu bar with the code available there.
3. The person clicks the status line in the menu bar. The full code is copied to the clipboard and the app confirms the copy.
4. The person opens the dashboard, starts connecting a repository on this Mac, and pastes the code into the pairing field.
5. The dashboard accepts the code and attaches it to this browser's Mac project space. The app finishes on its own moments later and comes online. The person continues choosing their repository without touching the app again.
6. The app notices the code was taken, stops showing one, and says the dashboard has taken over. The person stays in the dashboard; nothing more is asked of them in the app.

## Business Rules

- A code the app obtains belongs to no Mac project space when it is created. It authorizes nothing and identifies nobody until it is redeemed.
- A code becomes attached to exactly one Mac project space at the moment an authorized person redeems it in the dashboard, and to that person's own space only.
- A code is single-use. It is attached to one Mac project space once and brings exactly one worker online, and a second attempt with the same code is refused.
- A code expires. An expired code is refused with the same answer as a code that never existed, so no answer reveals whether a code was ever real.
- The code shown in the menu bar is replaced before it expires, so a person who copies what they can see always copies something the dashboard will accept.
- Copying is explicit. The app never places a code on the clipboard without the person asking for it.
- A code is a credential. It is never written to a log, a crash report, an analytics event, or any diagnostic the app or the control plane emits.
- Obtaining a code requires no account, and is therefore limited so an unidentified caller cannot mint codes without bound.
- A code nobody redeems is discarded once it can no longer be used. It leaves nothing behind that describes a person or a machine.
- Pairing is what establishes a worker's identity, so no rule here may require the app to already know a workspace, a project, or an account.

## Acceptance Criteria

- [AC-01] Given the app has never been paired, when it starts, then it obtains a pairing code from the control plane and holds one that has not expired.
- [AC-02] Given the app is unpaired and holding a code, when the person clicks the status line in the menu bar, then the menu shows that it is not paired, the full code is on the clipboard, and the app confirms it was copied.
- [AC-03] Given a code was created by the app, when it is inspected before anyone redeems it, then it is attached to no Mac project space and grants no access.
- [AC-04] Given the person pastes a valid code into the dashboard while authorized, when it is accepted, then the code is attached to that person's own Mac project space and the repository flow continues once the worker comes online, without the person returning to the app.
- [AC-05] Given a code was already attached to a Mac project space, when the same code is submitted again, then it is refused and no second workspace is attached.
- [AC-06] Given a code has expired, canceled, or never existed, when it is submitted, then it is refused with one answer that does not reveal which of those it was.
- [AC-07] Given the shown code is approaching expiry, when the app refreshes it, then the menu bar shows a code the dashboard still accepts and the replaced code no longer works.
- [AC-08] Given the person redeemed the code in the dashboard, when the app next checks, then it stops offering a code and reports that the dashboard has taken over, without claiming a setup it cannot finish and without the person reopening it.
- [AC-09] Given an unidentified caller requests codes repeatedly, when the allowed rate is exceeded, then further requests are refused without revealing whether any earlier code was redeemed.
- [AC-10] Given a code was never redeemed, when it can no longer be used, then it is discarded and retains nothing describing a person or a machine.
- [AC-11] Given a pairing succeeds or fails, when the app's and the control plane's diagnostics are inspected, then no code, credential, or fragment of either appears in any of them.

## Open Questions

- None.
