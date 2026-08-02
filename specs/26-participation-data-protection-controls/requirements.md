# Participation Data Protection Controls

## Status

Approved

## Outcome

Invitation and project-participation data is processed only for the approved participation service or minimum security and support purpose, remains available only to authorized recipients, excludes secrets and unauthorized project content, and is never reused for advertising, model training, unrelated improvement, linkable analytics, or another secondary purpose.

## Users

- Hosted-project owners and participants whose invitation, membership, notification, and derived data is processed.
- Authorized operations and verified support personnel diagnosing the participation service under restricted access.
- Privacy and security reviewers checking purpose, access, processor, transfer, and secondary-use controls.

## In Scope

- A complete participation processing inventory and purpose or lawful-basis map.
- Lifecycle classification that consumes the final participation identity, revocation, retention, and rights contract without redefining it.
- Owner, participant, operations, and exceptional-support access boundaries.
- Verified, least-privilege, time-bounded, purpose-limited, audited support elevation.
- Processor and transfer configuration for participation data.
- Account-neutral invitation and identity enumeration resistance.
- Secret, credential, and unauthorized project-content exclusion or redaction.
- Prohibition of advertising, model-training reuse, unrelated product improvement, and other secondary use.
- A genuinely anonymous aggregate boundary with no linkable participant, project, account, device, repository, network, invitation, or notification identifiers.

## Out of Scope

- Implementing invitation, participation, revocation, retention, deletion, rights, anonymization, notification, or email-delivery lifecycle behavior owned by other specifications.
- Changing owner, participant, or recipient-routing authorization supplied by the participation boundary.
- Creating a searchable user directory, social graph, product analytics store, or stable pseudonymous analytics profile.
- Deployment-specific processor agreements, controller details, regions, transfer safeguards, notices, incidents, DPIA state, legal conclusions, or accountable release approval.

## Primary Workflow

1. Participation data enters an invitation, proof, membership, profile, revocation, notification, delivery, support, security, or derived-record path.
2. The processing inventory identifies the minimum fields, service or security purpose, lawful basis, authority, authorized recipients, lifecycle owner, processors, and transfer classification.
3. The current participation boundary or restricted operations and support policy authorizes the request before optional presentation or content lookup.
4. Minimization rejects secrets, credentials, unauthorized project content, and fields outside the approved recipient context before persistence or transmission.
5. Purpose-limitation proof rejects unapproved processors, transfers, secondary use, linkable analytics, and any attempt to treat governed telemetry as anonymous data.

## Business Rules

- User-requested invitation, proof, participation, notification, and rights processing is limited to contract necessity. Minimum fraud, abuse, security, audit, operations, and support processing is limited to its documented legitimate-interest purpose and assessment.
- Every participation field and transfer has one recorded purpose, lawful basis, authority, minimum field set, access boundary, lifecycle owner, processor category, transfer classification, and review state.
- Lifecycle inventory entries consume the approved `capability:participation-identity-lifecycle`; this specification does not extend, weaken, or reinterpret its revocation, retention, deletion, rights, attribution-necessity, or anonymization rules.
- Owners receive only the membership-management data already approved for their project. Participants receive only their own account context and approved project labels. Stale, removed, departed, absent, and cross-project identities fail closed.
- Invitation creation, proof, denial, and failure results remain account-neutral and do not reveal whether an email, account, hosted identity, invitation, or former membership exists.
- Operations access is limited to necessary minimized service and security metadata. Support access is content-free by default; an exception requires verified authority, one incident purpose, least privilege, a fixed expiry, explicit revocation, and a minimized audit record.
- Processor and transfer configuration permits only approved destinations and minimum fields. Deployment-specific agreements, regions, safeguards, and accountable review remain release evidence.
- Participation data never transfers repository-provider, worker, coding-agent, model-provider, session, invitation, or email-delivery credentials.
- Raw secrets, unauthorized project content, participant emails outside the approved membership context, and unrelated identity data are rejected or removed before logs, support records, processor requests, exports, or participant-visible output are created.
- Participation data is not used for advertising, model training, unrelated product improvement, product analytics, or another secondary purpose.
- Any future measurement must receive only genuinely anonymous aggregate output and no raw or linkable participation data. Operational telemetry remains governed personal data when it contains a stable or linkable identifier.

## Acceptance Criteria

- [AC-01] Given any participation field or transfer, when the processing inventory is inspected, then its minimum fields, service or security purpose, lawful basis, authority, authorized recipients, lifecycle owner, processor category, transfer classification, and review state are recorded, match the approved identity lifecycle, and no participation processing is unclassified.
- [AC-02] Given an owner, participant, operations actor, stale member, removed or departed member, absent identity, or cross-project identity requests participation data, when access is evaluated, then only the approved project-scoped or minimized operations view is returned and every denial remains account-neutral without disclosing content or identity existence.
- [AC-03] Given support requests participation data, when the support boundary is evaluated, then access is content-free by default and any exception requires verified authority, least privilege, one purpose and scope, a fixed expiry, revocation, and a minimized audit record.
- [AC-04] Given participation data crosses persistence, notification, delivery, support, logging, export, or processor boundaries, when minimization runs, then credentials, secrets, unauthorized project content, out-of-context participant emails, and unrelated identities are rejected or removed before the boundary is crossed.
- [AC-05] Given participation stores, requests, events, metrics, processors, transfers, or destinations are inspected, when purpose limitation is verified, then no advertising, model-training reuse, unrelated improvement, product analytics, stable pseudonymous profile, or other secondary use exists, and any aggregate measurement boundary accepts no linkable identifier or raw participation data.

## Open Questions

- None.
