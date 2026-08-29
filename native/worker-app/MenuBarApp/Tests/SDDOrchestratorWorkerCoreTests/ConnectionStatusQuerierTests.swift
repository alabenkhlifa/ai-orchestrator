import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/43 Task 3 proof for AC-02: "Given Erlang distribution is
/// unavailable, when the menu is read, then it shows the same connection
/// state it would show today, including connecting, connected, refused, and
/// disconnected."
///
/// The querier runs no command any more, so these tests no longer feed it
/// canned command results. They write real files into a temp storage root
/// and read them back, which is what the app does on a machine where `rpc`
/// is refused. Every case the command-driven suite covered is kept; what
/// changes is the shape of the input, from a line on stdout to a file on
/// disk.
final class ConnectionStatusQuerierTests: XCTestCase {
    private var temporaryRoot = ""
    private var workerHome = ""

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("connection-status-querier-tests-\(UUID().uuidString)")
        workerHome = (temporaryRoot as NSString).appendingPathComponent(".sdd_orchestrator/worker")

        try FileManager.default.createDirectory(
            atPath: workerHome,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: temporaryRoot)
        try super.tearDownWithError()
    }

    /// Named here rather than asked of the type under test. The release
    /// picks this location, so the test has to state it independently for
    /// the two sides to be pinned to one path.
    private var statusFilePath: String {
        (workerHome as NSString).appendingPathComponent("connection_status.json")
    }

    private func write(_ contents: String) throws {
        try contents.write(toFile: statusFilePath, atomically: true, encoding: .utf8)
    }

    private func writeStatus(_ status: String, reason: String = "null") throws {
        try write("""
        {
          "reason": \(reason),
          "status": "\(status)",
          "updated_at": "2026-08-29T13:27:19.035632Z"
        }
        """)
    }

    private func query() -> GatewayConnectionState {
        ConnectionStatusQuerier.query(workerHomeOverride: workerHome)
    }

    // MARK: - The file is read from where the release writes it

    func test_statusFilePath_isBesideTheWorkerConfiguration() {
        XCTAssertEqual(ConnectionStatusQuerier.statusFilePath(workerHomeOverride: workerHome), statusFilePath)
        XCTAssertEqual(
            (ConnectionStatusQuerier.statusFilePath(workerHomeOverride: workerHome) as NSString)
                .deletingLastPathComponent,
            (WorkerPaths.workerConfigurationPath(homeOverride: workerHome) as NSString)
                .deletingLastPathComponent
        )
        XCTAssertTrue(
            ConnectionStatusQuerier.statusFilePath()
                .hasSuffix("/.sdd_orchestrator/worker/connection_status.json")
        )
    }

    // MARK: - Each state the release writes reads back as itself

    func test_query_connected() throws {
        try writeStatus("connected")

        XCTAssertEqual(query(), .connected)
    }

    func test_query_disconnected() throws {
        try writeStatus("disconnected")

        XCTAssertEqual(query(), .disconnected)
    }

    func test_query_unknownStatusString_isUnknown() throws {
        try writeStatus("unknown")

        XCTAssertEqual(query(), .unknown)
    }

    // MARK: - specs/39 Task 7: connected means attached

    func test_query_connecting_isConnectingAndNeverConnected() throws {
        try writeStatus("connecting")

        let state = query()

        XCTAssertEqual(state, .connecting)
        XCTAssertNotEqual(state, .connected)
    }

    func test_query_refused_isRefusedAndNeverConnected() throws {
        try writeStatus("refused", reason: "\"{:failed_to_join, :refused}\"")

        let state = query()

        XCTAssertEqual(state, .refused)
        XCTAssertNotEqual(state, .connected)
    }

    func test_query_everyStatusTheWorkerCanReport_isDistinct() throws {
        var states: [GatewayConnectionState] = []

        for status in ["connected", "connecting", "refused", "disconnected", "unknown"] {
            try writeStatus(status)
            states.append(query())
        }

        XCTAssertEqual(states, [.connected, .connecting, .refused, .disconnected, .unknown])
    }

    // MARK: - The reason is carried, never read

    func test_query_stateIsTheSameWithAReasonAndWithout() throws {
        try writeStatus("disconnected", reason: "null")
        let withoutReason = query()

        try writeStatus("disconnected", reason: "\"{:closed, :normal}\"")
        let withReason = query()

        XCTAssertEqual(withoutReason, .disconnected)
        XCTAssertEqual(withReason, .disconnected)
    }

    // MARK: - Every way of not knowing is `.unknown`, and never `.connected`

    func test_query_missingFile_isUnknown() throws {
        try FileManager.default.removeItem(atPath: workerHome)

        XCTAssertEqual(query(), .unknown)
    }

    func test_query_unreadableFile_isUnknown() throws {
        // Root reads anything, so this file could not be made unreadable
        // there and the case would fail for a reason that is not the code's.
        try XCTSkipIf(getuid() == 0, "runs as root, which can read a 0o000 file")

        try writeStatus("connected")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: statusFilePath)

        let state = query()

        XCTAssertEqual(state, .unknown)
        XCTAssertNotEqual(state, .connected)
    }

    func test_query_malformedJSON_isUnknown() throws {
        try write("{\"status\": \"connected\"")

        XCTAssertEqual(query(), .unknown)

        try write("")

        XCTAssertEqual(query(), .unknown)

        try write("[\"connected\"]")

        XCTAssertEqual(query(), .unknown)
    }

    func test_query_missingStatusKey_isUnknown() throws {
        try write("""
        {
          "reason": null,
          "updated_at": "2026-08-29T13:27:19.035632Z"
        }
        """)

        XCTAssertEqual(query(), .unknown)
    }

    func test_query_unrecognizedStatusString_isUnknown() throws {
        try writeStatus("garbage")

        let state = query()

        XCTAssertEqual(state, .unknown)
        XCTAssertNotEqual(state, .connected)
    }

    // MARK: - Pinned to the bytes the release actually writes

    /// Both sides have to agree on one file, so this case does not describe
    /// the shape in the test's own words. These are the exact bytes
    /// `ConnectionStatus`'s `encode/1` produces — `Jason.encode!(…, pretty:
    /// true)`, which sorts the keys and ends without a trailing newline —
    /// for a `:connected` transition with no reason. If the writer's output
    /// ever moves away from this, this case fails rather than the menu
    /// quietly going `.unknown` on a real machine.
    func test_query_theExactBytesTheReleaseWrites_readBack() throws {
        try write("""
        {
          "reason": null,
          "status": "connected",
          "updated_at": "2026-08-29T13:27:19.035632Z"
        }
        """)

        XCTAssertEqual(query(), .connected)
    }

    /// The same, for the transition that carries a reason: an arbitrary
    /// Elixir term rendered with `inspect/1` for display. It is a plain JSON
    /// string on this side and nothing decides anything from it.
    func test_query_theExactBytesOfARefusalWithAReason_readBack() throws {
        try write("""
        {
          "reason": "{:failed_to_join, %{\\"reason\\" => \\"unknown worker\\"}}",
          "status": "refused",
          "updated_at": "2026-08-29T13:27:19.035632Z"
        }
        """)

        XCTAssertEqual(query(), .refused)
    }
}
