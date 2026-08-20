import Foundation

/// Asks the already-running embedded release, over `bin/worker rpc`, for
/// its current run-state entry's lifecycle —
/// `SddOrchestrator.Worker.RunState.load/1`
/// (`lib/sdd_orchestrator/worker/run_state.ex`), read but not modified by
/// this task.
///
/// This is the AC-05 "is a run active" check the Quit flow makes before
/// deciding whether to warn (see `ActiveRunChecker`).
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
        let result = runner.run(executable: workerBinaryPath, arguments: ["rpc", expression], timeout: timeout)
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
