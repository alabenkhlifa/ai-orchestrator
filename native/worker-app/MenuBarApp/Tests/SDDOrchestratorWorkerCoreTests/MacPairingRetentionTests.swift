import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/39 Task 2 proof for AC-01: "Given the dashboard redeemed this
/// app's pairing code, when the app completes pairing, then it stores the
/// issued credential and worker identity and reports no project, without
/// asking the person for one."
///
/// **On "without asking the person for one":** there is deliberately no
/// test that a folder picker went uncalled, because `MacPairingRetention`
/// has no folder picker and no project parameter to begin with. `retain`
/// takes a credential and a worker identity and nothing else, and the
/// initializer takes no `WorkspaceFolderPicking`. The type's own shape is
/// the guarantee — a run-time check would only prove that a seam nobody
/// wired stayed unused. What is checked below instead is the observable
/// half of the same promise: what reaches disk carries no `project_id` and
/// no `workspace_root`.
final class MacPairingRetentionTests: XCTestCase {
    private let controlPlaneURL = URL(string: "http://localhost:4000")!
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

    private let agent = DetectedAgent(adapter: "claude_code", executablePath: "/usr/local/bin/claude")

    private func startedResult() -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: "ok:started\n", standardError: "", timedOut: false)
    }

    private func makeRunner(rpcResult: CommandResult) -> FakeWorkerRPCCommandRunner {
        FakeWorkerRPCCommandRunner(workerBinaryPath: workerBinaryPath, rpcResult: rpcResult)
    }

    private func makeRetention(
        commandRunner: CommandRunning,
        agentResolver: MacCodingAgentResolving
    ) -> MacPairingRetention {
        MacPairingRetention(
            controlPlaneURL: controlPlaneURL,
            workerBinaryPath: workerBinaryPath,
            commandRunner: commandRunner,
            agentResolver: agentResolver
        )
    }

    /// Pulls the temp config path out of the `File.read("…")` the
    /// expression embeds, exactly the way
    /// `PostPairingSetupCoordinatorImplTests` does.
    private func configPath(in expression: String) -> String? {
        guard
            let range = expression.range(of: "File.read(\""),
            let endQuote = expression[range.upperBound...].firstIndex(of: "\"")
        else { return nil }

        return String(expression[range.upperBound..<endQuote])
    }

    // MARK: - AC-01: a completed redemption stores the credential and worker identity, with no project

    func test_retain_resolvableAgent_storesTheCredentialAndTheWorkerIdentityWithNoProject() {
        let runner = makeRunner(rpcResult: startedResult())
        var storedConfig: [String: Any]?

        // The temp file only exists while rpc is being invoked (it is
        // cleaned up on the way out), so it is read here, at the moment the
        // real `bin/worker rpc` would read it.
        runner.onRPCCall = { [weak self] arguments in
            guard
                let self,
                let expression = arguments.last,
                let path = self.configPath(in: expression),
                let data = FileManager.default.contents(atPath: path)
            else { return XCTFail("expected a readable config file while rpc runs") }

            storedConfig = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        let retention = makeRetention(
            commandRunner: runner,
            agentResolver: FakeMacCodingAgentResolver(result: agent)
        )

        let stored = retention.retain(credential: "worker-1.super-secret-credential", worker: worker)

        XCTAssertTrue(stored)
        // The fake only counts an rpc call when the executable is the
        // worker binary itself, so this also proves the store went through
        // the embedded release rather than any other process.
        XCTAssertEqual(runner.rpcCallCount, 1)
        XCTAssertEqual(runner.lastRPCArguments?.first, "rpc")
        XCTAssertEqual(runner.whichCallCount, 0, "retention resolves the agent through its seam and shells out to nothing else")

        guard let storedConfig else { return XCTFail("expected the rpc call to see a decodable config file") }

        XCTAssertEqual(storedConfig["worker_credential"] as? String, "worker-1.super-secret-credential")
        XCTAssertEqual(storedConfig["worker_id"] as? String, "worker-1")
        XCTAssertEqual(storedConfig["device_workspace_id"] as? String, "ws-1")
        XCTAssertEqual(storedConfig["control_plane_address"] as? String, "http://localhost:4000")
        XCTAssertEqual(storedConfig["agent_adapter"] as? String, "claude_code")
        XCTAssertEqual(storedConfig["agent_executable"] as? String, "/usr/local/bin/claude")

        // Reports no project: absent keys, not empty strings and not nulls.
        XCTAssertFalse(storedConfig.keys.contains("project_id"))
        XCTAssertFalse(storedConfig.keys.contains("workspace_root"))
    }

    func test_retain_neverPutsTheCredentialOrTheWorkerIdentityIntoTheCommandArguments() {
        let runner = makeRunner(rpcResult: startedResult())
        let retention = makeRetention(
            commandRunner: runner,
            agentResolver: FakeMacCodingAgentResolver(result: agent)
        )

        let credential = "worker-1.super-secret-credential"
        retention.retain(credential: credential, worker: worker)

        let arguments = (runner.lastRPCArguments ?? []).joined()
        XCTAssertFalse(arguments.contains(credential), "the credential must never be spliced into the rpc expression")
        XCTAssertFalse(arguments.contains("ws-1"), "no configuration value belongs in the command arguments")
        XCTAssertFalse(arguments.contains("/usr/local/bin/claude"))
    }

    // MARK: - Nothing is half-stored

    func test_retain_unresolvedAgent_storesNothingAndRunsNoCommandAtAll() {
        let runner = makeRunner(rpcResult: startedResult())
        let resolver = FakeMacCodingAgentResolver(result: nil)
        let retention = makeRetention(commandRunner: runner, agentResolver: resolver)

        let stored = retention.retain(credential: "worker-1.secret", worker: worker)

        XCTAssertFalse(stored)
        XCTAssertEqual(resolver.callCount, 1)
        XCTAssertEqual(runner.rpcCallCount, 0, "an unresolved coding agent must stop before anything is written")
        XCTAssertEqual(runner.whichCallCount, 0)
        XCTAssertNil(runner.lastRPCArguments)
    }

    // MARK: - The temporary file never outlives the call

    func test_retain_removesTheTemporaryDirectory_afterASuccessfulStore() {
        assertTemporaryDirectoryIsRemoved(afterRPCAnswering: startedResult())
    }

    func test_retain_removesTheTemporaryDirectory_afterAFailedStore() {
        assertTemporaryDirectoryIsRemoved(
            afterRPCAnswering: CommandResult(exitCode: 0, standardOutput: "error:boom\n", standardError: "", timedOut: false)
        )
    }

    private func assertTemporaryDirectoryIsRemoved(
        afterRPCAnswering rpcResult: CommandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let runner = makeRunner(rpcResult: rpcResult)
        var observedConfigPath: String?

        runner.onRPCCall = { [weak self] arguments in
            guard let self, let expression = arguments.last, let path = self.configPath(in: expression) else { return }

            observedConfigPath = path
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "the config file must exist while rpc is being invoked",
                file: file,
                line: line
            )
        }

        let retention = makeRetention(
            commandRunner: runner,
            agentResolver: FakeMacCodingAgentResolver(result: agent)
        )

        retention.retain(credential: "worker-1.secret", worker: worker)

        guard let configPath = observedConfigPath else {
            return XCTFail("expected the rpc expression to embed a config file path", file: file, line: line)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: configPath),
            "the temporary config file must be removed once the rpc call returns",
            file: file,
            line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: (configPath as NSString).deletingLastPathComponent),
            "the per-run temporary directory must be removed too",
            file: file,
            line: line
        )
    }

    // MARK: - What the release answers

    func test_retain_alreadyStarted_countsAsStored() {
        // The pairing loop can complete more than once across a launch and
        // `Configuration.store/2` overwrites, so an already-running
        // supervisor means the configuration is on disk, not that the store
        // failed.
        let runner = makeRunner(
            rpcResult: CommandResult(exitCode: 0, standardOutput: "ok:already_started\n", standardError: "", timedOut: false)
        )
        let retention = makeRetention(
            commandRunner: runner,
            agentResolver: FakeMacCodingAgentResolver(result: agent)
        )

        XCTAssertTrue(retention.retain(credential: "worker-1.secret", worker: worker))
        XCTAssertEqual(runner.rpcCallCount, 1)
    }

    func test_retain_reportedFailure_isNotStored_andDoesNotCrash() {
        let runner = makeRunner(
            rpcResult: CommandResult(exitCode: 0, standardOutput: "error:boom\n", standardError: "", timedOut: false)
        )
        let retention = makeRetention(
            commandRunner: runner,
            agentResolver: FakeMacCodingAgentResolver(result: agent)
        )

        XCTAssertFalse(retention.retain(credential: "worker-1.secret", worker: worker))
        XCTAssertEqual(runner.rpcCallCount, 1)
    }

    func test_retain_commandFailure_isNotStored_andDoesNotCrash() {
        for rpcResult in [
            CommandResult(exitCode: 1, standardOutput: "", standardError: "boom", timedOut: false),
            CommandResult(exitCode: -1, standardOutput: "", standardError: "", timedOut: true),
            CommandResult(exitCode: 0, standardOutput: "garbage\n", standardError: "", timedOut: false)
        ] {
            let runner = makeRunner(rpcResult: rpcResult)
            let retention = makeRetention(
                commandRunner: runner,
                agentResolver: FakeMacCodingAgentResolver(result: agent)
            )

            XCTAssertFalse(retention.retain(credential: "worker-1.secret", worker: worker))
            XCTAssertEqual(runner.rpcCallCount, 1)
        }
    }

    // MARK: - The stand-in Task 3 replaces

    func test_unresolvedMacCodingAgent_resolvesNothing_soNothingIsStoredYet() {
        let runner = makeRunner(rpcResult: startedResult())
        let retention = makeRetention(commandRunner: runner, agentResolver: UnresolvedMacCodingAgent())

        XCTAssertNil(UnresolvedMacCodingAgent().resolveMacCodingAgent())
        XCTAssertFalse(retention.retain(credential: "worker-1.secret", worker: worker))
        XCTAssertEqual(runner.rpcCallCount, 0)
    }
}
