# Worker Menu Status Presentation

## Status

Approved

## Outcome

The worker app's menu tells the person what state their worker is in at a glance, through a coloured dot they can read before the words. The status line looks like part of the menu rather than a dead, greyed-out row.

## Users

- The person who installed the worker app on their Mac. They open the menu to answer one question: is my worker working right now. They are not expected to read a sentence to find that out, and they should not have to wonder whether a greyed-out line means something is broken.

## In Scope

- A coloured status dot on every state the menu's status line can show.
- One colour language across all of those states, so the same colour always means the same kind of thing.
- Every line that only reports information rendered as a normal, readable menu item: the status line, a pairing failure reason, and an available version.
- Clicking the status line continuing to copy the pairing code in the one state that offers a code.

## Out of Scope

- Changing any status wording. The seven lines say exactly what they say today.
- Changing which state the app reports, or when. State derivation stays owned by `specs/36-local-worker-native-distribution`, `specs/38-worker-initiated-pairing`, and `specs/39-mac-scoped-worker-connection`.
- Adding, removing, or reordering menu items.
- The dashboard's own connection badges.

## Primary Workflow

1. The person clicks the worker app's icon in the menu bar.
2. The menu opens. The first line shows a coloured dot next to the status text.
3. The person reads the colour and knows the kind of state without reading the sentence: green is working, red is not working, amber is still settling, grey is nothing set up yet, blue is an update waiting.
4. The line looks like every other item in the menu. If the person clicks it while a pairing code is on offer, the code is copied as it is today. If they click it in any other state, nothing happens and nothing appears broken.

## Business Rules

- Every state the status line can show carries exactly one dot. A state with no dot would read as a state the app forgot about.
- One colour means one kind of thing across every state. Green means the control plane has the worker attached. Red means it is not usable now, which covers both a lost connection and a refused one. Amber means the app is part-way through and expects to move on by itself. Grey means nothing is set up yet. Blue means an update is waiting and is not a health signal.
- Colour never carries meaning on its own. Every line keeps its text, so the dot reinforces the words rather than replacing them.
- A line that only reports information is never rendered as a disabled item. A person reads a greyed row as broken or as something they have lost access to, and neither is true of text that is simply telling them something.
- A line that offers an action a person genuinely cannot take right now stays disabled. Grey is reserved for that, so it keeps meaning one thing.
- A click on the status line does something only when a pairing code is on offer. In every other state the click is accepted and ignored, without a sound, a flash, or a menu that stays open pretending to work.

## Acceptance Criteria

- [AC-01] Given the menu is open in any of its states, when the status line is read, then it shows exactly one coloured dot beside text that is unchanged from today.
- [AC-02] Given two states of the same kind, when their dots are compared, then the colour follows one language: green for connected, red for disconnected and for a refused connection, amber for connecting and for setting up, grey for not paired, and blue for an update being available.
- [AC-03] Given a menu line that only reports information, such as the status line with nothing to copy, a pairing failure reason, or an available version, when the menu is open, then it is drawn as a normal enabled item rather than a greyed-out one.
- [AC-04] Given the app is unpaired and holding a pairing code, when the person clicks the status line, then the code is copied exactly as it is today, and in every other state the same click changes nothing.
- [AC-05] Given an update is available and installing it is deferred because a run is still active, when the menu is open, then the install item is still drawn as disabled, because there the grey reports an action the person genuinely cannot take yet.

## Open Questions

- None.
