import Foundation

/// specs/36 Task 5's real `PostPairingSetupCoordinator`: resolves a
/// workspace folder (AC-19), resolves a coding-agent executable (AC-20),
/// and — once both are known — stores the full
/// `SddOrchestrator.Worker.Configuration` and starts
/// `SddOrchestrator.Worker.Supervisor` under the already-running embedded
/// release (AC-21).
///
/// `folderPicker`/`agentSelectionPrompt` are the two AppKit-backed seams
/// (`NSOpenPanel`/`NSAlert`, in the `SDDOrchestratorWorkerApp` target) this
/// Core-side orchestration depends on only through their protocols, so the
/// whole decision — cancel-aborts-cleanly, detection-count branching,
/// JSON-building, idempotent-start handling — is unit-testable against
/// fakes, matching this package's "thin AppKit glue over a testable Core"
/// split (see `ActiveRunChecker`, `PairingFlowController`).
public final class PostPairingSetupCoordinatorImpl: PostPairingSetupCoordinator {
    private let dashboardURL: URL
    private let workerBinaryPath: String
    private let commandRunner: CommandRunning
    private let executableChecker: ExecutableChecking
    private let folderPicker: WorkspaceFolderPicking
    private let agentSelectionPrompt: AgentSelectionPrompting
    private let fileManager: FileManager
    private let rpcTimeout: TimeInterval

    public init(
        dashboardURL: URL,
        workerBinaryPath: String,
        commandRunner: CommandRunning,
        executableChecker: ExecutableChecking = FileManagerExecutableChecker(),
        folderPicker: WorkspaceFolderPicking,
        agentSelectionPrompt: AgentSelectionPrompting,
        fileManager: FileManager = .default,
        rpcTimeout: TimeInterval = 10
    ) {
        self.dashboardURL = dashboardURL
        self.workerBinaryPath = workerBinaryPath
        self.commandRunner = commandRunner
        self.executableChecker = executableChecker
        self.folderPicker = folderPicker
        self.agentSelectionPrompt = agentSelectionPrompt
        self.fileManager = fileManager
        self.rpcTimeout = rpcTimeout
    }

    /// Called on `PairingFlowController`'s background scheduler once
    /// `POST /worker_pairings` succeeds — never the main thread. Every
    /// AppKit-facing seam this method calls (`folderPicker`,
    /// `agentSelectionPrompt`) is responsible for its own hop to the main
    /// thread; this orchestration stays thread-agnostic.
    public func beginPostPairingSetup(credential: String, worker: WorkerIdentity, projectID: String) {
        guard let workspaceRoot = folderPicker.pickWorkspaceFolder() else {
            log("workspace folder selection canceled; post-pairing setup left stalled (menu still shows \"Paired, setting up…\")")
            return
        }

        let detected = CodingAgentDetector.detect(executableChecker: executableChecker, commandRunner: commandRunner)

        let resolvedAgent: DetectedAgent?
        if detected.count == 1 {
            resolvedAgent = detected[0]
        } else {
            resolvedAgent = agentSelectionPrompt.resolveCodingAgent(detected: detected)
        }

        guard let agent = resolvedAgent else {
            log("coding-agent selection canceled; post-pairing setup left stalled (menu still shows \"Paired, setting up…\")")
            return
        }

        let jsonObject = PostPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: dashboardURL.absoluteString,
            deviceWorkspaceID: worker.deviceWorkspaceID,
            credential: credential,
            agentAdapter: agent.adapter,
            agentExecutable: agent.executablePath,
            workspaceRoot: workspaceRoot,
            projectID: projectID,
            workerID: worker.id
        )

        storeAndStart(jsonObject: jsonObject)
    }

    private func storeAndStart(jsonObject: [String: String]) {
        let written: (directory: URL, file: URL)
        do {
            written = try writeTemporaryConfigFile(jsonObject)
        } catch {
            log("failed to write the temporary post-pairing configuration file: \(error)")
            return
        }

        defer { try? fileManager.removeItem(at: written.directory) }

        let expression = PostPairingRPCExpressionBuilder.build(configFilePath: written.file.path)
        let result = commandRunner.run(executable: workerBinaryPath, arguments: ["rpc", expression], timeout: rpcTimeout)

        switch PostPairingRPCExpressionBuilder.parse(result) {
        case .started:
            log("worker configuration stored; Worker.Supervisor started")
        case .alreadyStarted:
            // [Idempotency] DynamicSupervisor.start_child on an
            // already-started Worker.Supervisor means setup already
            // completed — success, not a failure to surface.
            log("Worker.Supervisor already running; post-pairing setup already completed")
        case .failure(let reason):
            log("post-pairing setup failed: \(reason)")
        case .commandFailed:
            log("post-pairing setup failed: bin/worker rpc did not complete")
        }
    }

    /// Writes the configuration JSON to a private temporary file: a
    /// per-run temp directory (owner-only, `0700`) containing one file
    /// (owner-only, `0600`), cleaned up by `storeAndStart`'s `defer`
    /// regardless of outcome. Never logged.
    private func writeTemporaryConfigFile(_ jsonObject: [String: String]) throws -> (directory: URL, file: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sdd-orchestrator-worker-setup-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let file = directory.appendingPathComponent("config.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        try data.write(to: file, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        return (directory, file)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("SDD Orchestrator Worker: \(message)\n".utf8))
    }
}
