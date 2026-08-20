import XCTest
@testable import SDDOrchestratorWorkerCore

final class PairingStatusCheckerTests: XCTestCase {
    private func result(output: String, exitCode: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: output, standardError: "", timedOut: timedOut)
    }

    func test_parse_paired() {
        XCTAssertEqual(PairingStatusChecker.parse(result(output: "paired\n")), .paired)
    }

    func test_parse_notPaired() {
        XCTAssertEqual(PairingStatusChecker.parse(result(output: "not_paired\n")), .notPaired)
    }

    func test_parse_unrecognizedOutput_isUnknown() {
        XCTAssertEqual(PairingStatusChecker.parse(result(output: "garbage\n")), .unknown)
    }

    func test_parse_nonZeroExit_isUnknown() {
        XCTAssertEqual(PairingStatusChecker.parse(result(output: "paired\n", exitCode: 1)), .unknown)
    }

    func test_parse_timedOut_isUnknown() {
        XCTAssertEqual(PairingStatusChecker.parse(result(output: "paired\n", timedOut: true)), .unknown)
    }

    func test_check_invokesEvalNotRpc_soItWorksBeforeTheReleaseIsRunning() {
        let runner = FakeCommandRunner(result: result(output: "not_paired\n"))

        _ = PairingStatusChecker.check(workerBinaryPath: "/path/to/bin/worker", runner: runner)

        XCTAssertEqual(runner.lastExecutable, "/path/to/bin/worker")
        XCTAssertEqual(runner.lastArguments?.first, "eval")
    }
}
