import Foundation

/// specs/36 Task 5's real `PostPairingSetupCoordinator`: resolves a
/// workspace folder (AC-19), resolves a coding-agent executable (AC-20),
/// and — once both are known — stores the full
/// `SddOrchestrator.Worker.Configuration` and starts
/// `SddOrchestrator.Worker.Supervisor` (AC-21).
///
/// [specs/43 Task 4, AC-01] It stores that configuration by writing the
/// file itself and starts the worker by restarting the embedded release,
/// the same way `MacPairingRetention` does and for the same reason: the
/// `bin/worker rpc` call both paths used needs Erlang distribution, which a
/// managed Mac's firewall blocks. The eight-field JSON it writes is
/// unchanged, because the release reading it is unchanged.
///
/// `folderPicker`/`agentSelectionPrompt` are the two AppKit-backed seams
/// (`NSOpenPanel`/`NSAlert`, in the `SDDOrchestratorWorkerApp` target) this
/// Core-side orchestration depends on only through their protocols, so the
/// whole decision — cancel-aborts-cleanly, detection-count branching,
/// JSON-building, store-then-restart — is unit-testable against fakes,
/// matching this package's "thin AppKit glue over a testable Core" split
/// (see `ActiveRunChecker`, `PairingFlowController`).
public final class PostPairingSetupCoordinatorImpl: PostPairingSetupCoordinator {
    private let dashboardURL: URL
    private let commandRunner: CommandRunning
    private let runtimeRestarter: WorkerRuntimeRestarting
    private let executableChecker: ExecutableChecking
    private let folderPicker: WorkspaceFolderPicking
    private let agentSelectionPrompt: AgentSelectionPrompting
    private let workerHome: String
    private let fileManager: FileManager

    public init(
        dashboardURL: URL,
        commandRunner: CommandRunning,
        runtimeRestarter: WorkerRuntimeRestarting,
        executableChecker: ExecutableChecking = FileManagerExecutableChecker(),
        folderPicker: WorkspaceFolderPicking,
        agentSelectionPrompt: AgentSelectionPrompting,
        workerHome: String = WorkerPaths.workerHome(),
        fileManager: FileManager = .default
    ) {
        self.dashboardURL = dashboardURL
        self.commandRunner = commandRunner
        self.runtimeRestarter = runtimeRestarter
        self.executableChecker = executableChecker
        self.folderPicker = folderPicker
        self.agentSelectionPrompt = agentSelectionPrompt
        self.workerHome = workerHome
        self.fileManager = fileManager
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
        do {
            try WorkerConfigurationStore.write(
                jsonObject: jsonObject,
                workerHome: workerHome,
                fileManager: fileManager
            )
        } catch {
            log("failed to write the worker configuration: \(error)")
            return
        }

        // Stored before the restart on purpose: a boot that fails leaves a
        // configuration the next launch starts against, and the menu keeps
        // saying the setup is unfinished until a worker is actually up.
        guard runtimeRestarter.restartWorkerRuntime() else {
            log("worker configuration stored, but the embedded release did not restart")
            return
        }

        log("worker configuration stored; the embedded release was restarted")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("SDD Orchestrator Worker: \(message)\n".utf8))
    }
}
