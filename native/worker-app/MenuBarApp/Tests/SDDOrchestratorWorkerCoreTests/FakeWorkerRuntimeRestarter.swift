import Foundation
@testable import SDDOrchestratorWorkerCore

/// [specs/43 Task 4, AC-01] A `WorkerRuntimeRestarting` fake: counts the
/// restarts asked of it and answers a canned result, so a test can prove
/// the pairing paths start the worker by restarting the release the app
/// owns instead of calling into a node that needs Erlang distribution.
///
/// `onRestart` fires synchronously at the moment the real restart would
/// happen, which is what lets a test read the configuration file the way
/// the rebooting release would read it — after the write, before the call
/// returns.
final class FakeWorkerRuntimeRestarter: WorkerRuntimeRestarting {
    private(set) var restartCount = 0

    /// What `restartWorkerRuntime()` answers. `false` is a release that
    /// did not come back up.
    var result: Bool

    /// Invoked synchronously on each restart, before the answer is
    /// returned.
    var onRestart: (() -> Void)?

    init(result: Bool = true) {
        self.result = result
    }

    func restartWorkerRuntime() -> Bool {
        restartCount += 1
        onRestart?()
        return result
    }
}
