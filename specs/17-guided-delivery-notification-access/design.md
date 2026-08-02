# Guided Delivery Notification Access Design

## Context

Slice 07 Task 36 projects blocked, review-ready, and terminally failed run events into the shared Slice 08 `AccountNotification` store. That completed projection owns event selection, minimized notification content, current-recipient resolution, and at-least-once deduplication. It does not yet provide the durable list, mark-read, safe-link, responsive interface, or Slice 07 notification-retention behavior.

The provider boundary has one known defect: an active participant without a `ProjectMemberProfile` is omitted from current-participant enumeration, which can route responsibility and a blocked notification to the owner. Slice 08 owns the repair through `capability:project-participation-recipient-routing`; this specification must not implement or duplicate participation logic.

## Proposed Approach

Extend the shared notification foundation through a Slice 07 access service that queries recipient-scoped records, revalidates project participation on every operation, exposes durable unread state, and marks records read idempotently. Resolve the stored safe feature reference only after the same authorization check, and return one non-disclosing refusal for absent and inaccessible records.

Render the authorized result in an accessible responsive in-product inbox. Use PubSub only to prompt a refresh; reconnect and application restart always recover state from the durable store. Add the Slice 07 event namespace to the shared retention pruner with a 90-day rule that deletes only notification records.

## Components Affected

- Shared account-level notification query and mark-read boundary.
- Guided-delivery notification access service.
- Project-participation authorization and repaired recipient-routing consumers.
- Safe internal feature-link resolver.
- In-product notification LiveView and navigation affordance.
- Shared privacy-retention pruner for Slice 07 notification event types.

## Data and Access Boundaries

This slice introduces no new authoritative data entity. It consumes the existing shared `AccountNotification` record created by Slice 07 Task 36 and must not redefine its identity, uniqueness, event namespace, body, or lifecycle-event projection.

Required boundaries:

- An account may list or mark read only its own notification records.
- A guided-delivery notification is visible only while the recipient remains a current participant of the referenced project.
- Active participant routing consumes `capability:project-participation-recipient-routing`; this slice cannot create, repair, or infer participation or display-profile state.
- The safe link is an internal project and feature reference, not a public URL, and authorization is checked after resolution.
- List items expose only minimized project and feature display context, status or required action, event time, read state, and the safe internal link.
- Retention may delete Slice 07 notification rows but cannot change account, participant, project, feature, run, review, or assignment state.

## Interfaces

- Notification access interface: list recipient-scoped authorized records in stable newest-first order with bounded pagination and unread state.
- Mark-read interface: apply one idempotent read transition to one authorized recipient record.
- Live-update interface: publish or consume only a refresh hint after durable insertion; never synthesize delivery from PubSub.
- Safe-link interface: resolve the stored internal feature reference and reauthorize the project and feature before navigation.
- Retention interface: select read and unread Slice 07 events at the 90-day boundary and prune them through the shared locked, restart-safe mechanism.

## Decisions and Tradeoffs

### Durable Store Is Delivery Truth

- Choice: Read notification state from the shared durable store after every connection or restart and treat PubSub only as a refresh hint.
- Reason: Offline recipients and restarted application nodes must not lose action-required state.
- Consequence: The interface performs an authorized durable query after reconnect instead of replaying transient messages.

### Reauthorize Every Notification Operation

- Choice: Check current project participation for list, read, mark-read, and link-open operations.
- Reason: A stored account-level recipient reference must not preserve project access after removal.
- Consequence: Previously delivered records become inaccessible immediately when participation ends, while retention later removes them on schedule.

### Participation Repair Remains Provider-Owned

- Choice: Block implementation on Slice 08's repaired recipient-routing capability instead of compensating for missing participant profiles in Slice 07.
- Reason: Authorization identity and participant enumeration have one owner, and a second fallback in the consumer would drift from assignment and review routing.
- Consequence: Task 1 remains blocked until Slice 08 Task 36 proves active participant routing independent of `ProjectMemberProfile`.

### Notification Retention Is State-Neutral

- Choice: Delete only Slice 07 notification rows after 90 days.
- Reason: Notification delivery is a projection of governed workflow history, not the authority for that history.
- Consequence: Feature and run records remain unchanged when a notification expires.

## Risks

- A cached authorization result could expose a notification after removal. Every operation uses a current provider read and tests removal between page render and action.
- PubSub could accidentally become the only source of new items. Restart and disconnected-browser proof reads from the durable store with PubSub disabled.
- A safe link could disclose whether another project's feature exists. Unknown, cross-project, and unauthorized references return the same refusal.
- Retention could select non-Slice 07 notification types. Selection is constrained to the reserved guided-delivery event namespace and proved against participation notifications.

## Open Questions

None.
