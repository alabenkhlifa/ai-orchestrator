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
/// `SddOrchestrator.Worker.Configuration`'s `worker.json`.
///
/// That single store is the point. This app keeps no credential file of its
/// own and no keychain item: a second copy of the secret would widen the
/// approved data boundary and the retention and revocation path the slice's
/// privacy release gate is written against, for no behavior the worker
/// runtime does not already get from `worker.json`.
///
/// [specs/43 Task 4, AC-01] It writes that file itself and then restarts
/// the embedded release, instead of asking the release's already-booted
/// node to do both through `bin/worker rpc`. `rpc` is Erlang distribution,
/// and a managed Mac's firewall blocks it, so the old path could not finish
/// pairing there at all. Writing a file needs no second process, and the
/// release loads its configuration at boot, so the restart is the start.
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
    private let workerHome: String
    private let runtimeRestarter: WorkerRuntimeRestarting
    private let agentResolver: MacCodingAgentResolving
    private let fileManager: FileManager

    public init(
        controlPlaneURL: URL,
        runtimeRestarter: WorkerRuntimeRestarting,
        agentResolver: MacCodingAgentResolving,
        workerHome: String = WorkerPaths.workerHome(),
        fileManager: FileManager = .default
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.runtimeRestarter = runtimeRestarter
        self.agentResolver = agentResolver
        self.workerHome = workerHome
        self.fileManager = fileManager
    }

    /// Stores the issued credential and worker identity as a projectless
    /// worker configuration, then starts `Worker.Supervisor` by restarting
    /// the release that loads it. Returns whether the configuration was
    /// stored *and* the runtime was started, so the caller never has to
    /// infer it from a log line.
    ///
    /// Writes a file and waits for a process restart, so the caller runs it
    /// off the main thread (see `AppDelegate`'s completion handler).
    /// Nothing here touches AppKit or the menu.
    ///
    /// Stores nothing at all unless every required field is in hand: an
    /// unresolved coding agent stops the whole thing before the file is
    /// written and before the release is touched. A half-written
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
        do {
            try WorkerConfigurationStore.write(
                jsonObject: jsonObject,
                workerHome: workerHome,
                fileManager: fileManager
            )
        } catch {
            log("failed to write this Mac's worker configuration: \(error)")
            return false
        }

        // The configuration is stored before the restart on purpose: if the
        // new boot fails, the next launch starts against a configuration
        // that is already on disk, and until then the menu keeps saying the
        // setup is unfinished rather than claiming a connected worker.
        guard runtimeRestarter.restartWorkerRuntime() else {
            log("worker configuration stored for this Mac, but the embedded release did not restart")
            return false
        }

        log("worker configuration stored for this Mac; the embedded release was restarted")
        return true
    }

    /// Never carries the credential, the worker id, or the configuration
    /// contents — only what happened.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data("SDD Orchestrator Worker: \(message)\n".utf8))
    }
}
