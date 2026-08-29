# Worker Menu Status Presentation Design

## Context

The worker app's menu is built in `AppDelegate.rebuildMenu()`. Its first item's title comes from `PairingCodeMenu.statusLine/3`, which returns a `PairingCodeMenuLine` carrying a title and an optional `copyableCode`. When a code is on offer the item gets the copy action; in every other state `rebuildMenu` sets `isEnabled = false`, which is what draws the greyed row.

`WorkerStatus` holds the seven states the line can show and `menuStatusLine` returns their exact wording. Three specifications contributed those states: `specs/36-local-worker-native-distribution` established the connection states, `specs/38-worker-initiated-pairing` added the unpaired code-offering line and the decision that clicking it copies, and `specs/39-mac-scoped-worker-connection` added the refused state and made connected mean attached.

Two facts shape this slice:

- The greyed row is not an approved decision anywhere. It appears only as an implementation choice in `rebuildMenu`. Nothing in `specs/36` or `specs/38` asks for a disabled item, so changing it reverses no agreement.
- The package splits deliberately: `SDDOrchestratorWorkerCore` is plain Foundation with no AppKit and holds every testable decision, while the `SDDOrchestratorWorkerApp` target is thin AppKit glue. A colour is an AppKit value, so the decision of *which* colour cannot live in Core, but the decision of *which kind of state this is* can.

## Proposed Approach

Add a semantic indicator to Core, map it to a colour in AppKit, and stop disabling the status line.

- `WorkerStatus` gains an indicator describing the kind of state, not its colour. Core owns and tests the state-to-indicator mapping.
- The AppKit layer turns one indicator into one small drawn circle and sets it as the menu item's image.
- `rebuildMenu` stops setting `isEnabled = false`. The menu turns off automatic enabling so an item with no action still draws as enabled.

The status wording is untouched, so the existing tests that assert exact menu strings keep passing unchanged and keep guarding the copy.

## Components Affected

- `WorkerStatus` in `SDDOrchestratorWorkerCore`: the new indicator and its per-state mapping.
- `AppDelegate.rebuildMenu()` in `SDDOrchestratorWorkerApp`: the item image, the enabled state, and the menu's automatic-enabling setting.
- A small AppKit drawing helper that turns one indicator into one image.

## Data and Access Boundaries

This slice introduces no stored record and no new entity. The indicator is derived in memory from a `WorkerStatus` the app already holds, and it is drawn and discarded with the menu.

Required boundaries:

- Nothing here is persisted, uploaded, or logged. The indicator is a function of a status the app already computed, so it can carry no information the menu did not already show.
- The indicator carries no credential, no worker identity, and no path, because it carries nothing but which of five kinds a state is.

## Interfaces

- `WorkerStatus.menuStatusLine` is unchanged, string for string. Its wording is product copy owned by the specifications that introduced each state, and this slice does not touch it.
- `PairingCodeMenu.statusLine/3` keeps its current return shape. `copyableCode` remains the one signal that says whether a click should do anything.
- No control-plane interface, protocol, or stored file changes.

## Decisions and Tradeoffs

### The indicator is semantic in Core and coloured in AppKit

- Choice: `WorkerStatus` answers a kind of state, such as healthy or problem, and the AppKit layer alone decides that healthy draws green.
- Reason: Core is plain Foundation on purpose, so it cannot hold an `NSColor`. Naming the kind rather than the colour also keeps the testable decision at the level that actually matters: that a refused connection and a dropped one are the same kind of problem is a product rule worth a test, while the exact green is not.
- Consequence: the colour itself is asserted by looking at the menu rather than by a unit test. That is the correct split for this package, and the slice's product proof is where a person confirms the colours.

### The dot is a drawn image, not a character in the title

- Choice: the dot is set as the menu item's image, and the title keeps exactly the text it has today.
- Reason: putting a coloured glyph in the title would make the status string carry presentation, which would break the tests that assert exact wording and would make the product copy depend on how a font renders an emoji. An image also aligns with the menu's own layout instead of sitting inside the text.
- Consequence: the app needs a small drawing helper. That is a few lines of AppKit, and it buys a status string that stays pure product copy.

### Colour reinforces the words and never replaces them

- Choice: every line keeps its full text next to the dot.
- Reason: colour alone excludes anyone who cannot distinguish these colours, and the menu is the one place a person checks when something is wrong. The dot is there to make the answer faster, not to become the answer.
- Consequence: no line gets shorter. The dot adds information rather than saving space, which is the intended trade.

### The menu stops enabling items automatically

- Choice: the menu is set to manage its own enabled state, and the status line stays enabled with no action attached.
- Reason: AppKit disables an item with no action by default, which is exactly what produces the greyed row. Turning that automatic behavior off is the direct way to keep the row readable while leaving the click inert.
- Consequence: every other item in this menu now owns its enabled state explicitly. The menu has three items and both others carry a real action and target, so nothing changes for them today, but a future item must set its own state rather than inheriting one.

### A click on an inert line does nothing at all

- Choice: the status line has no action outside the code-offering state, so a click closes the menu and changes nothing.
- Reason: the alternative, attaching an action that deliberately does nothing, would let a future edit give that handler a body by accident. Having no action is the honest expression of having nothing to do.
- Consequence: the person gets no feedback from the click. That is correct here, because the line is a status, and inventing feedback would suggest an action exists.

## Risks

- A colour language that reads well to the author can still be unreadable to someone with a colour vision deficiency. Reduced by keeping every line's text and by choosing red and green that differ in brightness as well as hue; detected by reading the menu in the product proof rather than trusting the palette.
- Turning off automatic enabling could leave a genuinely unavailable future item looking available. Reduced by keeping the menu to its current three items in this slice and recording the consequence; detected by the existing quit and dashboard actions continuing to work.
- A drawn image can look wrong against a dark menu or on a non-retina display. Reduced by drawing at the menu's own point size and letting the system scale it; detected in the product proof, which is read on a real menu bar.

## Open Questions

- None.
