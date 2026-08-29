import Foundation

/// Builds the exact eight-field JSON object
/// `SddOrchestrator.Worker.Configuration` requires (see
/// `lib/sdd_orchestrator/worker/configuration.ex`'s `@enforce_keys`), from
/// the pairing result, the resolved coding agent, and the operator-picked
/// workspace root.
///
/// Field names match `Configuration`'s own `to_map/1`/`from_map/1` exactly
/// (`control_plane_address`, `device_workspace_id`, `worker_credential`,
/// `agent_adapter`, `agent_executable`, `workspace_root`, `project_id`,
/// `worker_id`) so the release loads what `WorkerConfigurationStore` writes
/// without any renaming. [specs/43 Task 4] The eight fields are unchanged:
/// only who writes them moved from the release to this app.
enum PostPairingConfigurationBuilder {
    static func buildJSONObject(
        controlPlaneAddress: String,
        deviceWorkspaceID: String,
        credential: String,
        agentAdapter: String,
        agentExecutable: String,
        workspaceRoot: String,
        projectID: String,
        workerID: String
    ) -> [String: String] {
        [
            "control_plane_address": controlPlaneAddress,
            "device_workspace_id": deviceWorkspaceID,
            "worker_credential": credential,
            "agent_adapter": agentAdapter,
            "agent_executable": agentExecutable,
            "workspace_root": workspaceRoot,
            "project_id": projectID,
            "worker_id": workerID
        ]
    }
}
