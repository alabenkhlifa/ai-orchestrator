import Foundation

/// **specs/36 Task 5's extension point.** Everything after a credential and
/// worker identity are obtained — a repository-path picker, coding-agent
/// detection, `SddOrchestrator.Worker.Configuration.store`, starting
/// `SddOrchestrator.Worker.Supervisor` — is out of Task 4's scope. This
/// task (Task 4) only defines where that work plugs in and hands it exactly
/// the three things pairing produced: the issued credential, the paired
/// worker's identity, and the `project_id` the pairing URL carried.
///
/// `AppDelegate` holds one instance of this and never calls
/// `Configuration.store`/`Worker.Supervisor` itself (see specs/36 Task 4's
/// brief). The menu bar stays on "Paired, setting up…" for as long as no
/// implementation calls back to change it — which, until Task 5 exists, is
/// forever.
public protocol PostPairingSetupCoordinator: AnyObject {
    func beginPostPairingSetup(credential: String, worker: WorkerIdentity, projectID: String)
}

/// The only implementation until Task 5 lands: logs once and does nothing
/// else. Deliberately inert — no `Configuration.store`, no
/// `Worker.Supervisor`, no menu-bar change of its own.
public final class UnimplementedPostPairingSetupCoordinator: PostPairingSetupCoordinator {
    public init() {}

    public func beginPostPairingSetup(credential: String, worker: WorkerIdentity, projectID: String) {
        FileHandle.standardError.write(
            Data("SDD Orchestrator Worker: post-pairing setup not yet implemented (specs/36 Task 5)\n".utf8)
        )
    }
}
