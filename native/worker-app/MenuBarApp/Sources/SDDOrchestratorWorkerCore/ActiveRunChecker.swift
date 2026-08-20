/// The Quit-confirmation decision (AC-04/AC-05):
///
///   * no run active -> stop the embedded worker and quit immediately.
///   * a run active -> warn ("A run is in progress. Quitting will stop it.
///     Quit anyway?") before stopping anything.
public enum ActiveRunChecker {
    /// Mirrors `SddOrchestrator.Worker.RunState`'s own accepted/blocked
    /// (still in flight) vs. canceled/failed/stopped/verification_completed
    /// (terminal) distinction — see `run_state.ex`'s `@lifecycle_states` and
    /// this task's brief. Duplicated here deliberately as data, not
    /// behavior: this app never writes or interprets run-state semantics
    /// beyond this one active/terminal split, and the source of truth for
    /// the lifecycle values themselves stays `run_state.ex`.
    public static let activeLifecycles: Set<String> = ["accepted", "blocked"]

    /// Whether the given current-entry lifecycle counts as an active run.
    /// `nil` (no current entry at all) is never active.
    public static func isActive(currentLifecycle: String?) -> Bool {
        guard let currentLifecycle else { return false }
        return activeLifecycles.contains(currentLifecycle)
    }

    /// Whether Quit should warn before stopping anything, given the raw
    /// result of querying the embedded release's run state.
    ///
    /// A failed query (`.queryFailed`) fails safe toward warning: this app
    /// cannot prove no run is active, so it must not silently stop a
    /// process that might be mid-run.
    public static func shouldWarnBeforeQuit(queryResult: RunStateQueryResult) -> Bool {
        switch queryResult {
        case .success(let currentLifecycle):
            return isActive(currentLifecycle: currentLifecycle)
        case .queryFailed:
            return true
        }
    }
}
