/// The outcome of asking the embedded release for its current run-state
/// entry's lifecycle (see `RunStateQuerier`).
public enum RunStateQueryResult: Equatable, Sendable {
    /// `currentLifecycle` is `nil` when there is no `current` entry at all
    /// (a worker that has never accepted a command) — never active.
    /// Otherwise it is the raw `lifecycle` string
    /// `SddOrchestrator.Worker.RunState` stores (e.g. `"accepted"`,
    /// `"blocked"`, `"stopped"`, ...).
    case success(currentLifecycle: String?)
    /// The query itself failed (process launch error, timeout, unparseable
    /// output) — deliberately not folded into `.success(nil)`. See
    /// `ActiveRunChecker.shouldWarnBeforeQuit(queryResult:)`, which treats
    /// this as "warn": an unprovable answer must not be treated the same
    /// as a provably empty one.
    case queryFailed
}
