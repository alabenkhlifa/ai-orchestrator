import XCTest
@testable import SDDOrchestratorWorkerCore

final class ProtocolVersionQuerierTests: XCTestCase {
    private func result(output: String, exitCode: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: output, standardError: "", timedOut: timedOut)
    }

    func test_parse_numericOutput_returnsTrimmedString() {
        XCTAssertEqual(ProtocolVersionQuerier.parse(result(output: "1\n")), "1")
    }

    func test_parse_unknownOutput_isNil() {
        XCTAssertNil(ProtocolVersionQuerier.parse(result(output: "unknown\n")))
    }

    func test_parse_nonNumericOutput_isNil() {
        XCTAssertNil(ProtocolVersionQuerier.parse(result(output: "garbage\n")))
    }

    func test_parse_emptyOutput_isNil() {
        XCTAssertNil(ProtocolVersionQuerier.parse(result(output: "")))
    }

    func test_parse_nonZeroExit_isNil() {
        XCTAssertNil(ProtocolVersionQuerier.parse(result(output: "1\n", exitCode: 1)))
    }

    func test_parse_timedOut_isNil() {
        XCTAssertNil(ProtocolVersionQuerier.parse(result(output: "1\n", timedOut: true)))
    }

    func test_query_invokesEvalNotRpc_soItWorksBeforeTheReleaseIsRunning() {
        let runner = FakeCommandRunner(result: result(output: "1\n"))

        _ = ProtocolVersionQuerier.query(workerBinaryPath: "/path/to/bin/worker", runner: runner)

        XCTAssertEqual(runner.lastExecutable, "/path/to/bin/worker")
        XCTAssertEqual(runner.lastArguments?.first, "eval")
    }
}
