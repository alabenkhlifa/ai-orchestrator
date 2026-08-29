import Foundation

/// [specs/43 Task 3, AC-02] Reads the worker's last-known gateway
/// connection state from the file the embedded release publishes:
/// `connection_status.json`, beside `worker.json` under the release's own
/// storage root. `SddOrchestrator.Worker.ConnectionStatus`
/// (`lib/sdd_orchestrator/worker/connection_status.ex`) owns that file, its
/// location, and its shape, and rewrites it on every transition.
///
/// A file, because neither command can answer this query on the machine
/// this slice exists for. `rpc` reaches the running node and would report
/// the truth, but it needs Erlang distribution — epmd plus a listening
/// socket — which a managed Mac's firewall refuses, so the menu could never
/// show the real state there. And `eval` is not the substitute it was for
/// `RunStateQuerier`: the run state is a file, but the connection state
/// lives in the running VM's `:persistent_term`, and a fresh VM has none of
/// its memory. `eval` would answer `unknown` for a worker that is attached
/// right now. So the release writes each transition down, and this reads
/// it. Nothing here runs a command.
///
/// The file is a report, never the authority, and it is meaningless once
/// the release stops. A stale claim of health is worse than admitting
/// ignorance, so every way of not knowing — no file, no permission to read
/// it, bytes that are not JSON, no `status` key, a status this app does not
/// recognize — answers `.unknown`, and none of them can answer
/// `.connected`.
///
/// The file's `reason` and `updated_at` are read by nothing here.
/// `GatewayConnectionState.refused` carries no reason on purpose
/// (specs/39 Task 7), and this task changes no state's meaning.
public enum ConnectionStatusQuerier {
    /// The name the release publishes under. It mirrors that module's own
    /// `@file_name`, which is the one place the file is named on the other
    /// side.
    static let fileName = "connection_status.json"

    /// `<workerHome>/connection_status.json`. The storage root comes from
    /// `WorkerPaths.workerHome(override:)`, which already mirrors
    /// `SddOrchestrator.Worker.Configuration.home/1`, so this app never
    /// resolves the release's root a second way.
    static func statusFilePath(workerHomeOverride: String? = nil) -> String {
        (WorkerPaths.workerHome(override: workerHomeOverride) as NSString)
            .appendingPathComponent(fileName)
    }

    /// The state the release last recorded, or `.unknown` when the file
    /// cannot be read or understood. The override names the storage root,
    /// the same way every other path in this app takes one; the app itself
    /// passes nothing.
    public static func query(workerHomeOverride: String? = nil) -> GatewayConnectionState {
        let path = statusFilePath(workerHomeOverride: workerHomeOverride)

        // Missing, or readable only by another account. Either way this app
        // has observed nothing. The release writes the file by renaming a
        // complete temporary neighbour over it, so a read that does return
        // bytes never returns half of a write.
        guard let data = FileManager.default.contents(atPath: path) else { return .unknown }

        return parse(data)
    }

    static func parse(_ data: Data) -> GatewayConnectionState {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? String
        else { return .unknown }

        // Each state the worker can report is named here on purpose. An
        // unrecognized string falls to `.unknown` rather than to anything
        // stronger, so a worker running a newer status set can never be read
        // as connected by an older app.
        switch status {
        case "connected": return .connected
        case "connecting": return .connecting
        case "refused": return .refused
        case "disconnected": return .disconnected
        case "unknown": return .unknown
        default: return .unknown
        }
    }
}
