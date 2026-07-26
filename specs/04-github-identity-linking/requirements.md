# GitHub Identity Linking

## Status

Approved

## Outcome

A user with separate GitHub and passwordless hosted identities can enter one stable passwordless account after both sign-in methods are freshly proven and the merge is explicitly confirmed, while preserving every hosted project and preventing unsafe matches, partial merges, silent overwrites, or involuntary re-linking.

## Users

- Hosted passwordless users who later authenticate with GitHub.
- GitHub users whose verified identity corresponds to an existing passwordless account.
- Support and privacy personnel handling approved recovery or rights workflows.

## Primary Workflow

1. GitHub authentication returns a stable provider identity and email data under the minimum approved permission.
2. Automatic matching considers only one GitHub address marked both primary and verified.
3. Eligible ASCII addresses are compared under the approved base and exact-provider normalization rules.
4. A valid unambiguous match creates only a non-mutating candidate and requests fresh passwordless proof without exposing the candidate account's data.
5. After both sign-in methods are freshly proven, the product starts a non-mutating preflight of both hosted identities and their complete project sets.
6. Project-name or repository conflicts pause the merge for explicit recovery choices and a fresh preflight.
7. After preflight passes, the product identifies the accounts and merge consequences and requires explicit confirmation.
8. A confirmed conflict-free merge commits atomically into the existing passwordless personal workspace, preserves every project, revokes absorbed-workspace worker pairings, and reduces the absorbed workspace to the approved minimal record.
9. The linked GitHub method can later restore access to the surviving workspace if passwordless email access is lost, but it cannot change the verified email.
10. The user may later unlink GitHub only after fresh passwordless proof and explicit confirmation.
11. A later GitHub sign-in cannot undo that unlink automatically; explicit re-linking requires proof of both sign-in methods, confirmation, preflight, and repository revalidation.

## In Scope

- Verified-primary GitHub email retrieval with no secondary-email matching or retention.
- Conservative base email normalization and exact-provider alias rules for automatic matching.
- ASCII-only automatic matching at launch, including exclusion of `xn--` domain labels.
- Non-mutating automatic candidate detection.
- Fresh proof of both sign-in methods and explicit confirmation before initial identity linking.
- Idempotent user-confirmed identity linking into the stable passwordless workspace.
- Non-destructive project consolidation and atomic project-name and repository conflict preflight.
- User-confirmed name and repository conflict recovery.
- Post-merge worker-pairing revocation and explicit re-pairing.
- Immediate reduction of the absorbed workspace to a minimal inaccessible merge record.
- Preservation of the linked GitHub sign-in method without verified-email change authority.
- Fresh-passwordless-proof GitHub unlinking.
- Durable suppression of automatic re-linking after explicit unlink.
- Explicit two-proof re-linking, including when verified emails differ.
- Audit, disclosure, GDPR governance, and account-neutral failure behavior.
- First-release confirmed-merge dispute handling limited to support-assisted verified review.

## Out of Scope

- GitHub project onboarding itself, defined in `specs/01-github-project-onboarding/`.
- Magic-link delivery and general hosted-session behavior, defined in `specs/03-hosted-passwordless-access/`.
- Collaboration invitations, memberships, roles, permissions, and merge reconciliation; those require a collaboration specification before collaboration records exist.
- Automatic matching for non-ASCII local parts, Unicode domains, or IDNA-encoded domains in the first release.
- Accountless on-device project identity merging or implicit upload.
- General project deletion or repository replacement outside merge conflict recovery.
- Verified-email change, defined by `specs/03-hosted-passwordless-access/`.

## Business Rules

- Automatic candidate detection uses only the single GitHub email marked both primary and verified.
- Secondary GitHub emails never trigger matching and must not persist in application records, logs, analytics, or audit payloads.
- Missing, unverified, non-matching, or ambiguous primary results skip candidate linking without disclosing another account.
- After surrounding whitespace removal and structural validation, first-release automatic matching requires ASCII characters in both addresses and no case-insensitive `xn--` domain label.
- Ineligible internationalized addresses remain usable as separate supported sign-ins; matching must not Unicode-normalize, transliterate, remove diacritics, map confusables, or convert domain forms to manufacture a match.
- Base normalization trims surrounding whitespace, lowercases the domain, rejects internal whitespace, and preserves local-part case by default.
- Local-part case folding requires exact-domain and account-type provider documentation that case variants reach the same mailbox.
- Provider rules run in this order: approved case folding, approved period removal, then approved `+tag` stripping.
- Dot removal and `+tag` stripping are independently approved only for exact domains and account types supported by official provider documentation; custom domains never inherit a personal-domain rule.
- Alias normalization affects comparison only and never rewrites the verified address used for display, communication, or rights workflows.
- A normalized form matching multiple hosted identities stops candidate detection without account disclosure.
- Automatic matching may create only transient non-mutating candidate state. It must not expose candidate account data or change either identity, workspace, project, pairing, or repository connection.
- Initial linking requires fresh GitHub authentication and fresh passwordless proof for the matched identity.
- After both methods are proven and preflight passes, the product must identify the accounts and consequences and require explicit confirmation before commit.
- Declining, cancelling, failing proof, or leaving confirmation incomplete must preserve both separate identities and all related state.
- User-confirmed linking is idempotent and preserves the passwordless user and personal-workspace identities.
- The existence of hosted projects on both identities is normal history, not a conflict; every project and related hosted record must be retained.
- Preflight evaluates the complete combined set against case-insensitive project-name uniqueness and canonical repository uniqueness before mutation.
- Any unresolved project-name or repository conflict aborts the entire merge without changing either identity, workspace, project, pairing, or repository connection.
- A name conflict suggests the lowest available suffix `-1`, `-2`, and so on; no rename occurs until confirmation and a fresh complete preflight passes.
- A repository conflict requires the user to choose which project keeps the repository and select another authorized, valid, unlinked repository for the other project.
- Conflict choices apply only inside a retried atomic merge and never modify repository content.
- A successful merge moves every GitHub-backed hosted project into the existing passwordless workspace while preserving stable project identity, display name except confirmed conflict changes, repository connection, and related data.
- A successful merge revokes absorbed-workspace worker credentials without uninstalling workers or changing local files; explicit pairing to the surviving workspace issues new credentials.
- A failed or cancelled merge leaves all existing pairings unchanged.
- After commit, the absorbed workspace is immediately replaced by one inaccessible merge record containing only source workspace ID, surviving workspace ID, merge event ID, status, completion time, and approved deletion deadline.
- The merge record contains no project identifiers or content, repository metadata, email, credentials, sessions, worker secrets, conflict details, membership data, or analytics join keys.
- The merge record is personal data accessible only to approved idempotency, security-audit, verified-support, rights, retention, and deletion workflows. Its lawful basis and shortest necessary retention require privacy or legal approval.
- A merge the user explicitly confirmed is not reversible by self-service in the first release. A later dispute of a confirmed merge is handled only through an approved verified-support and data-subject-rights review using the audit trail and the minimal merge record; the product retains no additional absorbed-workspace state to reconstruct the merge automatically.
- Identity merging must not create, reconcile, change, or delete collaboration membership, invitation, role, or permission records.
- Candidate detection, proof, confirmation, merge attempts, and results are disclosed and auditable under the approved GDPR data contract.
- A successfully linked GitHub identity remains a sign-in method for the surviving hosted identity and workspace.
- If passwordless email access is lost, valid authentication through the already linked GitHub identity may restore account access but must not replace or change the verified email.
- A GitHub-authenticated session alone must not authorize verified-email change, GitHub unlinking, or explicit re-linking.
- GitHub unlinking requires fresh passwordless magic-link proof for the verified email on the stable identity and explicit confirmation of sign-in and repository-access consequences.
- Existing sessions, GitHub authentication, or proof for another passwordless identity cannot authorize unlinking.
- Successful unlink removes the GitHub sign-in method, revokes or deletes accepted GitHub credentials, ends GitHub-only sessions, and disconnects dependent repositories while preserving the passwordless identity, workspace, projects, data, and absorbed-workspace state.
- Failed or cancelled unlink is non-mutating.
- Successful unlink creates a minimal privacy-governed policy that blocks future automatic GitHub linking.
- Explicit re-link requires fresh GitHub authentication, fresh passwordless proof, identification and confirmation of both accounts, complete project conflict preflight, and atomic commit.
- A returned verified primary GitHub email may differ from the passwordless email during explicit re-link; automatic normalization and ASCII rules neither authorize nor reject this two-proof flow.
- Explicit re-link may proceed even when GitHub returns no verified primary email at all; fresh proof of both sign-in methods and explicit confirmation authorize re-link, and the automatic ASCII and normalization rules neither authorize nor block this two-proof path.
- Failed, cancelled, unconfirmed, or conflicted re-link attempts preserve the unlink policy and both identity boundaries.
- Re-linked repository connections remain disconnected until the new GitHub authorization is validated for each repository.
- Accountless on-device projects are never attached, uploaded, synchronized, duplicated, or assigned to a hosted identity merely because authentication or linking occurs.

## Acceptance Criteria

- Given a verified secondary GitHub email matches but the verified primary does not, when authentication completes, then no automatic link occurs and no secondary address is retained.
- Given GitHub returns no primary, an unverified primary, multiple primaries, or a non-matching primary, when authentication completes, then no automatic link or account disclosure occurs.
- Given `  User.Name@Example.COM  ` and no local-part provider rule, when normalization runs, then the comparison form is `User.Name@example.com`.
- Given local parts differ only by case on a domain without an approved case rule, when matching runs, then they remain distinct.
- Given an address contains internal whitespace, when normalization runs, then it is rejected rather than repaired.
- Given a domain approved for both rules, when `first.last+work@approved.example` and `firstlast@approved.example` are compared, then dot and tag transformations may produce a match.
- Given a custom or unknown domain, when the same variations are compared, then provider-personal-domain rules are not inherited.
- Given either address contains non-ASCII characters or an `xn--` label, when automatic matching is considered, then no Unicode or IDNA transformation or eligible candidate is produced.
- Given normalization maps to multiple identities, when matching ends, then no merge or account disclosure occurs.
- Given an unambiguous candidate is found, when passwordless proof has not succeeded, then no candidate account data is exposed and neither identity is changed.
- Given passwordless proof is invalid, expired, mismatched, or cancelled, when the attempt ends, then no merge or account disclosure occurs.
- Given both sign-in methods are freshly proven and preflight passes, when confirmation is shown, then the identified accounts and merge consequences are visible before any mutation.
- Given confirmation is declined, cancelled, or incomplete, when the attempt ends, then both identities, workspaces, projects, pairings, and repository connections remain unchanged.
- Given both sign-in methods are freshly proven, preflight passes, and the user explicitly confirms, when merge commits, then the passwordless identity and workspace survive and every hosted project is preserved exactly once.
- Given a project-name or repository conflict, when preflight runs, then no identity, workspace, project, pairing, or connection mutation occurs.
- Given `example` and `example-1` already exist, when a conflicting `example` is presented, then `example-2` is suggested without changing either project.
- Given the user confirms a name or repository recovery choice, when retry begins, then the full preflight reruns and the choice applies only inside a successful atomic commit.
- Given repository recovery is cancelled or invalid, when the attempt ends, then both projects and identities remain unchanged.
- Given the absorbed workspace has a paired worker, when merge succeeds, then the old credential is revoked, the worker and files remain, and explicit re-pairing is required.
- Given merge fails, when the old worker reconnects, then its prior pairing remains valid.
- Given merge succeeds, when retained source-workspace storage is inspected, then only the six approved merge-record fields remain and the record is absent from ordinary interfaces.
- Given the recorded merge-record data contract of fields, lawful basis, access, retention, and deletion, when implementation readiness is evaluated, then implementation may proceed while final legal confirmation of the lawful basis and exact retention remains a release-gate item.
- Given a user disputes a merge they explicitly confirmed, when recovery is requested, then no self-service un-merge is offered and the case is handled only through the approved verified-support and rights workflow using audit and merge-record evidence.
- Given passwordless email access is lost after GitHub was linked, when the linked GitHub identity authenticates successfully, then the surviving hosted identity and workspace are restored without changing the verified email.
- Given only the linked GitHub identity or its hosted session is proven, when verified-email change, GitHub unlinking, or explicit re-linking is attempted, then the operation is denied without mutation.
- Given fresh passwordless proof and confirmation, when unlink succeeds, then GitHub access is removed while the stable passwordless workspace and projects remain unchanged and dependent repositories become disconnected.
- Given unlink proof is invalid, stale, mismatched, or cancelled, when the attempt ends, then no identity, credential, session, project, or connection changes.
- Given the user later signs in with GitHub after unlinking, when authentication completes, then automatic linking remains disabled even if emails match.
- Given both sign-in methods are freshly proven, the identified accounts are confirmed, and preflight passes, when explicit re-link commits, then GitHub is attached atomically even if the verified emails differ.
- Given an explicit re-link where GitHub returns no verified primary email, when both sign-in methods are freshly proven and the user confirms, then re-link commits atomically under the two-proof rule without relying on automatic email matching.
- Given explicit re-link fails or is cancelled, when it ends, then the unlink policy and both identity boundaries remain unchanged.
- Given GitHub is re-linked, when repository connections are shown, then they remain disconnected until individually revalidated.

## Open Questions

- None.
