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
}
