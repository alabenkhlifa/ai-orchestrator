# Guided Delivery Feature-Specification Link Design

## Context

`specs/07-guided-specification-delivery`'s `Delivery.Feature` (`lib/sdd_orchestrator/delivery/feature.ex`) owns the board's `lifecycle_column`. `specs/30-repository-execution-profile-completion`'s `RepositoryPilotSelection` (`lib/sdd_orchestrator/repository_pilots/repository_pilot_selection.ex`) references one current authoritative `specification_id` from `capability:project-specification-store` (`specs/09-project-specification-storage`); by deliberate, already-verified design it stores only stable identifiers and nothing about the delivery board. No existing code correlates the two. `Delivery.Readiness.current_revision/2` reads the project's first current specification regardless of which feature is being assessed — confirmed by direct reading, not a real correlation, and out of scope to change here. `specs/15-repository-sdd-kit-integration`'s post-pilot eligibility gate needs to resolve "the feature that reflects the piloted specification's delivery progress," which is exactly the capability this slice publishes.

`specs/07` and `specs/30` are both fully `Verified`. This is additive, independently valuable, and separately verifiable, so it is a new child specification rather than reopening either.

## Proposed Approach

Add an optional, owner-settable `specification_id` to `Feature`, enforced unique per `(project_id, specification_id)` where set. Reuse the existing owner-authority-mapped current-snapshot read already used by `RepositoryPilots.selectable_specifications/3` (per `capability:project-specification-store`) to populate the link picker, so no new specification-listing contract is invented. Publish one new read function that resolves a project's linked feature for a given specification identity, returning a not-linked result rather than an error when absent.

## Components Affected

- `Delivery.Feature` schema and migration (new nullable column plus a partial unique index).
- `Delivery.Features` context (link/unlink functions, owner-only authorization, the new capability read).
- The existing feature detail LiveView: an owner-only link control.

## Data and Access Boundaries

- `Feature`: gains an optional `specification_id` (string, matching `capability:project-specification-store`'s identity format), unique per `(project_id, specification_id)` where not null. No other existing field, lifecycle behavior, or authorization changes.

Required boundaries:

- Setting, changing, or clearing `specification_id` is authorized like `RepositoryPilotSelection`'s pilot selection (owner-only), not like the existing participant-level Feature mutations (`transition`, `status`, `assignment`), because it depends on an owner-only specification read.
- The link stores only the specification's stable identifier; it never copies title, requirements, design, or tasks content onto the feature.
- The published read returns only feature identity already reachable through the existing board read by an authorized viewer; it introduces no new data exposure.

## Interfaces

- `Delivery.Features.link_specification/4` (exact name may be refined at implementation time): owner-authorized, validates the specification identity against the current snapshot, enforces the one-link-per-specification constraint, and updates only `specification_id`.
- `Delivery.Features.unlink_specification/3`: owner-authorized, clears the field.
- `Delivery.Features.fetch_by_specification/3` (the published capability read): given `project_id` and `specification_id`, returns `{:ok, feature} | {:error, :not_linked}`, for another approved specification — starting with `specs/15` — to combine with the existing board read for `lifecycle_column`.

## Decisions and Tradeoffs

### Feature Owns The Link, Not The Pilot Record

- Choice: add `specification_id` to `Delivery.Feature` rather than a `feature_id` to `RepositoryPilotSelection`.
- Reason: `RepositoryPilotSelection` (`specs/30`, `Verified`) already codifies "stores only stable identifiers" as a settled business rule about the pilot itself; `Feature` is the record consumers actually need to read (`lifecycle_column`).
- Consequence: a consumer resolving "the feature for this pilot" needs two reads — the pilot's `specification_id`, then this slice's link — rather than one direct field.

### Owner-Only Linking

- Choice: gate linking, changing, and clearing to the project owner, unlike other `Feature` mutations.
- Reason: the picker's specification list is reachable only through the project's owner-mapped `capability:project-specification-store` authority today; a participant-level gate would expose a control no participant could actually complete.
- Consequence: linking stays unavailable to non-owner participants until `specs/09` separately approves participant specification authorization. Existing `Feature` mutations are unaffected.

### At-Most-One Feature Per Specification

- Choice: enforce a unique `(project_id, specification_id)` constraint rather than allowing many features to share one specification.
- Reason: keeps the published read deterministic with no tie-break rule for any present or future consumer.
- Consequence: an owner who wants to re-link a specification to a different feature must first clear the existing link.

## Risks

- A non-owner seeing a link control they cannot use would be confusing. Mitigate by scoping the control's visibility to the owner viewer entirely, rather than showing it disabled with no options, consistent with how `RepositoryPilotSelection`'s selection UI is already scoped.
- A race between two rapid link attempts could momentarily contend for the same specification. The database unique index remains the authority: a concurrent second write fails the constraint instead of corrupting state.

## Open Questions

- None.
