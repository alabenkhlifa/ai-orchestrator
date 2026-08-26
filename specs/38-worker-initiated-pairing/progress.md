# Worker-Initiated Pairing Progress Log

### 2026-08-26 - Specification created from a gap found while testing locally

- Completed: Wrote `requirements.md`, `design.md`, and this plan. Product requirements are `Approved`; tasks are `Not Started` with `Task 1` executable now.
- Trigger: pairing a freshly installed worker app was impossible. The `Open in App` deep link only renders at `/onboarding/local` with a project parameter. That address needs a project, a local project needs a paired worker, and a paired worker needs a code. Nothing broke the cycle.
- Decisions the user made: the app fetches its own code and shows it; the code is created unbound and is attached to a Mac project space only when an owner redeems it; clicking the menu-bar status line copies the code; the app refreshes the code before it expires.
- Scope: `split required` against `specs/02-local-project-onboarding/` and `specs/36-local-worker-native-distribution/`. Both are `Verified`. This work adds an anonymous trust boundary and changes `PairingAttempt`'s lifecycle, so neither should absorb it. Both stay unchanged and this slice consumes their capabilities instead.
- Found while inspecting: the code format is an attempt id joined to a random secret, so collisions are impossible by construction rather than by a check. The design keeps that property. The pairing form's placeholder advertises a short code the product has never issued; `Task 4` corrects it.
- Failed checks: None. No code was written.
- Proof receipts: None yet.
- Spec updates: New specification. `specs/02` and `specs/36` are untouched.
