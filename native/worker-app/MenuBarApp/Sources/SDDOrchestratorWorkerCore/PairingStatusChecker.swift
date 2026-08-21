import Foundation

/// Determines whether a worker configuration/credential is stored, by
/// asking the embedded release's own
/// `SddOrchestrator.Worker.Configuration.load/1` — never by re-implementing
/// its file-path or parsing logic here (that stays owned by
/// `lib/sdd_orchestrator/worker/configuration.ex`, untouched by this task).
///
/// Uses `bin/worker eval`, not `bin/worker rpc`: `Configuration.load/1` is
/// plain struct and file I/O with no `Application` dependency (see its own
/// moduledoc), so a fresh, non-booted "clean" VM can call it directly —
/// this check does not require the embedded release's `bin/worker start`
/// child process to already be running or reachable.
public enum PairingStatusChecker {
    static let expression = """
    try do
      case SddOrchestrator.Worker.Configuration.load(nil) do
        {:ok, _config} -> IO.puts("paired")
        {:error, _reason} -> IO.puts("not_paired")
      end
    rescue
      _ -> IO.puts("unknown")
    end
    """

    public static func check(
        workerBinaryPath: String,
        runner: CommandRunning,
        timeout: TimeInterval = 5
    ) -> PairingStatus {
        let result = runner.run(executable: workerBinaryPath, arguments: ["eval", expression], timeout: timeout)
        return parse(result)
    }

    static func parse(_ result: CommandResult) -> PairingStatus {
        guard !result.timedOut, result.exitCode == 0 else { return .unknown }

        switch result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "paired": return .paired
        case "not_paired": return .notPaired
        default: return .unknown
        }
    }
}
