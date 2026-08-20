@testable import SDDOrchestratorWorkerCore

/// A `PairingWorkScheduling` fake that runs work synchronously, on the
/// calling thread, instead of hopping to a background queue — keeps
/// `PairingFlowControllerTests` deterministic and expectation-free, the same
/// way the fake `FakePairingHTTPPoster` invokes its completion synchronously.
struct ImmediateScheduler: PairingWorkScheduling {
    func schedule(_ work: @escaping () -> Void) {
        work()
    }
}
