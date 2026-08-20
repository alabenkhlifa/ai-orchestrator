import XCTest
@testable import SDDOrchestratorWorkerCore

final class WorkerStatusTests: XCTestCase {
    // MARK: - AC-03: not-paired must be genuinely correct

    func test_notPaired_showsNotPairedStatusLine() {
        XCTAssertEqual(WorkerStatus.notPaired.menuStatusLine, "Not paired")
    }

    func test_from_notPairedPairingStatus_isAlwaysNotPaired_regardlessOfConnectionState() {
        XCTAssertEqual(WorkerStatus.from(pairing: .notPaired, connection: .unknown), .notPaired)
        XCTAssertEqual(WorkerStatus.from(pairing: .notPaired, connection: .connected), .notPaired)
        XCTAssertEqual(WorkerStatus.from(pairing: .notPaired, connection: .disconnected), .notPaired)
    }

    func test_from_unknownPairingStatus_failsSafeToNotPaired() {
        // A failed pairing query must never be treated as "paired" — see
        // WorkerStatus.from's doc comment.
        XCTAssertEqual(WorkerStatus.from(pairing: .unknown, connection: .unknown), .notPaired)
        XCTAssertEqual(WorkerStatus.from(pairing: .unknown, connection: .connected), .notPaired)
    }

    // MARK: - Paired cases (Task 4/9 placeholders — real UI text only)

    func test_from_paired_mapsConnectionStateThroughDirectly() {
        XCTAssertEqual(WorkerStatus.from(pairing: .paired, connection: .connected), .connected)
        XCTAssertEqual(WorkerStatus.from(pairing: .paired, connection: .disconnected), .disconnected)
        XCTAssertEqual(WorkerStatus.from(pairing: .paired, connection: .unknown), .pairedConnecting)
    }

    func test_allCasesHaveNonEmptyMenuStatusLines() {
        let allCases: [WorkerStatus] = [.notPaired, .pairedConnecting, .connected, .disconnected, .updateAvailable]

        for status in allCases {
            XCTAssertFalse(status.menuStatusLine.isEmpty, "\(status) must have a non-empty menu status line")
        }
    }

    func test_menuStatusLines_areDistinctPerCase() {
        let allCases: [WorkerStatus] = [.notPaired, .pairedConnecting, .connected, .disconnected, .updateAvailable]
        let lines = Set(allCases.map(\.menuStatusLine))

        XCTAssertEqual(lines.count, allCases.count, "each WorkerStatus case must render distinct menu text")
    }
}
