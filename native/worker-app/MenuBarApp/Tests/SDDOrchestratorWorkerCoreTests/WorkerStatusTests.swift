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

    // MARK: - AC-07: pairing succeeded, post-pairing setup is still pending

    func test_pairedSettingUp_showsPairedSettingUpStatusLine() {
        XCTAssertEqual(WorkerStatus.pairedSettingUp.menuStatusLine, "Paired, setting up…")
    }

    func test_pairedSettingUp_isDistinctFromNotPairedAndConnected() {
        XCTAssertNotEqual(WorkerStatus.pairedSettingUp, .notPaired)
        XCTAssertNotEqual(WorkerStatus.pairedSettingUp, .connected)
    }

    // MARK: - Paired cases (Task 9 placeholders — real UI text only)

    func test_from_paired_mapsConnectionStateThroughDirectly() {
        XCTAssertEqual(WorkerStatus.from(pairing: .paired, connection: .connected), .connected)
        XCTAssertEqual(WorkerStatus.from(pairing: .paired, connection: .disconnected), .disconnected)
        XCTAssertEqual(WorkerStatus.from(pairing: .paired, connection: .unknown), .pairedConnecting)
    }

    // MARK: - AC-07: a connected transport is not an attachment

    func test_from_paired_connectingTransport_neverReadsAsConnected() {
        let status = WorkerStatus.from(pairing: .paired, connection: .connecting)

        XCTAssertEqual(status, .pairedConnecting)
        XCTAssertNotEqual(status, .connected)
        XCTAssertEqual(status.menuStatusLine, "Connecting…")
        XCTAssertNotEqual(status.menuStatusLine, "Connected")
    }

    // MARK: - AC-08: a refusal is named, never presented as a connection

    func test_from_paired_refusedAttachment_readsAsTheRefusal() {
        let status = WorkerStatus.from(pairing: .paired, connection: .refused)

        XCTAssertEqual(status, .connectionRefused)
        XCTAssertNotEqual(status, .connected)
        XCTAssertNotEqual(status, .disconnected)
    }

    func test_connectionRefused_showsTheRefusalStatusLine() {
        XCTAssertEqual(
            WorkerStatus.connectionRefused.menuStatusLine,
            "Paired, but the control plane refused the connection"
        )
    }

    func test_connectionRefused_lineNamesNoControlPlaneDetail() {
        // The worker reports one atom, so there is no reason to render; the
        // line says a refusal happened and nothing it cannot know.
        let line = WorkerStatus.connectionRefused.menuStatusLine

        XCTAssertFalse(line.contains("—"), "product copy must not use an em dash")
        XCTAssertFalse(line.lowercased().contains("connected"))
    }

    func test_allCasesHaveNonEmptyMenuStatusLines() {
        for status in Self.allCases {
            XCTAssertFalse(status.menuStatusLine.isEmpty, "\(status) must have a non-empty menu status line")
        }
    }

    func test_menuStatusLines_areDistinctPerCase() {
        let lines = Set(Self.allCases.map(\.menuStatusLine))

        XCTAssertEqual(lines.count, Self.allCases.count, "each WorkerStatus case must render distinct menu text")
    }

    private static let allCases: [WorkerStatus] = [
        .notPaired, .pairedSettingUp, .pairedConnecting, .connected, .connectionRefused,
        .disconnected, .updateAvailable
    ]
}
