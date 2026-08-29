import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/36 Task 5's AC-19/AC-20/AC-21 proof, kept as it was, plus
/// specs/43 Task 4's change to how the last step happens: the coordinator
/// writes the configuration itself and restarts the embedded release
/// instead of running `bin/worker rpc`, which needs Erlang distribution.
/// The eight-field JSON it stores is unchanged.
///
/// [specs/43 Task 4] Records every command the coordinator runs, on top of
/// the `which`/`rpc` split `FakeWorkerRPCCommandRunner` already makes.
/// Wrapping rather than extending that fake keeps it exactly as
/// `MacCodingAgentSetupTests` relies on it, and gives these tests the one
/// thing they need beyond it: the full argument list of everything that
/// ran, so "no rpc call, and no secret in any argument" can be asserted
/// rather than argued.
private final class RecordingCommandRunner: CommandRunning {
    private let wrapped: FakeWorkerRPCCommandRunner

    private(set) var calls: [(executable: String, arguments: [String])] = []

    init(wrapping wrapped: FakeWorkerRPCCommandRunner) {
        self.wrapped = wrapped
    }

    var rpcCallCount: Int { wrapped.rpcCallCount }
    var whichCallCount: Int { wrapped.whichCallCount }
    var lastRPCArguments: [String]? { wrapped.lastRPCArguments }

    /// Every executable and every argument of every command that ran, as
    /// one string to search.
    var everythingRun: String {
        calls.map { ([$0.executable] + $0.arguments).joined(separator: " ") }.joined(separator: " ")
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls.append((executable, arguments))
        return wrapped.run(executable: executable, arguments: arguments, timeout: timeout)
    }
}

final class PostPairingSetupCoordinatorImplTests: XCTestCase {
    private let dashboardURL = URL(string: "http://localhost:4000")!

    private var workerHome = ""
    private var temporaryRoot = ""

    private let worker = WorkerIdentity(
        id: "worker-1",
        deviceWorkspaceID: "ws-1",
        osFamily: "macos",
        osMajor: "15",
        protocolVersion: "1",
        appVersion: "1.0.0",
        state: "active"
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("post-pairing-setup-tests-\(UUID().uuidString)")
        workerHome = (temporaryRoot as NSString).appendingPathComponent(".sdd_orchestrator/worker")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: temporaryRoot)
        try super.tearDownWithError()
    }

    private var configurationPath: String {
        WorkerPaths.workerConfigurationPath(homeOverride: workerHome)
    }

    /// The detector still shells out to `/usr/bin/which`, so the runner
    /// stays — which is also what lets these tests assert that no command
    /// this path runs is ever an `rpc` call.
    private func makeRunner() -> RecordingCommandRunner {
        RecordingCommandRunner(
            wrapping: FakeWorkerRPCCommandRunner(
                workerBinaryPath: "/path/to/bin/worker",
                rpcResult: CommandResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
            )
        )
    }

    private func makeCoordinator(
        commandRunner: CommandRunning,
        restarter: WorkerRuntimeRestarting,
        executableChecker: ExecutableChecking = FakeExecutableChecker(executablePaths: ["/usr/local/bin/claude"]),
        folderPicker: WorkspaceFolderPicking,
        agentSelectionPrompt: AgentSelectionPrompting
    ) -> PostPairingSetupCoordinatorImpl {
        PostPairingSetupCoordinatorImpl(
            dashboardURL: dashboardURL,
            commandRunner: commandRunner,
            runtimeRestarter: restarter,
            executableChecker: executableChecker,
            folderPicker: folderPicker,
            agentSelectionPrompt: agentSelectionPrompt,
            workerHome: workerHome
        )
    }

    private func storedConfiguration(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: configurationPath),
            "expected a worker configuration at the storage root",
            file: file,
            line: line
        )

        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the release decodes this file with Jason.decode!/1, so it must be a JSON object",
            file: file,
            line: line
        )
    }

    // MARK: - AC-19: folder-picker cancel aborts cleanly

    func test_beginPostPairingSetup_folderPickerCanceled_abortsWithoutDetectingOrPromptingOrStoring() {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: nil)
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(runner.whichCallCount, 0, "canceling the folder picker must abort before agent detection ever runs")
        XCTAssertEqual(prompt.callCount, 0)
        XCTAssertEqual(restarter.restartCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workerHome))
    }

    // MARK: - AC-20: agent-selection cancel (auto-detection found none) aborts cleanly

    func test_beginPostPairingSetup_agentSelectionCanceledAfterNoneDetected_abortsWithoutStoring() {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            executableChecker: FakeExecutableChecker(executablePaths: []),
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(prompt.callCount, 1)
        XCTAssertEqual(prompt.lastDetected, [])
        XCTAssertEqual(restarter.restartCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationPath))
    }

    // MARK: - Exactly one auto-detected: the fallback prompt is never invoked

    func test_beginPostPairingSetup_exactlyOneAgentDetected_neverInvokesFallbackPrompt() {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            executableChecker: FakeExecutableChecker(executablePaths: ["/usr/local/bin/claude"]),
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(prompt.callCount, 0)
        XCTAssertEqual(restarter.restartCount, 1)
    }

    // MARK: - Both found: the fallback prompt receives both candidates

    func test_beginPostPairingSetup_bothAgentsDetected_invokesFallbackPromptWithBothCandidates() {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let bothDetected = [
            DetectedAgent(adapter: "claude_code", executablePath: "/usr/local/bin/claude"),
            DetectedAgent(adapter: "codex", executablePath: "/usr/local/bin/codex")
        ]
        let prompt = FakeAgentSelectionPrompt(result: bothDetected[0])
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            executableChecker: FakeExecutableChecker(executablePaths: ["/usr/local/bin/claude", "/usr/local/bin/codex"]),
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(prompt.callCount, 1)
        XCTAssertEqual(prompt.lastDetected, bothDetected)
        XCTAssertEqual(runner.whichCallCount, 0, "both being found via common paths must skip which entirely")
        XCTAssertEqual(restarter.restartCount, 1)
    }

    // MARK: - AC-21 / specs/43 AC-01: the same eight-field configuration, stored by this app

    func test_beginPostPairingSetup_happyPath_storesTheSameEightFieldConfigurationItStoredBefore() throws {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(
            credential: "worker-1.super-secret-credential",
            worker: worker,
            projectID: "proj-1"
        )

        let configuration = try storedConfiguration()

        XCTAssertEqual(configuration["control_plane_address"] as? String, "http://localhost:4000")
        XCTAssertEqual(configuration["device_workspace_id"] as? String, "ws-1")
        XCTAssertEqual(configuration["worker_credential"] as? String, "worker-1.super-secret-credential")
        XCTAssertEqual(configuration["agent_adapter"] as? String, "claude_code")
        XCTAssertEqual(configuration["agent_executable"] as? String, "/usr/local/bin/claude")
        XCTAssertEqual(configuration["workspace_root"] as? String, "/Users/dev/repo")
        XCTAssertEqual(configuration["project_id"] as? String, "proj-1")
        XCTAssertEqual(configuration["worker_id"] as? String, "worker-1")
        XCTAssertEqual(configuration.count, 8, "the deep-link path pairs into a project, so it stores all eight fields")
    }

    func test_beginPostPairingSetup_happyPath_writesAnOwnerOnlyFileInAnOwnerOnlyDirectory() throws {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: configurationPath)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: workerHome)

        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workerHome), ["worker.json"])
    }

    // MARK: - Nothing this path runs is an rpc call, and no secret reaches an argument list

    func test_beginPostPairingSetup_happyPath_restartsTheReleaseAndRunsNoRpcCall() {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        let credential = "worker-1.super-secret-credential"
        coordinator.beginPostPairingSetup(credential: credential, worker: worker, projectID: "proj-1")

        XCTAssertEqual(restarter.restartCount, 1, "the worker starts by restarting the release the app owns")
        XCTAssertEqual(
            runner.rpcCallCount,
            0,
            "nothing on this path may reach the release's node: rpc is the call a managed Mac's firewall blocks"
        )
        XCTAssertNil(runner.lastRPCArguments)

        let everythingRun = runner.everythingRun
        XCTAssertFalse(everythingRun.contains("rpc"))
        XCTAssertFalse(everythingRun.contains(credential), "the credential belongs in the configuration file and nowhere else")
        XCTAssertFalse(everythingRun.contains("/Users/dev/repo"))
        XCTAssertFalse(everythingRun.contains("proj-1"))
    }

    func test_beginPostPairingSetup_releaseDoesNotComeBackUp_leavesTheStoredConfigurationInPlace() throws {
        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter(result: false)
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        // The next launch starts against what is already on disk, which is
        // why storing comes before restarting.
        XCTAssertEqual(restarter.restartCount, 1)
        XCTAssertEqual(try storedConfiguration()["worker_credential"] as? String, "worker-1.secret")
    }

    // MARK: - A failed write stores nothing and starts nothing

    func test_beginPostPairingSetup_unwritableStorageRoot_storesNothingAndDoesNotRestartTheRelease() throws {
        let blocked = (temporaryRoot as NSString).appendingPathComponent("blocked")
        try FileManager.default.createDirectory(atPath: temporaryRoot, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked, contents: Data("not a directory".utf8)))

        workerHome = (blocked as NSString).appendingPathComponent("worker")

        let runner = makeRunner()
        let restarter = FakeWorkerRuntimeRestarter()
        let folderPicker = FakeWorkspaceFolderPicker(result: "/Users/dev/repo")
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let coordinator = makeCoordinator(
            commandRunner: runner,
            restarter: restarter,
            folderPicker: folderPicker,
            agentSelectionPrompt: prompt
        )

        coordinator.beginPostPairingSetup(credential: "worker-1.secret", worker: worker, projectID: "proj-1")

        XCTAssertEqual(restarter.restartCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationPath))
    }
}
