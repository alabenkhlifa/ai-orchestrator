import XCTest
@testable import SDDOrchestratorWorkerCore

final class WorkerPathsTests: XCTestCase {
    func test_workerBinaryPath_appendsReleaseBinWorker() {
        let path = WorkerPaths.workerBinaryPath(
            resourcePath: "/Applications/SDD Orchestrator Worker.app/Contents/Resources"
        )

        XCTAssertEqual(
            path,
            "/Applications/SDD Orchestrator Worker.app/Contents/Resources/release/bin/worker"
        )
    }

    // MARK: - [specs/43 Task 4, AC-01] The storage root the app now writes into

    func test_workerHome_withoutAnOverride_isTheReleaseSOwnDefault() {
        // `SddOrchestrator.Worker.Configuration.home/1` resolves
        // `~/.sdd_orchestrator/worker`, and the app has to write where the
        // release reads.
        XCTAssertTrue(WorkerPaths.workerHome().hasSuffix("/.sdd_orchestrator/worker"))
        XCTAssertTrue(WorkerPaths.workerHome().hasPrefix("/"))
    }

    func test_workerHome_withAnOverride_isTheOverride() {
        XCTAssertEqual(WorkerPaths.workerHome(override: "/tmp/worker-home"), "/tmp/worker-home")
    }

    func test_workerConfigurationPath_isWorkerJsonUnderTheStorageRoot() {
        XCTAssertEqual(
            WorkerPaths.workerConfigurationPath(homeOverride: "/tmp/worker-home"),
            "/tmp/worker-home/worker.json"
        )
        XCTAssertTrue(WorkerPaths.workerConfigurationPath().hasSuffix("/.sdd_orchestrator/worker/worker.json"))
    }
}
