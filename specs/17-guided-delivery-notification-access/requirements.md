# Guided Delivery Notification Access

## Status

Approved

## Outcome

A current project participant can find durable guided-delivery notifications, understand which ones still require attention, mark them read, and safely return to the related feature, while removed participants are denied and expired notification records are deleted without changing delivery workflow state.

## Users

- Current project participants receiving blocked-run, ready-for-review, or failed-run notifications.
- Project owners who may receive delivery notifications in more than one responsibility role.
- Removed or former participants whose access must end immediately.

## In Scope

- An authorized notification list backed by the shared account-level notification store.
- Durable unread state and idempotent mark-read behavior.
- PubSub as an optional live presentation hint rather than the delivery guarantee.
- Reauthorization when listing, reading, marking read, or opening a feature link.
- A responsive and accessible in-product notification interface.
- Ninety-day deletion of Slice 07 notification records without feature, run, or participation mutation.

## Out of Scope

- Lifecycle-event projection and recipient selection already delivered by Slice 07 Task 36.
- Invitation and participation notification behavior owned by Slice 08.
- Email, chat, mobile-push, webhook, or other external notification channels.
- Feature, run, review, evidence, or participation state changes caused by notification reads or retention.

## Primary Workflow

1. A current participant opens the in-product notification interface after a guided-delivery lifecycle event has been projected.
2. The product lists only notifications the participant is currently authorized to access and shows their durable unread state.
3. The participant marks a notification read or opens its safe internal feature link.
4. The product revalidates current project participation before either action and denies removed participants without exposing project or notification content.
5. Retention removes Slice 07 notification records after 90 days without changing the related project workflow.

## Business Rules

- The stored account-level notification record is the delivery guarantee; PubSub is only a live update hint.
- Authorization must be revalidated on list, read, mark-read, and safe-link access.
- Active participant authorization and recipient routing must not depend on the presence of a `ProjectMemberProfile`; a missing presentation profile cannot silently route responsibility to the owner.
- No participant email, branch, commit, evidence detail, preview detail, or other project content may be copied into the notification list item.
- Mark-read is idempotent and cannot mutate feature, run, review, assignment, or participation state.
- A removed participant receives the same non-disclosing refusal for an unknown, inaccessible, or formerly accessible notification.
- Slice 07 notification records are deleted within 90 days whether read or unread.

## Acceptance Criteria

- [AC-01] Given a current participant has guided-delivery notifications, when they list them, then only currently authorized records are returned with durable unread state and minimized display content.
- [AC-02] Given an authorized notification is unread, when its recipient marks it read one or more times or reconnects after application restart, then it remains read exactly once without depending on PubSub delivery.
- [AC-03] Given a participant opens a notification's safe feature link, when authorization is evaluated, then a current participant reaches the related feature and an unknown, cross-project, or removed participant receives a non-disclosing refusal.
- [AC-04] Given a current participant uses the notification interface on desktop or mobile, when they navigate, mark read, or open a notification by keyboard or pointer, then the controls remain understandable, accessible, and usable without horizontal overflow or lost focus.
- [AC-05] Given a Slice 07 notification is at least 90 days old, when retention enforcement runs, then the record is deleted whether read or unread and no feature, run, review, assignment, or participation state changes.

## Open Questions

None.
