import XCTest
@testable import SDDOrchestratorWorkerCore

final class PostPairingSetupCoordinatorImplTests: XCTestCase {
    private let dashboardURL = URL(string: "http://localhost:4000")!
    private let workerBinaryPath = "/path/to/bin/worker"

    private let worker = WorkerIdentity(
        id: "worker-1",
        deviceWorkspaceID: "ws-1",
        osFamily: "macos",
        osMajor: "15",
        protocolVersion: "1",
        appVersion: "1.0.0",
        state: "active"
    )

    private func startedResult() -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: "ok:started\n", standardError: "", timedOut: false)
    }

    private func makeRunner(rpcResult: CommandResult) -> FakeWorkerRPCCommandRunner {
        FakeWorkerRPCCommandRunner(workerBinaryPath: workerBinaryPath, rpcResult: rpcResult)
    }

    private func makeCoordinator(
        commandRunner: CommandRunning,
        executableChecker: ExecutableChecking = FakeExecutableChecker(executablePaths: ["/usr/local/bin/claude"]),
        folderPicker: WorkspaceFolderPicking,
        agentSelectionPrompt: AgentSelectionPrompting
    ) -> PostPairingSetupCoordinatorImpl {
        PostPairingSetupCoordinatorImpl(
            dashboardURL: dashboardURL,
            workerBinaryPath: workerBinaryPath,
            commandRunner: commandRunner,
            executableChecker: executableChecker,
            folderPicker: folderPicker,
            agentSelectionPrompt: agentSelectionPrompt
        )
    }

    // MARK: - AC-19: folder-picker cancel aborts cleanly

    func test_beginPostPairingSetup_folderPickerCanceled_abortsWithoutDetectingOrPromptingOrRunningRpc() {
        let runner = makeRunner(rpcResult: startedResult())
        let folderPicker = FakeWorkspaceFolderPicker(result: nil)
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(commandRunner: runner, folderPicker: folderPicker, agentSelectionPrompt: prompt)

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(runner.whichCallCount, 0, "canceling the folder picker must abort before agent detection ever runs")
        XCTAssertEqual(prompt.callCount, 0)
        XCTAssertEqual(runner.rpcCallCount, 0)
    }

    // MARK: - AC-20: agent-selection cancel (auto-detection found none) aborts cleanly

    func test_beginPostPairingSetup_agentSelectionCanceledAfterNoneDetected_abortsWithoutRunningRpc() {
        let runner = makeRunner(rpcResult: startedResult())
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            executableChecker: FakeExecutableChecker(executablePaths: []),
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(prompt.callCount, 1)
        XCTAssertEqual(prompt.lastDetected, [])
        XCTAssertEqual(runner.rpcCallCount, 0)
    }

    // MARK: - Exactly one auto-detected: the fallback prompt is never invoked

    func test_beginPostPairingSetup_exactlyOneAgentDetected_neverInvokesFallbackPrompt() {
        let runner = makeRunner(rpcResult: startedResult())
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            executableChecker: FakeExecutableChecker(executablePaths: ["/usr/local/bin/claude"]),
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(prompt.callCount, 0)
        XCTAssertEqual(runner.rpcCallCount, 1)
    }

    // MARK: - Both found: the fallback prompt receives both candidates

    func test_beginPostPairingSetup_bothAgentsDetected_invokesFallbackPromptWithBothCandidates() {
        let runner = makeRunner(rpcResult: startedResult())
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let bothDetected = [
            DetectedAgent(adapter: "claude_code", executablePath: "/usr/local/bin/claude"),
            DetectedAgent(adapter: "codex", executablePath: "/usr/local/bin/codex")
        ]
        let prompt = FakeAgentSelectionPrompt(result: bothDetected[0])
        let coordinator = makeCoordinator(
            commandRunner: runner,
            executableChecker: FakeExecutableChecker(executablePaths: ["/usr/local/bin/claude", "/usr/local/bin/codex"]),
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(prompt.callCount, 1)
        XCTAssertEqual(prompt.lastDetected, bothDetected)
        XCTAssertEqual(runner.whichCallCount, 0, "both being found via common paths must skip which entirely")
        XCTAssertEqual(runner.rpcCallCount, 1)
    }

    // MARK: - Happy path: rpc invoked correctly, credential never leaks into the command arguments

    func test_beginPostPairingSetup_happyPath_invokesRpcAgainstTheWorkerBinary_withoutLeakingTheCredential() {
        let runner = makeRunner(rpcResult: startedResult())
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(commandRunner: runner, folderPicker: folderPicker, agentSelectionPrompt: prompt)

        let credential = "worker-1.super-secret-credential"
        coordinator.beginPostPairingSetup(credential: credential, worker: worker, projectID: "proj-1")

        XCTAssertEqual(runner.rpcCallCount, 1)
        XCTAssertEqual(runner.lastRPCArguments?.first, "rpc")
        XCTAssertFalse(
            (runner.lastRPCArguments ?? []).joined().contains(credential),
            "the credential must never be spliced into the rpc expression"
        )
        XCTAssertFalse(
            (runner.lastRPCArguments ?? []).joined().contains("/Users/dev/repo"),
            "the workspace path must never be spliced into the rpc expression either"
        )
    }

    // MARK: - AC-21 idempotency: {:error, {:already_started, _}} is treated as success

    func test_beginPostPairingSetup_alreadyStarted_isTreatedAsSuccess_doesNotCrashOrRetry() {
        let runner = makeRunner(
            rpcResult: CommandResult(exitCode: 0, standardOutput: "ok:already_started\n", standardError: "", timedOut: false)
        )
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(commandRunner: runner, folderPicker: folderPicker, agentSelectionPrompt: prompt)

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(runner.rpcCallCount, 1)
    }

    // MARK: - rpc failure does not crash

    func test_beginPostPairingSetup_rpcReportsFailure_doesNotCrash() {
        let runner = makeRunner(
            rpcResult: CommandResult(exitCode: 0, standardOutput: "error:boom\n", standardError: "", timedOut: false)
        )
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(commandRunner: runner, folderPicker: folderPicker, agentSelectionPrompt: prompt)

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(runner.rpcCallCount, 1)
    }

    // MARK: - The temporary config file exists while rpc runs, and is cleaned up afterward

    func test_beginPostPairingSetup_writesTheConfigFileBeforeRpc_andRemovesItAfterward() {
        let runner = makeRunner(rpcResult: startedResult())
        var observedConfigPath: String?

        runner.onRPCCall = { arguments in
            guard
                let expression = arguments.last,
                let range = expression.range(of: "File.read(\""),
                let endQuote = expression[range.upperBound...].firstIndex(of: "\"")
            else { return }

            let path = String(expression[range.upperBound..<endQuote])
            observedConfigPath = path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the config file must exist while rpc is being invoked")
        }

        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(commandRunner: runner, folderPicker: folderPicker, agentSelectionPrompt: prompt)

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        guard let configPath = observedConfigPath else {
            return XCTFail("expected the rpc expression to embed a config file path")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: configPath),
            "the temporary config file must be removed once the rpc call returns"
        )
    }
}
