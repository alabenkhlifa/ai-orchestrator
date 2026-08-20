import Foundation

/// Queries this worker's own announced protocol version —
/// `SddOrchestrator.Worker.GatewayConnection.protocol_version/0` — via
/// `bin/worker eval`, so the pairing-completion request's `protocol_version`
/// attribute (specs/36 Task 4) is never a hardcoded Swift literal that could
/// drift from the embedded release's own value.
///
/// Uses `bin/worker eval`, not `bin/worker rpc`, for the same reason as
/// `PairingStatusChecker`: `protocol_version/0` returns a plain module
/// attribute with no `Application` dependency, so a fresh, non-booted "clean"
/// VM can call it directly without requiring the embedded release's
/// `bin/worker start` child process to already be running.
public enum ProtocolVersionQuerier {
    static let expression = """
    try do
      IO.puts(Integer.to_string(SddOrchestrator.Worker.GatewayConnection.protocol_version()))
    rescue
      _ -> IO.puts("unknown")
    end
    """

    /// `nil` on any failure (process launch error, timeout, unparseable or
    /// non-numeric output). Callers treat a missing protocol version as an
    /// omitted, optional pairing-request attribute rather than blocking
    /// pairing on it — see `PairingCompletionRequestBody`.
    public static func query(
        workerBinaryPath: String,
        runner: CommandRunning,
        timeout: TimeInterval = 5
    ) -> String? {
        let result = runner.run(executable: workerBinaryPath, arguments: ["eval", expression], timeout: timeout)
        return parse(result)
    }

    static func parse(_ result: CommandResult) -> String? {
        guard !result.timedOut, result.exitCode == 0 else { return nil }

        let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Int(trimmed) != nil else { return nil }
        return trimmed
    }
}
