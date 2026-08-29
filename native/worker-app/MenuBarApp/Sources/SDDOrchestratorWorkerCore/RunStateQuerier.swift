import Foundation

/// Asks the embedded release for its current run-state entry's lifecycle —
/// `SddOrchestrator.Worker.RunState.load/1`
/// (`lib/sdd_orchestrator/worker/run_state.ex`), read but not modified by
/// this task.
///
/// Uses `bin/worker eval`, not `bin/worker rpc`, exactly as
/// `PairingStatusChecker` does: the run state is a file, not memory.
/// `RunState.load/1` reads `Configuration.home/1`'s directory, which falls
/// back to `~/.sdd_orchestrator/worker` when the application env is unset,
/// so a fresh, non-booted "clean" VM reads the same file the running
/// release would. `rpc` needs Erlang distribution (epmd plus a listening
/// socket), which a managed Mac's firewall blocks, and this check must
/// still answer there (`specs/43-distribution-free-worker-control`
/// Task 1, AC-04).
///
/// This is the `specs/36-local-worker-native-distribution` AC-05 "is a run
/// active" check the Quit flow makes before deciding whether to warn (see
/// `ActiveRunChecker`).
public enum RunStateQuerier {
    static let expression = """
    try do
      case SddOrchestrator.Worker.RunState.load(nil) do
        {:ok, %{current: nil}} -> IO.puts("none")
        {:ok, %{current: %{lifecycle: lifecycle}}} -> IO.puts(lifecycle)
        {:error, _reason} -> IO.puts("error")
      end
    rescue
      _ -> IO.puts("error")
    end
    """

    public static func query(
        workerBinaryPath: String,
        runner: CommandRunning,
        timeout: TimeInterval = 5
    ) -> RunStateQueryResult {
        let result = runner.run(executable: workerBinaryPath, arguments: ["eval", expression], timeout: timeout)
        return parse(result)
    }

    static func parse(_ result: CommandResult) -> RunStateQueryResult {
        guard !result.timedOut, result.exitCode == 0 else { return .queryFailed }

        let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmed {
        case "none": return .success(currentLifecycle: nil)
        case "error", "": return .queryFailed
        default: return .success(currentLifecycle: trimmed)
        }
    }
}
