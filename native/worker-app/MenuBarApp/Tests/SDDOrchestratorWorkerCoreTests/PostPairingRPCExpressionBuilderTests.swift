import XCTest
@testable import SDDOrchestratorWorkerCore

final class PostPairingRPCExpressionBuilderTests: XCTestCase {
    private func result(output: String, exitCode: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: output, standardError: "", timedOut: timedOut)
    }

    // MARK: - build/1

    func test_build_embedsTheGivenConfigFilePath_andReferencesTheRightElixirCalls() {
        let path = "/tmp/sdd-orchestrator-worker-setup-ABC/config.json"
        let expression = PostPairingRPCExpressionBuilder.build(configFilePath: path)

        XCTAssertTrue(expression.contains("File.read(\"\(path)\")"))
        XCTAssertTrue(expression.contains("Jason.decode!"))
        XCTAssertTrue(expression.contains("%SddOrchestrator.Worker.Configuration{"))
        XCTAssertTrue(expression.contains("SddOrchestrator.Worker.Configuration.store"))
        XCTAssertTrue(expression.contains("SddOrchestrator.Application.worker_host_name()"))
        XCTAssertTrue(expression.contains("SddOrchestrator.Worker.Supervisor"))
        XCTAssertTrue(expression.contains("already_started"))
    }

    func test_build_readsEveryConfigurationFieldFromTheDecodedFile_neverAsALiteral() {
        // `build(configFilePath:)` takes no configuration values at all
        // (only the temp file's own path) — every one of the eight fields
        // is read out of `data` (the decoded JSON file) at Elixir runtime,
        // never spliced into the expression as a Swift-side literal.
        let expression = PostPairingRPCExpressionBuilder.build(configFilePath: "/tmp/x/config.json")

        for field in [
            "control_plane_address", "device_workspace_id", "worker_credential",
            "agent_adapter", "agent_executable", "workspace_root", "project_id", "worker_id"
        ] {
            XCTAssertTrue(expression.contains("Map.fetch!(data, \"\(field)\")"), "expected \(field) to be read from the decoded file")
        }
    }

    func test_build_escapesBackslashesAndQuotesInTheConfigFilePath() {
        let path = "/tmp/weird" + "\"" + "path" + "\\" + "here/config.json"
        let expression = PostPairingRPCExpressionBuilder.build(configFilePath: path)

        let expectedEscaped = "/tmp/weird" + "\\\"" + "path" + "\\\\" + "here/config.json"

        XCTAssertTrue(expression.contains("File.read(\"\(expectedEscaped)\")"))
        XCTAssertFalse(expression.contains("File.read(\"\(path)\")"), "the raw, unescaped path must never appear verbatim")
    }

    // MARK: - parse/1

    func test_parse_started() {
        XCTAssertEqual(PostPairingRPCExpressionBuilder.parse(result(output: "ok:started\n")), .started)
    }

    func test_parse_alreadyStarted_isItsOwnSuccessCase() {
        XCTAssertEqual(PostPairingRPCExpressionBuilder.parse(result(output: "ok:already_started\n")), .alreadyStarted)
    }

    func test_parse_errorPrefixedOutput_capturesTheReason() {
        XCTAssertEqual(PostPairingRPCExpressionBuilder.parse(result(output: "error:boom\n")), .failure("boom"))
    }

    func test_parse_nonZeroExitOrTimeout_isCommandFailed() {
        XCTAssertEqual(PostPairingRPCExpressionBuilder.parse(result(output: "ok:started\n", exitCode: 1)), .commandFailed)
        XCTAssertEqual(PostPairingRPCExpressionBuilder.parse(result(output: "ok:started\n", timedOut: true)), .commandFailed)
    }

    func test_parse_unrecognizedOutput_isCommandFailed() {
        XCTAssertEqual(PostPairingRPCExpressionBuilder.parse(result(output: "garbage\n")), .commandFailed)
    }
}
