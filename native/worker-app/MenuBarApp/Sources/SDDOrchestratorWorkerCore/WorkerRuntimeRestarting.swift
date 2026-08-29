import Foundation

/// [specs/43 Task 4, AC-01] How a stored configuration becomes a running
/// worker on a Mac where Erlang distribution is unavailable.
///
/// Pairing used to end with `bin/worker rpc`, which asks the release's
/// already-booted node to store the configuration and start
/// `Worker.Supervisor`. `rpc` is distribution: it needs `epmd` and a
/// listening socket. A managed Mac's firewall blocks that, so pairing could
/// not finish at all there and the app was unusable, not merely
/// uninformative.
///
/// The release loads its configuration at boot, so restarting it *is*
/// starting the worker, and the app already owns and supervises that child
/// process. This seam is the whole of what the pairing paths need of it:
/// they store the configuration, then ask for a restart. They never learn
/// what a process is, and `WorkerProcessController` stays the one place
/// that starts, watches, and stops the release.
///
/// It also removes the idempotency question the old call answered with
/// `already_started`: a fresh boot has nothing started yet.
public protocol WorkerRuntimeRestarting {
    /// Stops the embedded release if it is running, then starts a fresh
    /// one, which loads whatever configuration is on disk now. Blocks until
    /// the new process is launched, so callers run it off the main thread.
    ///
    /// Returns whether a fresh process is running. `false` means the
    /// configuration is stored but no worker is up: the caller reports that
    /// as an unfinished setup rather than as a paired, connected worker.
    func restartWorkerRuntime() -> Bool
}
