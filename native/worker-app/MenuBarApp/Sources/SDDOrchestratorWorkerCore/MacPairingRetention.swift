import Foundation

/// [specs/39 Task 2, AC-01] Keeps what a menu-bar redemption issues.
///
/// `specs/38-worker-initiated-pairing` deliberately threw the credential
/// away: `Worker.Configuration` required a `project_id`, a worker-initiated
/// pairing has none, and there was nothing valid to store. specs/39 Task 1
/// removed that reason — `control_plane_address`, `device_workspace_id`,
/// `worker_credential`, `agent_adapter`, `agent_executable` and `worker_id`
/// are all a stored configuration now needs. So the credential and the
/// worker identity `POST /worker_pairings` answered are written to the one
/// durable store this project has for them:
/// `SddOrchestrator.Worker.Configuration`'s `worker.json`, through the
/// embedded release's `bin/worker rpc`.
///
/// That single store is the point. This app keeps no credential file of its
/// own and no keychain item: a second copy of the secret would widen the
/// approved data boundary and the retention and revocation path the slice's
/// privacy release gate is written against, for no behavior the worker
/// runtime does not already get from `worker.json`.
///
/// **It never asks the person for a project or a repository folder.** It
/// takes no project id and holds no `WorkspaceFolderPicking` — the type's
/// own shape is the guarantee, not a check made at run time. A worker
/// paired from the menu bar is authorized for this Mac; which repository it
/// later works in is a question the dashboard asks, not this app.
/// (`PostPairingSetupCoordinatorImpl` does hold a folder picker, because
/// specs/36's deep-link path pairs *into a project* and genuinely needs
/// one. The two paths stay separate for exactly this reason.)
///
/// The one thing it cannot resolve itself is which coding agent this Mac
/// runs, which is specs/39 Task 3's. That arrives through
/// `MacCodingAgentResolving`, implemented by `MacCodingAgentSetup`. An
/// unresolvable agent is answered as `nil` and stops this path before it
/// writes anything, rather than storing a worker that names an agent this
/// Mac cannot run.
public final class MacPairingRetention {
    private let controlPlaneURL: URL
    private let workerBinaryPath: String
    private let commandRunner: CommandRunning
    private let agentResolver: MacCodingAgentResolving
    private let fileManager: FileManager
    private let rpcTimeout: TimeInterval

    public init(
        controlPlaneURL: URL,
        workerBinaryPath: String,
        commandRunner: CommandRunning,
        agentResolver: MacCodingAgentResolving,
        fileManager: FileManager = .default,
        rpcTimeout: TimeInterval = 10
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.workerBinaryPath = workerBinaryPath
        self.commandRunner = commandRunner
        self.agentResolver = agentResolver
        self.fileManager = fileManager
        self.rpcTimeout = rpcTimeout
    }

    /// Stores the issued credential and worker identity as a projectless
    /// worker configuration, then starts `Worker.Supervisor`. Returns
    /// whether the configuration was actually stored, so the caller never
    /// has to infer it from a log line.
    ///
    /// Shells out to `bin/worker rpc` and blocks until it answers, so the
    /// caller runs it off the main thread (see `AppDelegate`'s completion
    /// handler). Nothing here touches AppKit or the menu.
    ///
    /// Stores nothing at all unless every required field is in hand: an
    /// unresolved coding agent stops the whole thing before the temporary
    /// file is written and before any command runs. A half-written
    /// `worker.json` naming an agent this Mac cannot run would be worse
    /// than no configuration, because the worker runtime would start
    /// against it.
    @discardableResult
    public func retain(credential: String, worker: WorkerIdentity) -> Bool {
        guard let agent = agentResolver.resolveMacCodingAgent() else {
            log("no coding agent resolved for this Mac; nothing stored (menu still shows \"Paired, setting up…\")")
            return false
        }

        let jsonObject = MacPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: controlPlaneURL.absoluteString,
            deviceWorkspaceID: worker.deviceWorkspaceID,
            credential: credential,
            agentAdapter: agent.adapter,
            agentExecutable: agent.executablePath,
            workerID: worker.id
        )

        return storeAndStart(jsonObject: jsonObject)
    }

    private func storeAndStart(jsonObject: [String: String]) -> Bool {
        let written: (directory: URL, file: URL)
        do {
            written = try writeTemporaryConfigFile(jsonObject)
        } catch {
            log("failed to write the temporary worker configuration file: \(error)")
            return false
        }

        defer { try? fileManager.removeItem(at: written.directory) }

        let expression = MacPairingRPCExpressionBuilder.build(configFilePath: written.file.path)
        let result = commandRunner.run(executable: workerBinaryPath, arguments: ["rpc", expression], timeout: rpcTimeout)

        switch MacPairingRPCExpressionBuilder.parse(result) {
        case .started:
            log("worker configuration stored for this Mac; Worker.Supervisor started")
            return true
        case .alreadyStarted:
            // [Idempotency] The pairing loop can complete more than once
            // across a launch, and `store/2` overwrites. An
            // already-started Worker.Supervisor means the configuration
            // was stored and the runtime is up — success, not a failure to
            // surface.
            log("Worker.Supervisor already running; the stored configuration was refreshed")
            return true
        case .failure(let reason):
            log("storing this Mac's worker configuration failed: \(reason)")
            return false
        case .commandFailed:
            log("storing this Mac's worker configuration failed: bin/worker rpc did not complete")
            return false
        }
    }

    /// Writes the configuration JSON to a private temporary file: a
    /// per-run temp directory (owner-only, `0700`) containing one file
    /// (owner-only, `0600`), cleaned up by `storeAndStart`'s `defer`
    /// regardless of outcome. The credential passes through here and
    /// nowhere else on disk outside `worker.json` itself.
    private func writeTemporaryConfigFile(_ jsonObject: [String: String]) throws -> (directory: URL, file: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sdd-orchestrator-mac-pairing-\(UUID().uuidString)", isDirectory: true)

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

    /// Never carries the credential, the worker id, or the configuration
    /// contents — only what happened.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data("SDD Orchestrator Worker: \(message)\n".utf8))
    }
}
