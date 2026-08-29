import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/39 Task 2 (AC-01) proof: the expression that stores a projectless
/// worker configuration names the six required fields and nothing else,
/// and carries no configuration value inline.
final class MacPairingRPCExpressionBuilderTests: XCTestCase {
    private func result(output: String, exitCode: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: output, standardError: "", timedOut: timedOut)
    }

    // MARK: - build/1

    func test_build_embedsTheGivenConfigFilePath_andReferencesTheRightElixirCalls() {
        let path = "/tmp/sdd-orchestrator-mac-pairing-ABC/config.json"
        let expression = MacPairingRPCExpressionBuilder.build(configFilePath: path)

        XCTAssertTrue(expression.contains("File.read(\"\(path)\")"))
        XCTAssertTrue(expression.contains("Jason.decode!"))
        XCTAssertTrue(expression.contains("%SddOrchestrator.Worker.Configuration{"))
        XCTAssertTrue(expression.contains("SddOrchestrator.Worker.Configuration.store"))
        XCTAssertTrue(expression.contains("SddOrchestrator.Application.worker_host_name()"))
        XCTAssertTrue(expression.contains("SddOrchestrator.Worker.Supervisor"))
        XCTAssertTrue(expression.contains("already_started"))
    }

    func test_build_readsEverySixRequiredFieldFromTheDecodedFile_neverAsALiteral() {
        // `build(configFilePath:)` takes no configuration values at all
        // (only the temp file's own path) — every required field is read
        // out of `data` (the decoded JSON file) at Elixir runtime, never
        // spliced into the expression as a Swift-side literal.
        let expression = MacPairingRPCExpressionBuilder.build(configFilePath: "/tmp/x/config.json")

        for field in [
            "control_plane_address", "device_workspace_id", "worker_credential",
            "agent_adapter", "agent_executable", "worker_id"
        ] {
            XCTAssertTrue(expression.contains("Map.fetch!(data, \"\(field)\")"), "expected \(field) to be read from the decoded file")
        }
    }

    func test_build_neverMentionsProjectOrWorkspaceRoot() {
        let expression = MacPairingRPCExpressionBuilder.build(configFilePath: "/tmp/x/config.json")

        // Both take the struct's own `nil` default. Setting them to `nil`
        // explicitly would build the same struct but read as a decision
        // this app never made: the pairing was never told about a project.
        XCTAssertFalse(expression.contains("project_id"))
        XCTAssertFalse(expression.contains("workspace_root"))
    }

    func test_build_escapesBackslashesAndQuotesInTheConfigFilePath() {
        let path = "/tmp/weird" + "\"" + "path" + "\\" + "here/config.json"
        let expression = MacPairingRPCExpressionBuilder.build(configFilePath: path)

        let expectedEscaped = "/tmp/weird" + "\\\"" + "path" + "\\\\" + "here/config.json"

        XCTAssertTrue(expression.contains("File.read(\"\(expectedEscaped)\")"))
        XCTAssertFalse(expression.contains("File.read(\"\(path)\")"), "the raw, unescaped path must never appear verbatim")
    }

    func test_build_isTheOnlyDifferenceFromTheProjectScopedExpression() {
        // The specs/36 deep-link expression must stay exactly as it was
        // verified. If this ever stops differing only by the two optional
        // fields, one of the two paths drifted.
        let path = "/tmp/x/config.json"
        let projectScoped = PostPairingRPCExpressionBuilder.build(configFilePath: path)
        let macScoped = MacPairingRPCExpressionBuilder.build(configFilePath: path)

        XCTAssertNotEqual(projectScoped, macScoped)
        XCTAssertTrue(projectScoped.contains("Map.fetch!(data, \"project_id\")"))
        XCTAssertTrue(projectScoped.contains("Map.fetch!(data, \"workspace_root\")"))
    }

    // MARK: - parse/1 (reused from the project-scoped builder, same release output)

    func test_parse_started() {
        XCTAssertEqual(MacPairingRPCExpressionBuilder.parse(result(output: "ok:started\n")), .started)
    }

    func test_parse_alreadyStarted_isItsOwnSuccessCase() {
        XCTAssertEqual(MacPairingRPCExpressionBuilder.parse(result(output: "ok:already_started\n")), .alreadyStarted)
    }

    func test_parse_errorPrefixedOutput_capturesTheReason() {
        XCTAssertEqual(MacPairingRPCExpressionBuilder.parse(result(output: "error:boom\n")), .failure("boom"))
    }

    func test_parse_nonZeroExitOrTimeoutOrGarbage_isCommandFailed() {
        XCTAssertEqual(MacPairingRPCExpressionBuilder.parse(result(output: "ok:started\n", exitCode: 1)), .commandFailed)
        XCTAssertEqual(MacPairingRPCExpressionBuilder.parse(result(output: "ok:started\n", timedOut: true)), .commandFailed)
        XCTAssertEqual(MacPairingRPCExpressionBuilder.parse(result(output: "garbage\n")), .commandFailed)
    }
}
