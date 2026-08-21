import Foundation

/// specs/36 Task 11's confirm -> active-run gate -> Gatekeeper verify ->
/// install-handoff decision (AC-13/AC-14). Kept in
/// `SDDOrchestratorWorkerCore`, not `AppDelegate`, matching this package's
/// "thin AppKit glue over a testable Core" split (see
/// `PostPairingSetupCoordinatorImpl`, `PairingFlowController`).
///
/// Threading contract, mirroring `AppDelegate.applicationShouldTerminate(_:)`
/// (the existing AC-04/AC-05 Quit gate this task's brief says to mirror):
/// this type's methods are pure/synchronous decision points. The actual
/// blocking `RunStateQuerier.query` call is the *caller*'s job, dispatched
/// off the main thread exactly the way `applicationShouldTerminate` already
/// does it -- this type only ever consumes an already-obtained
/// `RunStateQueryResult`, so every branch here is unit-testable without a
/// real subprocess or a background queue (no `XCTestExpectation` needed,
/// same as `PairingFlowControllerTests`' `ImmediateScheduler`).
///
/// [AC-14] There is no "a run just finished" push/event from the embedded
/// release to this native shell -- only polling. So a confirm received
/// while a run is active does not fail or require a second click later: it
/// transitions to `.awaitingActiveRunToFinish` and stays there until the
/// caller's own periodic poll (`AppDelegate`'s dedicated install-poll
/// timer, piggybacking on the exact same `RunStateQuerier` call the Quit
/// flow and this coordinator's own confirm path already use) reports a
/// terminal/no-run result via `runStateUpdated(_:)`, at which point the
/// install proceeds automatically.
public final class UpdateInstallCoordinator {
    public enum State: Equatable, Sendable {
        /// Nothing confirmed yet, or a previous attempt was `.aborted` and
        /// no new confirmation has been made since.
        case idle
        /// [AC-14] Confirmed while a run was active (or run-state could not
        /// be proven safe) -- waiting for a later `runStateUpdated(_:)` call
        /// to report a terminal/no-run result before installing.
        case awaitingActiveRunToFinish(artifact: PendingUpdateArtifact)
        /// Gatekeeper assessment passed and `InstallExecuting` reported the
        /// helper actually started. Terminal state for this coordinator's
        /// own scope -- the real install/relaunch happens in the detached
        /// helper after this app quits (see `HelperScriptInstallExecutor`).
        case installHandedOff(artifact: PendingUpdateArtifact)
        /// Gatekeeper assessment failed, or the installer handoff itself
        /// failed to start -- install aborted, nothing on disk touched
        /// beyond the already-downloaded artifact. `reason` is a
        /// log-friendly string, not user-facing copy.
        case aborted(reason: String)
    }

    private let gatekeeperAssess: (URL) -> Bool
    private let installExecutor: InstallExecuting
    private let runningAppBundlePath: () -> String
    private let onStateChange: (State) -> Void
    private let log: (String) -> Void

    public private(set) var state: State = .idle

    public init(
        commandRunner: CommandRunning,
        installExecutor: InstallExecuting,
        runningAppBundlePath: @escaping () -> String = { Bundle.main.bundlePath },
        onStateChange: @escaping (State) -> Void = { _ in },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.gatekeeperAssess = { url in GatekeeperAssessor.assess(artifactURL: url, runner: commandRunner) }
        self.installExecutor = installExecutor
        self.runningAppBundlePath = runningAppBundlePath
        self.onStateChange = onStateChange
        self.log = log
    }

    /// [AC-13/AC-14] The operator activated "Install and Relaunch".
    /// `runStateResult` is the caller's already-obtained
    /// `RunStateQuerier.query(...)` result -- see this type's doc comment
    /// on why the querying itself is not this type's job.
    ///
    /// A confirmation received while already `.awaitingActiveRunToFinish`
    /// or `.installHandedOff` is a no-op (mirrors
    /// `PairingFlowController.handle(urlString:)`'s own
    /// inFlight/succeeded-ignores-a-second-call guard): the operator is
    /// never asked to confirm twice, and there is nothing a second
    /// confirmation could usefully change once the first is already
    /// in flight toward installing.
    public func confirmInstall(artifact: PendingUpdateArtifact, runStateResult: RunStateQueryResult) {
        switch state {
        case .awaitingActiveRunToFinish, .installHandedOff:
            return
        case .idle, .aborted:
            break
        }

        if Self.blocksInstall(runStateResult) {
            log("run active (or run-state unprovable) at confirm time; deferring install of \(artifact.version)")
            transition(to: .awaitingActiveRunToFinish(artifact: artifact))
            return
        }

        proceedPastActiveRunGate(artifact: artifact)
    }

    /// [AC-14] A later run-state poll, taken while an install may or may not
    /// be deferred. Safe to call on every periodic poll cycle regardless of
    /// current state -- a no-op unless this coordinator is currently
    /// `.awaitingActiveRunToFinish` (mirrors `AppDelegate.pollConnectionStatus()`'s
    /// existing "always safe to call" polling shape).
    public func runStateUpdated(_ runStateResult: RunStateQueryResult) {
        guard case .awaitingActiveRunToFinish(let artifact) = state else { return }
        guard !Self.blocksInstall(runStateResult) else { return }

        log("deferred run reached a terminal state; proceeding with install of \(artifact.version)")
        proceedPastActiveRunGate(artifact: artifact)
    }

    /// [AC-13/AC-14] The active-run gate has now passed (either immediately
    /// at confirm time, or after a later poll). From here on the path is
    /// identical regardless of which one triggered it: Gatekeeper-verify
    /// the artifact, then hand off to the installer.
    private func proceedPastActiveRunGate(artifact: PendingUpdateArtifact) {
        guard gatekeeperAssess(artifact.fileURL) else {
            log("Gatekeeper assessment failed for \(artifact.fileURL.path); aborting install, nothing touched")
            transition(to: .aborted(reason: "Gatekeeper assessment failed"))
            return
        }

        let handedOff = installExecutor.beginInstall(
            artifact: artifact,
            runningAppBundlePath: runningAppBundlePath()
        )
        guard handedOff else {
            log("install helper failed to start for \(artifact.fileURL.path)")
            transition(to: .aborted(reason: "install helper failed to start"))
            return
        }

        transition(to: .installHandedOff(artifact: artifact))
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange(newState)
    }

    /// [AC-14] Fail-safe wrapper around `ActiveRunChecker.isActive` (the
    /// canonical active/terminal split this task reuses rather than
    /// duplicating): a failed query cannot prove no run is active, so it is
    /// treated the same as an active one. Mirrors
    /// `ActiveRunChecker.shouldWarnBeforeQuit(queryResult:)`'s own
    /// `.queryFailed -> true` fail-safe without reusing that Quit-specific
    /// name for what is, here, a different action (deferring an install,
    /// not warning before quitting).
    private static func blocksInstall(_ result: RunStateQueryResult) -> Bool {
        switch result {
        case .success(let currentLifecycle):
            return ActiveRunChecker.isActive(currentLifecycle: currentLifecycle)
        case .queryFailed:
            return true
        }
    }
}
