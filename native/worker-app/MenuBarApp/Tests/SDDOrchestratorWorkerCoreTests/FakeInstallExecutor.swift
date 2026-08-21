import Foundation
@testable import SDDOrchestratorWorkerCore

/// An `InstallExecuting` fake: records whether/how it was called and
/// returns a canned result, so `UpdateInstallCoordinatorTests` can assert
/// the real helper hand-off (real `Process` spawn, real `hdiutil`/`mv`) is
/// never exercised by a unit test while still proving the orchestration
/// calls it at exactly the right moment with exactly the right arguments.
final class FakeInstallExecutor: InstallExecuting {
    private(set) var callCount = 0
    private(set) var lastArtifact: PendingUpdateArtifact?
    private(set) var lastRunningAppBundlePath: String?

    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func beginInstall(artifact: PendingUpdateArtifact, runningAppBundlePath: String) -> Bool {
        callCount += 1
        lastArtifact = artifact
        lastRunningAppBundlePath = runningAppBundlePath
        return result
    }
}
