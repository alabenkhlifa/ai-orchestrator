# Participation Identity Lifecycle Design

## Context

Slice 08 already provides fresh invitation proof, atomic first acceptance, direct current-participant authorization, a versioned departure handoff, historical profiles, retention pruning, and rights-aware anonymization. Three lifecycle gaps remain in the implemented contract.

`Participation.Acceptance` always inserts a new `ProjectMemberProfile`. A departed participant retains a historical profile linked to the same account, so fresh re-acceptance collides with `project_member_profiles_account_index` and is currently surfaced as `:invalid_display_name`. `ParticipationRevocation` keeps `former_hosted_identity_id` and `former_account_id` after consumer acknowledgement and after the participant authorization's own hosted-identity link expires. `Privacy.Rights` correctly refuses direct anonymization of an active profile and lets a verified request override pending-handoff necessity after departure, but it does not provide the approved workflow that first ends current participation.

This focused child specification closes those gaps without redefining invitation proof, current authorization, revocation consumption, notification content, contribution history, or the broader participation privacy program.

## Proposed Approach

Extend acceptance with a project-and-account profile lookup under the existing transaction. If it finds a linked historical participant profile, lock it and update that row to active state with the newly accepted display name. If it finds no linked profile, insert a new profile as first acceptance does today. An anonymized profile is not linked to the account and is never considered for reactivation. Keep the fresh `ProjectParticipant` insert, invitation consumption, and notification writes in the same `Ecto.Multi`, and classify profile-state or account-link conflicts separately from label validation failures.

Extend revocation acknowledgement so the acknowledgement fields and both former-identity links are updated together. Add a complementary retention selector to the existing locked pruner that clears any remaining `former_hosted_identity_id` and `former_account_id` at 30 days from `occurred_at`, whether or not acknowledgement was delivered. Both paths retain the revocation row and its non-identifying consumer contract. The identifying last display label continues to follow the separate attribution-necessity and anonymization rules.

Add an explicit verified participation-anonymization orchestration boundary in `Privacy.Rights`. Direct historical anonymization keeps refusing active profiles. The orchestration path takes the verified participant's stable account and hosted identity, uses the authoritative participant self-departure transition, and invokes the existing verified historical-attribution anonymization only after departure commits. A failure after departure remains safely retryable: access stays ended and the request reports incomplete anonymization instead of rolling authorization back or restoring it.

## Components Affected

- `SddOrchestrator.Participation.Acceptance` transaction and error classification.
- `SddOrchestrator.Participation.ProjectMemberProfile` historical-profile reactivation changeset.
- `SddOrchestrator.Participation.Revocations` acknowledgement transaction.
- `SddOrchestrator.Participation.ParticipationRevocation` former-identity release changeset.
- `SddOrchestrator.Privacy.Retention` revocation-link retention rule.
- `SddOrchestrator.Privacy.Rights` verified participant-anonymization orchestration.
- Focused acceptance, revocation retention, rights workflow, and compatibility tests.

## Data and Access Boundaries

- `ProjectParticipant`: Existing project-scoped authorization. Re-acceptance creates a fresh active authorization after fresh proof; departure remains authoritative and immediately fail-closed.
- `ProjectMemberProfile`: Existing project presentation and historical-attribution row. A linked historical row may be reactivated for the same project and account; an anonymized row remains permanently unlinked and unchanged.
- `ParticipationRevocation`: Existing versioned departure handoff. Former account and hosted-identity links are transient personal data cleared on acknowledgement or at 30 days, while the stable event and consumer-reconciliation fields remain.

Required boundaries:

- Authorization derives from immutable ownership or active `ProjectParticipant` state, never profile existence or display-name state.
- A profile lookup is scoped to the accepted project and account and locked before reactivation; it cannot select another project, account, role, or anonymized row.
- Fresh invitation proof and explicit acceptance remain mandatory before any new authorization or profile activation.
- Profile identifiers are stable only for linked historical profiles. Anonymized profile identifiers remain historical references and are never reassigned to a person.
- The accepted display name is presentation only, uses the existing normalization and uniqueness rules, and cannot be replaced by an email or stable identifier.
- Acknowledgement and scheduled cleanup clear only the two former-participant identity links; they do not mutate owner identity, project state, consumer-owned state, or current authorization.
- Rights orchestration accepts only an already verified request scoped to the same current participant. It cannot end another participant's membership, remove the immutable owner, or use a display name or email as authority.
- Once departure commits, every subsequent step and retry remains fail-closed even when anonymization or propagation is incomplete.

## Interfaces

- Acceptance interface: `Participation.Acceptance.accept/4` preserves its successful result and existing invitation-safety behavior, while returning a typed profile-state or identity-lifecycle conflict distinct from `:invalid_display_name` and `:display_name_taken`.
- Profile reactivation interface: a `ProjectMemberProfile` changeset transitions only a linked participant profile from `historical` to `active`, applies the newly accepted label, clears obsolete anonymization metadata, and reuses all current display-name constraints.
- Revocation acknowledgement interface: `Participation.Revocations.acknowledge/3` remains idempotent and returns the acknowledged row with both former-identity links cleared.
- Revocation retention interface: the shared retention runner reports a dedicated revocation-link cleanup count and clears remaining former links at `occurred_at <= now - 30 days`.
- Rights orchestration interface: a verified participation-anonymization operation accepts project, account, and hosted-identity scope, performs self-departure when current, then invokes verified historical anonymization and returns an explicit complete or retryable-incomplete result.
- Compatibility interface: existing current-participant, Slice 07 revocation-consumer, notification, and historical-attribution contracts continue to receive the same stable project, role, event, and history references.

## Decisions and Tradeoffs

### Reuse Linked Historical Presentation

- Choice: Reactivate the linked historical profile instead of inserting a duplicate.
- Reason: The profile is the stable project presentation and contribution-attribution reference for that account while it remains identifiable.
- Consequence: The profile identifier survives departure and rejoin, but its active label is the newly accepted value rather than the prior historical spelling.

### Anonymized History Is Never Relinked

- Choice: Treat an anonymized profile as permanently historical and create a separate active profile after a later fresh acceptance.
- Reason: Reusing the anonymized row would reverse an approved de-linking action and make past attribution linkable again.
- Consequence: One person may have an anonymous historical profile and a separate later active profile in the same project; no application path may infer or expose that relationship from presentation data.

### Earliest Of Acknowledgement Or Thirty Days

- Choice: Clear former account and hosted-identity links when the consumer acknowledges, with scheduled cleanup as a 30-day maximum.
- Reason: The consumer no longer needs those routing links after successful handling, and an unavailable consumer must not extend their retention indefinitely.
- Consequence: A consumer retry after acknowledgement or after the deadline must rely on the stable handoff identifier and non-identifying event fields rather than former-person routing data.

### Ordered Rights Transitions Remain Retryable

- Choice: Commit departure through the existing authoritative transition before invoking anonymization instead of hiding both operations in one new transaction.
- Reason: Departure must publish its durable handoff and notifications through their existing transaction, and access denial must not be rolled back because later anonymization or propagation failed.
- Consequence: A failure can leave a departed but not yet anonymized profile. The rights workflow reports that state as retryable, never as complete, and retries only the remaining anonymization work.

### Preserve Direct Active-Anonymization Refusal

- Choice: Keep the historical-anonymization primitive fail-closed for active profiles and add a separate verified orchestration path.
- Reason: This prevents an ordinary caller from bypassing the participation lifecycle while still giving an approved verified request a complete route.
- Consequence: Callers must select the verified orchestration explicitly when the requester is still active.

## Risks

- Concurrent re-acceptance could update or insert presentation twice. Lock the invitation and linked profile, retain database uniqueness constraints, and prove concurrent rollback and idempotent replay.
- A broad error mapper could still turn an account-link conflict into invalid display-name input. Classify constraint and state failures by their actual field and constraint name and cover the negative mapping directly.
- Immediate acknowledgement cleanup could break a consumer that expects former identities after it reports success. Treat acknowledgement as the terminal routing boundary and preserve the stable handoff fields needed for replay diagnostics.
- Shared retention work from other participation slices may touch `Privacy.Retention`. Task 2 owns only the revocation-link rule and must be reconciled additively rather than overwriting email-delivery or account-notification rules.
- Rights anonymization may fail after departure. Persist no success claim until anonymization completes, keep access denied, and make the incomplete state safe to retry.
- A new active profile could be correlated with anonymized history through application output. Never relink the old row, expose a relationship, or derive labels from email, account, or hosted-identity values.

## Open Questions

- None.
