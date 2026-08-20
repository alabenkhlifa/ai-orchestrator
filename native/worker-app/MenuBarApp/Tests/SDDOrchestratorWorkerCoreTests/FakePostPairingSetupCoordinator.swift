@testable import SDDOrchestratorWorkerCore

/// A `PostPairingSetupCoordinator` fake: records whether/how it was called,
/// so `PairingFlowControllerTests` can assert the extension point receives
/// exactly the right data on success, and is never called on failure.
final class FakePostPairingSetupCoordinator: PostPairingSetupCoordinator {
    private(set) var callCount = 0
    private(set) var lastCredential: String?
    private(set) var lastWorker: WorkerIdentity?
    private(set) var lastProjectID: String?

    func beginPostPairingSetup(credential: String, worker: WorkerIdentity, projectID: String) {
        callCount += 1
        lastCredential = credential
        lastWorker = worker
        lastProjectID = projectID
    }
}
