import Foundation

/// Polls `SddOrchestrator.Worker.ConnectionStatus.status/0` (Elixir,
/// `lib/sdd_orchestrator/worker/connection_status.ex`) over
/// `bin/worker rpc` — unlike `PairingStatusChecker`, this requires the
/// embedded release's `bin/worker start` child process to already be
/// running, since `rpc` targets that already-booted node.
public enum ConnectionStatusQuerier {
    static let expression = """
    try do
      %{status: status} = SddOrchestrator.Worker.ConnectionStatus.status()
      IO.puts(Atom.to_string(status))
    rescue
      _ -> IO.puts("unknown")
    end
    """

    public static func query(
        workerBinaryPath: String,
        runner: CommandRunning,
        timeout: TimeInterval = 5
    ) -> GatewayConnectionState {
        let result = runner.run(executable: workerBinaryPath, arguments: ["rpc", expression], timeout: timeout)
        return parse(result)
    }

    static func parse(_ result: CommandResult) -> GatewayConnectionState {
        guard !result.timedOut, result.exitCode == 0 else { return .unknown }

        // Each state the worker can report is named here on purpose. An
        // unrecognized string falls to `.unknown` rather than to anything
        // stronger, so a worker running a newer status set can never be read
        // as connected by an older app.
        switch result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "connected": return .connected
        case "connecting": return .connecting
        case "refused": return .refused
        case "disconnected": return .disconnected
        case "unknown": return .unknown
        default: return .unknown
        }
    }
}
