# Guided Delivery Feature-Specification Link

## Status

Approved

## Outcome

A delivery-board feature can be explicitly linked to one of the project's current authoritative specifications, so another approved specification can resolve which feature reflects a given specification's board and delivery progress without guessing or duplicating specification identity.

## Users

- Project owners linking a feature to the specification it delivers, or changing or clearing that link later.
- Project participants who create or edit features and continue to work exactly as today, with no required specification link.
- Other approved specifications (starting with `specs/15-repository-sdd-kit-integration`) reading a project's feature-specification link as a consumer of the published capability.

## In Scope

- One optional `specification_id` link on a delivery-board feature, settable, changeable, and clearable only by the project owner.
- A guaranteed at-most-one-feature-per-specification link within a project.
- A published read capability letting another approved specification resolve, for one project and specification identity, the linked feature's stable identity — and, through the existing board read, its `lifecycle_column`.

## Out of Scope

- Any change to `specs/30-repository-execution-profile-completion`'s `RepositoryPilotSelection` schema, business rules, or pilot-selection UI.
- Any change to `Delivery.Readiness`'s existing, separate readiness-assessment axes.
- Requiring a specification link at feature creation, or backfilling a link for features created before this change.
- Participant-level (non-owner) specification browsing or linking; specification content remains owner-only readable until `specs/09-project-specification-storage` separately approves broader participant authorization.
- Repository-kit installation eligibility itself, owned by `specs/15-repository-sdd-kit-integration`, which consumes the capability this slice publishes through its own separate specification change.

## Primary Workflow

1. The project owner opens a feature and optionally selects one of the project's current authoritative specifications to link, from the same specification identity and title already shown when selecting a repository pilot.
2. The link is stored on the feature. The owner may change or clear it later from the feature detail view.
3. A project can have at most one feature linked to any one specification; a specification already linked to another feature is not offered, and a direct attempt to link it again is rejected.
4. Another approved specification reads the project's current linked feature for one specification identity through the published capability, and separately reads that feature's `lifecycle_column` through the existing board read.
5. When no feature is linked to the requested specification, the read reports a clear not-linked result rather than an error or a guess.

## Business Rules

- Only the project owner may set, change, or clear a feature's specification link. Specification identity and content remain owner-only readable per `specs/09-project-specification-storage`'s current scope; feature creation, editing, and every other existing feature mutation keep their current participant-level authorization unchanged.
- The link references one specification identity from `capability:project-specification-store`'s current snapshot and stores only that stable identifier, never a copy of specification title, requirements, design, or tasks content.
- A project may link at most one feature to a given specification identity at a time. An attempt to link a second feature to an already-linked specification is rejected, and the first feature's link is unchanged.
- Linking, changing, or clearing a link never creates, changes, or deletes a specification document, and never changes the feature's `lifecycle_column`, `status`, or any other existing field.
- Removing a link is always available to the owner and never deletes the feature.
- The published read capability returns only the linked feature's stable identity; it exposes no specification content and creates no second specification authority.

## Acceptance Criteria

- [AC-01] Given the project owner is viewing a feature, when they open its specification link control, then they see the project's current authoritative specifications not already linked to another feature, and may select one or leave it unlinked.
- [AC-02] Given a feature already has a linked specification, when the owner changes or clears the link, then the feature's other fields are unchanged and the previous link no longer resolves to that feature.
- [AC-03] Given two features and one specification, when the owner attempts to link the second feature to a specification already linked to the first, then the attempt is rejected and the first feature's link is unchanged.
- [AC-04] Given a consumer capability requests the linked feature for one project and specification identity, when a link exists, then it receives that feature's stable identity; when no link exists, then it receives a clear not-linked result, never an error or a guess.
- [AC-05] Given a non-owner participant, when they attempt to set, change, or clear a specification link, then the attempt is refused and every other feature action they are already authorized for remains unaffected.

## Open Questions

- None.
