# Worker Menu Status Presentation Tasks

## Status

In Progress

## Active Slice

Give the worker app's menu a coloured dot on every status it can show, in one colour language, and stop drawing the status line as a disabled row while keeping the pairing-code copy exactly as it works today.

## Cross-Specification Dependencies

Requires:

- None.

Provides:

- None.

## Slice Size Gate

- Slice size: Standard

## Task Size Gate

- Standard tasks deliver one independently provable outcome, normally in one task-boundary commit, with focused proof.
- Exceptions are allowed only when splitting an atomic migration, transaction, or invariant would create an invalid intermediate state.

## Proof Scope Gate

- Applies to: all tasks.

## Implementation Boundary

Included:

- A semantic status indicator on `WorkerStatus` and its mapping for all seven states.
- The AppKit drawing that turns one indicator into one coloured dot on the menu item.
- The menu's enabled-state handling, so no line that merely reports information is drawn greyed, while an action a person cannot take yet still is.

Excluded:

- Every status string. The wording belongs to the specifications that introduced each state and is unchanged here.
- Which state the app reports and when, owned by `specs/36-local-worker-native-distribution`, `specs/38-worker-initiated-pairing`, and `specs/39-mac-scoped-worker-connection`.
- The set of menu items, their order, and the pairing-code copy behavior itself.
- The dashboard's own connection badges.

Deferred after this slice:

- Showing the state on the menu bar icon itself, so it can be read without opening the menu. That is a larger change to what the icon means and is not what this slice was asked for.

Release gates:

- None of its own. Distributing any build carrying this change stays governed by `specs/36-local-worker-native-distribution`'s signing and notarization release gate.

Traceability:

- Deferred criteria: none
- Release criteria: none
- Deferred entities: none
- Release entities: none

## Tasks

- [x] Task 1 — Give every status a coloured dot in one colour language.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: none
  - Purpose: Let a person read the kind of state from the menu before reading the sentence, without changing what any line says.
  - Owned surfaces: `WorkerStatus`'s semantic status indicator and its mapping for all seven states, the AppKit helper that draws one indicator as one dot, and the menu item's image in `AppDelegate.rebuildMenu()`.
  - Owns: AC-01, AC-02
  - Proof: Focused tests cover every status answering exactly one indicator, connected answering the healthy kind, disconnected and the refused state answering the same problem kind, connecting and setting up answering the same in-progress kind, not paired answering the idle kind, update available answering its own kind rather than a health one, and every `menuStatusLine` string remaining byte-identical.
  - Delivered: `StatusIndicator` names five kinds of state in the AppKit-free Core target and `WorkerStatus.indicator` maps all seven states to them through an exhaustive switch, so a new state cannot compile without choosing a kind. `StatusIndicatorImage` is the only place that knows a colour, drawing the dot through a handler that re-runs so the system colours resolve under the menu's current appearance. Every status string is unchanged and pinned by a test.

- [x] Task 2 — Reserve grey for an action a person cannot take.
  - Size: Standard
  - Proof scope: Focused
  - Depends on: Task 1
  - Purpose: Remove the greyed rows a person reads as broken, without inventing an action a line does not have and without hiding that a deferred install really is unavailable.
  - Owned surfaces: The menu's automatic-enabling setting in `AppDelegate.rebuildMenu()`, and the enabled state of the status item, the pairing-failure detail item, the update-version detail item, and the install item.
  - Owns: AC-03, AC-04, AC-05
  - Proof: Focused tests cover `PairingCodeMenu.statusLine/3` still offering a copyable code only in the code-offering state and still refusing to offer one in every paired state, so the one signal that decides whether a click does anything is unchanged. The enabled rendering itself is AppKit glue with no unit-test seam and is proved by the slice's product proof, which reads a menu carrying a pairing failure, an available version, and a deferred install.
  - Delivered: The menu stops enabling items automatically, so the status line, the pairing-failure reason, and the available-version line keep their normal look, while the install item still greys out when a run blocks it. The status line gains a target only in the code-offering state, so a click elsewhere does nothing without a stub selector standing in for it.

## Verification Gate

- [ ] Acceptance criteria pass.
- [ ] The worker app's own test suite passes.
- [ ] Every existing menu and status test passes unchanged, proving no status wording moved.
- [ ] Build and static checks pass.
- [ ] Product proof, read on the real menu bar of an installed build rather than in a browser, because this slice's whole outcome lives in the native menu and no web surface changes: open the worker app's menu in each reachable state and confirm the dot's colour and that the status line is not greyed. Record the states seen in `progress.md`.

## Blocked Decisions

- None.

## Progress Log

See [progress.md](progress.md).
