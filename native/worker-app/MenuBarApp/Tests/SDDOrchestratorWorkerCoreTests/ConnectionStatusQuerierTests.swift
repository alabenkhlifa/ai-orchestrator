import XCTest
@testable import SDDOrchestratorWorkerCore

final class ConnectionStatusQuerierTests: XCTestCase {
    private func result(output: String, exitCode: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: output, standardError: "", timedOut: timedOut)
    }

    func test_parse_connected() {
        XCTAssertEqual(ConnectionStatusQuerier.parse(result(output: "connected\n")), .connected)
    }

    func test_parse_disconnected() {
        XCTAssertEqual(ConnectionStatusQuerier.parse(result(output: "disconnected\n")), .disconnected)
    }

    func test_parse_unknownStatusString_isUnknown() {
        XCTAssertEqual(ConnectionStatusQuerier.parse(result(output: "unknown\n")), .unknown)
    }

    // MARK: - specs/39 Task 7: connected means attached

    func test_parse_connecting_isConnectingAndNeverConnected() {
        let state = ConnectionStatusQuerier.parse(result(output: "connecting\n"))

        XCTAssertEqual(state, .connecting)
        XCTAssertNotEqual(state, .connected)
    }

    func test_parse_refused_isRefusedAndNeverConnected() {
        let state = ConnectionStatusQuerier.parse(result(output: "refused\n"))

        XCTAssertEqual(state, .refused)
        XCTAssertNotEqual(state, .connected)
    }

    func test_parse_everyStatusTheWorkerCanReport_isDistinct() {
        let states = ["connected", "connecting", "refused", "disconnected", "unknown"]
            .map { ConnectionStatusQuerier.parse(result(output: $0 + "\n")) }

        XCTAssertEqual(states, [.connected, .connecting, .refused, .disconnected, .unknown])
    }

    func test_parse_unrecognizedOutput_isUnknown() {
        XCTAssertEqual(ConnectionStatusQuerier.parse(result(output: "garbage\n")), .unknown)
    }

    func test_parse_nonZeroExitOrTimeout_isUnknown() {
        XCTAssertEqual(ConnectionStatusQuerier.parse(result(output: "connected\n", exitCode: 1)), .unknown)
        XCTAssertEqual(ConnectionStatusQuerier.parse(result(output: "connected\n", timedOut: true)), .unknown)
    }

    func test_query_invokesRpc() {
        let runner = FakeCommandRunner(result: result(output: "connected\n"))

        _ = ConnectionStatusQuerier.query(workerBinaryPath: "/path/to/bin/worker", runner: runner)

        XCTAssertEqual(runner.lastExecutable, "/path/to/bin/worker")
        XCTAssertEqual(runner.lastArguments?.first, "rpc")
    }
}
