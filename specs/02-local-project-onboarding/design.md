# Local Project Onboarding Design

## Context

The product must support repositories that remain on the user's computer and users who do not authenticate with GitHub. The dashboard cannot directly trust or reach a local filesystem, so a paired local worker forms the repository boundary.

## Proposed Approach

Use an accountless device workspace for on-device projects. For the first executable slice, discover or graphically install a macOS worker, pair it explicitly to that workspace, open the native folder picker, and validate the selected repository locally. Before any approved onboarding metadata leaves the device for the first time, disclose the data boundary and accountless recovery limit and require confirmation. Return only minimum connection and compatibility metadata, create the project through the same stable identity, naming, and repository-uniqueness contracts as the GitHub path, then open the new project's dashboard.

Preserve projects when the worker is reinstalled or a repository moves. Replacement workers require explicit re-pairing, and moved repositories reconnect through `Locate repository` only after canonical identity matches.

Do not represent repository reconnection as recovery of lost device-workspace history. That history can be recovered only by importing a previous export; otherwise the repository starts new project history.

Hosted storage invokes the separate passwordless and storage specifications; it is not implemented implicitly by worker pairing.

Implement the local and GitHub paths as separate slices, but hold the first usable release until both paths and every shared dependency they invoke pass coordinated entry-surface verification.

## Components Affected

- Shared entry surface and local onboarding UI.
- Accountless device-workspace persistence.
- macOS local worker package, lifecycle, and status surface.
- Pairing and credential management.
- Local Git repository selection and validation.
- Project registration, naming, and connection state.
- Post-creation project-dashboard handoff.
- Combined project catalog boundary.
- Privacy, diagnostics, and security controls for device metadata.

## Data and Access Boundaries

- `DeviceWorkspace`: the accountless ownership boundary available to the current operating-system user.
- `LocalWorker`: an installed endpoint paired to one workspace with replaceable credentials.
- `PairingAttempt`: short-lived state binding one user-confirmed worker and workspace.
- `RepositoryConnection`: stable local repository identity, approved display metadata, and availability state.
- `PortableRepositoryIdentity`: a versioned, non-secret validation salt and non-reversible digest carried as the canonical local repository identifier.
- `Project`: stable project identity and display name created for one repository.

Required boundaries:

- The operating-system user and filesystem permission model is the trust boundary for accountless on-device data.
- Pairing grants one workspace access to one worker; credentials are not transferable between workspaces.
- Repository validation and source access run on the worker.
- Local paths, remote URLs, filenames, Git history, and source content do not leave the device during onboarding.
- Metadata leaving the device is limited to the minimum connection and compatibility contract and covered by an approved data contract.
- A portable repository identifier is linkable personal data wherever that exact identifier is deliberately copied. Independent onboarding generates a different identifier and creates no global repository-equality signal.
- First-use confirmation precedes outbound onboarding metadata. The disclosure remains accessible and requires confirmation again only when the disclosed handling changes.
- A repository connection does not contain enough information to reconstruct lost accountless project history; recovery requires a previous export.
- Authentication changes catalog composition, not ownership or storage of accountless projects.
- Catalog composition uses stable project identity, not repository similarity, to decide whether an item represents one project or separate projects.

## Interfaces

- Worker discovery interface: report whether a compatible paired worker is available.
- Pairing interface: create, expire, confirm, revoke, and replace a workspace-bound credential.
- Local repository interface: let the user select a path, validate Git state, generate a new portable canonical identity or match a supplied existing identity, and return only approved identity and status metadata.
- Local selection interface: open the operating system's folder picker, then display the selected repository name and location without requiring manual path entry.
- Privacy disclosure interface: before the first outbound onboarding exchange, explain what remains local, what is shared, and the accountless recovery limit; record confirmation without requiring it for every unchanged connection.
- Recovery interface: pair a replacement worker explicitly, locate a moved repository by recomputing its supplied portable identity, and upgrade a legacy workspace-scoped identity only after an exact source-side match without changing project identity or accepting a different repository as a replacement.
- Project-history recovery interface: direct users with a previous export to the import workflow and otherwise establish new history without presenting reconnection as recovery.
- Project registration interface: enforce naming and repository uniqueness and commit project plus connection atomically.
- Connection-status interface: distinguish connected, unavailable, authorization-required, and invalid states.
- Post-creation navigation interface: after atomic creation succeeds, open the new project's dashboard with its repository, storage mode, and connection status; creation failure remains in onboarding without exposing a partial dashboard.
- Catalog interface: show distinct project identities separately even when they share a repository, and show one entry for an explicitly migrated or resynchronized stable project using its authoritative storage mode.

## Decisions and Tradeoffs

### Coordinated First Usable Release

- Choice: Release the first usable version only when `Login with GitHub` and `Work without GitHub` both complete their specified onboarding paths.
- Reason: The entry surface presents both choices as primary actions, so a disabled, placeholder, or dead action would misrepresent the product.
- Consequence: The two paths retain separate specification and implementation ownership, but neither can ship alone as the first usable release. Shared entry, storage-selection, and other invoked dependency boundaries require coordinated browser proof.

### Open The New Project After Creation

- Choice: Open the newly created project's dashboard immediately after local onboarding succeeds.
- Reason: The user should arrive at the project they just connected instead of navigating back through the catalog.
- Consequence: The destination dashboard must show the linked repository, selected storage mode, and current connection status. Navigation occurs only after atomic creation commits; a failure remains in onboarding.

### macOS First Worker Slice

- Choice: Support macOS in the first executable local-worker slice, then add Windows and Linux in later slices.
- Reason: Packaging, signing, permissions, updates, and verification differ by operating system and would make the first worker slice too broad.
- Consequence: The worker boundary must remain portable, but the active implementation and verification gate cover only approved macOS versions.

### Native Repository Selection

- Choice: Select repositories through the operating system's folder picker and show the accepted repository name and location after selection.
- Reason: BA, PO, PM, and other non-technical users should not need to understand or enter filesystem paths.
- Consequence: Path access remains inside the worker and local UI boundary; outbound metadata still requires a separate approved contract.

### Explicit Recovery Without Project Loss

- Choice: Preserve projects across worker replacement and repository moves. Require explicit re-pairing for a replacement worker and canonical-identity confirmation before reconnecting a relocated repository.
- Reason: A missing worker or moved path is a recoverable connection problem, not project deletion or permission to substitute another repository.
- Consequence: The UI needs visible pairing and `Locate repository` recovery states, while the technical design must define durable workspace and repository identities.

### Explicit Local Worker

- Choice: Access local repositories through a user-installed paired worker.
- Reason: A hosted dashboard cannot safely assume direct local filesystem access.
- Consequence: Onboarding depends on packaging, installation, updates, pairing, transport, status, and revocation behavior.

### Local Means Repository Location

- Choice: Define `Work without GitHub` by repository location, not agent execution location.
- Reason: A local repository may later use a local or remote coding agent.
- Consequence: UI language and state must keep repository, project-data, worker, and agent locations distinct.

### Operating-System Trust Boundary

- Choice: Rely on the current operating-system user and filesystem permissions for accountless projects.
- Reason: Shared-device isolation is an environment responsibility for the first release.
- Consequence: Anyone with access to that boundary may access on-device project data.

### Source Stays Local

- Choice: Keep local paths, remote URLs, filenames, Git history, and source code on the device during onboarding; share only minimum connection and compatibility metadata.
- Reason: Local repositories may be private or unavailable through a hosted provider.
- Consequence: The technical data contract and canonical identity mechanism must operate within this boundary. Later agent operations require their own explicit data contract.

### First-Connection Disclosure

- Choice: Explain what remains local, what is shared, and the accountless data-loss limit before the first outbound onboarding exchange. Require confirmation once and again only if the disclosed handling changes.
- Reason: Users need an informed choice without being interrupted by the same confirmation on every connection.
- Consequence: Declining confirmation stops the exchange, while the accepted disclosure remains accessible for later review.

### Export-Only Project-History Recovery

- Choice: Recover lost accountless project history only from a previous export. Reconnecting the repository without an export starts new project history.
- Reason: Repository contents cannot reconstruct SDD decisions and project data that existed only in the lost device workspace.
- Consequence: The product must warn users about this limit and integrate recovery with the import workflow instead of implying that repository reconnection restores history.

### Stable Project Identity In The Combined Catalog

- Choice: Keep different stable projects as separate entries even when they link to the same repository. Show an explicitly migrated or resynchronized stable project once with its authoritative storage mode.
- Reason: Repository similarity does not prove that two independently owned project histories are the same project.
- Consequence: Catalog composition must use stable project identity and remain non-mutating. Exact labels and visual grouping are design decisions, but storage mode and device availability remain visible.

### Minimum Outbound Connection Contract

- Choice: The only data that leaves the device during onboarding is a fixed `RepositoryConnectionContract`: a server-generated opaque `connection_id`, the owning `workspace_id` and `worker_id`, a versioned non-reversible `repository_fingerprint` whose opaque value includes its non-secret validation salt and digest, coarse compatibility descriptors (`app_version`, `protocol_version`, `os_family`, `os_major`), and a `connection_status`. The user-chosen project name travels through project registration, not the worker payload.
- Reason: These fields authorize, deduplicate, restore, and display a connection while keeping local paths, remote URLs, filenames, Git history, and source on the device.
- Consequence: No hostname, OS username, serial number, MAC address, full path, remote URL, filename, or raw commit id is sent. The folder basename and path stay local; only the naming-rule project name the user confirms is stored server-side.

### Versioned Portable Repository Identity

- Choice: Represent a local canonical repository identity as a versioned value containing a worker-generated random per-identity validation salt and an HMAC-SHA256 digest over the repository's sorted root-commit object IDs. Creating a new connection generates a fresh salt. Matching an existing connection or restored project supplies its full canonical identifier to the worker, which parses the salt, recomputes the digest locally, and compares in constant time. The source workspace identifier is not an input and does not enter the identifier. An unborn repository remains unsupported until it has a root commit.
- Reason: A supplied salt lets an authorized target worker prove an exact repository match after same-project restoration without exposing raw commit IDs, local paths, credentials, or source workspace identity. A fresh salt for independent onboarding prevents the service from deriving global equality merely because separate workspaces chose the same repository.
- Consequence: The same identifier is linkable personal data only across records or packages where it is deliberately copied. Independently onboarded connections for the same Git history have different identifiers. Within one workspace, duplicate detection asks the worker to compare the selected repository against the workspace's existing identifiers before allocating a new one. Worktrees and clones match when tested against the same supplied identifier; a non-matching selection remains a different repository.

### Legacy Workspace-Scoped Identity Upgrade

- Choice: Treat the existing bare workspace-HMAC fingerprint as legacy and non-portable. A local project using it cannot produce a replacement-environment-ready backup until the user explicitly selects the source repository through `Locate repository`. The worker first proves the legacy match with the original workspace scope, then generates the versioned portable identity; the device store atomically replaces only that project's canonical repository identity after rechecking workspace uniqueness. Failure, mismatch, unavailability, or a uniqueness race preserves the legacy identity and blocks portable backup. A legacy package identifier is not accepted as proof of cross-workspace repository authority.
- Reason: The legacy digest does not carry the key needed by another workspace, so it cannot support exact target validation. Explicit source-side proof avoids weakening identity matching or adding source workspace identity to the package.
- Consequence: Existing projects remain visible and usable before upgrade, but portability reports an actionable source-side upgrade requirement. The upgrade changes neither project identity nor repository content or configuration. The normal source workspace can still validate its legacy value until upgrade completes.

### macOS Worker Packaging

- Choice: The first worker targets the current macOS major and the immediately previous major (floor macOS 14). It ships as a Developer ID-signed, notarized `.app` delivered in a `.dmg`, updated through a signed in-app update check (appcast), with no App Store dependency and no terminal step.
- Reason: Signing plus notarization satisfies Gatekeeper for non-technical graphical installation and updates.
- Consequence: The worker contract stays OS-portable for later Windows and Linux slices. Real signing, notarization, and update-channel proof need an Apple signing identity and the notarization service and are release-gate items; worker protocol behavior is locally verifiable through a contract test double.

### Workspace-Bound Pairing And Outbound Transport

- Choice: Pairing uses a dashboard-issued, attempt-bound, single-use pairing code that expires in minutes; on completion the server issues a per-worker credential stored only as a salted hash server-side, with the raw secret held in the worker's OS keychain. The worker communicates outbound-only over TLS via a worker-initiated persistent connection, so no inbound public port is required. Credentials are rotatable and revocable; a replacement worker re-pairs for a new credential and the old one is revoked; a credential authorizes exactly one workspace.
- Reason: Attempt binding and single use limit pairing abuse, and outbound-only transport avoids exposing the user's machine.
- Consequence: Credentials never appear in client payloads, logs, analytics, or project data; incomplete attempts expire; cross-workspace use is denied.

### Pairing Authorization Persistence

- Choice: `PairingAttempt` and `LocalWorker` authorization metadata live in the hosted control-plane database keyed by an opaque `device_workspace_id` with no foreign key to `workspaces`, because the control plane must verify inbound worker connections while accountless device roots are not hosted rows. Only the credential digest and salt, coarse compatibility descriptors, and lifecycle state are stored — never device-authoritative project data. Codes and credentials travel as an `id.secret` pair, where the id selects the row and the secret is compared in constant time against a per-row salted SHA-256 digest.
- Reason: Verifying an inbound worker requires a server-side authorization record, and this record is connection metadata within the approved outbound boundary rather than device-authoritative data.
- Consequence: Worker authorization is verifiable server-side without hosting a device workspace root or any device project data; raw codes and credentials are never persisted and are returned only once.

### On-Device Storage Seam

- Choice: This slice owns only the `on_device` storage mode from `specs/05-project-storage-lifecycle/`. The storage-mode explanation reads the storage-selection contract but implements only on-device; hosted storage selection routes to `specs/03-hosted-passwordless-access/` and `specs/05-project-storage-lifecycle/` and stays deferred. The active slice has no authentication dependency.
- Reason: Local onboarding is accountless; hosted modes need authentication and migration that are separate slices.
- Consequence: Combined-catalog and hosted-storage integrations remain deferred; only the shared entry surface and shared naming/uniqueness rules are active cross-slice dependencies.

### Device Persistence Adapter

- Choice: Accountless device-authoritative data (the device workspace, and in later tasks its projects and repository connections) is served through a `DeviceStore` behaviour and never stored in the hosted control-plane database, honoring the storage foundation's `workspaces_hosted_kind_only` constraint. The production adapter is the native macOS worker persisting under the operating-system boundary (release-gated); a durable local adapter backs development and verification.
- Reason: On-device projects are accountless and losable by design, so their authoritative data cannot live in hosted persistence keyed to an account.
- Consequence: Development and verification run against the durable local adapter, so stable access and data loss are distinct events; the native worker adapter and its packaging are release-gated. The hosted database keeps rejecting device roots, and the combined catalog composes device-store reads with hosted rows only after authentication (deferred).

### Worker Verification Strategy

- Choice: Verify with the established Slice 01 toolchain: ExUnit contract and integration tests against a protocol-compatible worker test double over the same outbound transport, security tests for the pairing lifecycle and cross-workspace denial, and Playwright (`npm --prefix assets run test:e2e`) browser scenarios for graphical installation guidance, native selection, first-connection disclosure and confirmation, and connection-state UX, all under `mix check`.
- Reason: The protocol boundary and application behavior are fully verifiable locally without a signed native binary.
- Consequence: OS-level packaging, signing, and notarization on real macOS hosts are release-gate proofs; everything else is part of the standard local gate.

### Device-Metadata Data-Protection Contract

- Choice: Treat the outbound connection contract, portable repository identifier including its non-secret validation salt, legacy fingerprint, and pairing-credential hash as personal data. Purpose is limited to establishing, maintaining, deduplicating, upgrading, and explicitly restoring the repository connection for the created project. Lawful basis is contract necessity for connection metadata and legitimate interest for pairing security events. Access is scoped to the owning workspace except when the user deliberately transfers the same canonical identifier inside an encrypted same-project backup; the credential hash is reachable only by the pairing and verification path. Retention: connection identity and compatibility for the project lifetime, credential hash until revoked or replaced, pairing attempts expired within minutes, and security-audit events bounded. Deleting the project deletes its connection, compatibility, and identifier. Analytics stay aggregate and anonymous with no repository identifier, workspace, or worker identifiers.
- Reason: Applies data minimization, purpose limitation, storage limitation, and least privilege from the specification onward.
- Consequence: Final retention durations, the hosting processor, region, and transfer safeguards (if hosted), and the required privacy review are release-gate items; the contract above is sufficient to build and locally verify.

## Risks

- Pairing compromise could grant machine access. Bind attempts and credentials to one workspace, expire incomplete attempts, and make workers visible and revocable.
- Full paths and repository metadata may reveal sensitive machine or organization information. Define and test the minimum outbound fields.
- A vague disclosure could create false expectations about locality or recovery. State the approved boundary and loss consequence before first connection and keep it available afterward.
- Users may mistake repository reconnection for project-history recovery. Distinguish connection recovery, export import, and new project history.
- Worker unavailability can make a project look deleted. Preserve the project and expose connection state separately.
- Different paths, worktrees, clones, and remotes can defeat naive duplicate detection. Define canonical local repository identity before implementation.
- Reusing one deterministic repository digest globally would create unnecessary cross-workspace linkability. Generate a fresh validation salt for independent onboarding and compare only identifiers already authorized to the current workspace or deliberately supplied through same-project restoration.
- A failed or partial legacy upgrade could detach a project or weaken uniqueness. Require exact legacy proof and one atomic identity replacement guarded by the workspace's repository constraint.
- A replacement worker or moved path could be accepted too broadly. Require explicit pairing and canonical-identity confirmation before access or reconnection.
- macOS-only delivery limits the first slice's reach. Keep the worker contract portable and specify Windows and Linux in later slices.
- Users may confuse worker location with later agent location. Use distinct labels and recovery messages.
- Accountless data can be accessed by another person sharing the same OS boundary. State this boundary without implying product-level isolation.
- Repository-based deduplication can hide an independent project or imply an unsafe merge. Use stable project identity and preserve separate entries when identities differ.
- Separate GitHub and local slices can drift at the shared entry and dependency boundaries. Verify both complete paths against the same release candidate.

## Open Questions

- Deferred after this slice: How does combined-catalog composition prove stable project identity and present separate same-repository projects clearly without mutating either boundary? Owned by the combined-catalog work deferred after this slice.
- Release gate: Real macOS signing, notarization, and update-channel verification; the hosting processor, region, and transfer safeguards if the control plane is hosted; and the final privacy review of the device-metadata and pairing-credential data contract.
