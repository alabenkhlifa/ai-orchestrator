import XCTest
@testable import SDDOrchestratorWorkerCore

final class RunStateQuerierTests: XCTestCase {
    private func result(output: String, exitCode: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: output, standardError: "", timedOut: timedOut)
    }

    func test_parse_none_isSuccessWithNilLifecycle() {
        XCTAssertEqual(RunStateQuerier.parse(result(output: "none\n")), .success(currentLifecycle: nil))
    }

    func test_parse_knownLifecycle_isSuccessWithThatLifecycle() {
        XCTAssertEqual(RunStateQuerier.parse(result(output: "accepted\n")), .success(currentLifecycle: "accepted"))
        XCTAssertEqual(RunStateQuerier.parse(result(output: "blocked\n")), .success(currentLifecycle: "blocked"))
        XCTAssertEqual(RunStateQuerier.parse(result(output: "stopped\n")), .success(currentLifecycle: "stopped"))
    }

    func test_parse_error_isQueryFailed() {
        XCTAssertEqual(RunStateQuerier.parse(result(output: "error\n")), .queryFailed)
    }

    func test_parse_emptyOutput_isQueryFailed() {
        XCTAssertEqual(RunStateQuerier.parse(result(output: "")), .queryFailed)
    }

    func test_parse_nonZeroExit_isQueryFailedRegardlessOfOutput() {
        XCTAssertEqual(RunStateQuerier.parse(result(output: "accepted\n", exitCode: 1)), .queryFailed)
    }

    func test_parse_timedOut_isQueryFailedRegardlessOfOutput() {
        XCTAssertEqual(RunStateQuerier.parse(result(output: "accepted\n", timedOut: true)), .queryFailed)
    }

    func test_query_invokesRpcWithTheWorkerBinaryAndTheExpectedArguments() {
        let runner = FakeCommandRunner(result: result(output: "none\n"))

        _ = RunStateQuerier.query(workerBinaryPath: "/path/to/bin/worker", runner: runner, timeout: 3)

        XCTAssertEqual(runner.callCount, 1)
        XCTAssertEqual(runner.lastExecutable, "/path/to/bin/worker")
        XCTAssertEqual(runner.lastArguments?.first, "rpc")
        XCTAssertEqual(runner.lastArguments?.count, 2)
    }
}
