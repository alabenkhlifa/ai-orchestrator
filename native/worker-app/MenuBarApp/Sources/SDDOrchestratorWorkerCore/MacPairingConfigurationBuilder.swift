import Foundation

/// Builds the exact six-field JSON object
/// `SddOrchestrator.Worker.Configuration` requires of a worker that has no
/// project (see `lib/sdd_orchestrator/worker/configuration.ex`'s
/// `@required_keys`, narrowed by specs/39 Task 1), from the pairing result
/// and the resolved coding agent.
///
/// Field names match `Configuration`'s own `to_map/1`/`from_map/1` exactly
/// (`control_plane_address`, `device_workspace_id`, `worker_credential`,
/// `agent_adapter`, `agent_executable`, `worker_id`) so the
/// `bin/worker rpc`-side `Jason.decode!` + struct literal
/// (`MacPairingRPCExpressionBuilder`) can read this object without any
/// renaming.
///
/// `project_id` and `workspace_root` are absent keys, never empty strings
/// and never explicit nulls. Task 1 made both optional and made an absent
/// project decode to `nil`; an empty string would instead be a project id
/// of `""`, which is a value this worker was never issued. Sending the
/// keys at all would also make this app claim to answer a question a
/// menu-bar pairing does not ask — this is the whole point of AC-01's "and
/// reports no project, without asking the person for one".
///
/// A separate builder rather than an optional-parameter widening of
/// `PostPairingConfigurationBuilder`: that one serves specs/36's
/// project-scoped deep-link path, whose contract (eight fields, all
/// required, an operator-picked repository folder) this slice explicitly
/// leaves untouched.
enum MacPairingConfigurationBuilder {
    static func buildJSONObject(
        controlPlaneAddress: String,
        deviceWorkspaceID: String,
        credential: String,
        agentAdapter: String,
        agentExecutable: String,
        workerID: String
    ) -> [String: String] {
        [
            "control_plane_address": controlPlaneAddress,
            "device_workspace_id": deviceWorkspaceID,
            "worker_credential": credential,
            "agent_adapter": agentAdapter,
            "agent_executable": agentExecutable,
            "worker_id": workerID
        ]
    }
}
