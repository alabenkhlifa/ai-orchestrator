import Foundation

/// Launches, supervises, and stops the embedded release's `bin/worker
/// start` child process.
///
/// `bin/worker start` (see the release's own shell script) `exec`s the real
/// BEAM VM in place — it never forks a grandchild — so the current
/// `Process` handle is the running worker for as long as it is alive.
///
/// Supervision here is intentionally simple, per this task's scope: detect
/// and log an unexpected exit (the child dying on its own, not from a stop
/// this controller itself requested). No auto-restart — that is explicitly
/// deferred. A restart this controller is *asked* for is a different thing
/// and is what `restartWorkerRuntime()` answers.
public final class WorkerProcessController: WorkerRuntimeRestarting {
    private let workerBinaryPath: String
    private let runner: CommandRunning
    private let lock = NSLock()

    // The child in hand. A `var`, and created per launch rather than once
    // in `init`, because a `Process` is single-use: it cannot be run again
    // after it exits, so a restart needs a fresh one.
    private var process: Process?

    // [specs/43 Task 4] Which children this controller itself asked to
    // stop, so an exit it caused is never reported as unexpected. Held by
    // identity rather than as one shared flag: a restart starts the new
    // child while the old child's termination handler may still be in
    // flight, and a single flag would either let the new child inherit the
    // old one's expectation or blame the old one's exit on nobody.
    private var expectedStops: Set<ObjectIdentifier> = []

    /// Called (on an arbitrary queue — hop to main yourself if touching UI)
    /// when the embedded process exits without this controller having
    /// requested it.
    public var onUnexpectedExit: ((Int32) -> Void)?

    public init(workerBinaryPath: String, runner: CommandRunning = ProcessCommandRunner()) {
        self.workerBinaryPath = workerBinaryPath
        self.runner = runner
    }

    /// Whether the embedded process is currently believed to be running.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Starts `bin/worker start` as a child process.
    public func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: workerBinaryPath)
        process.arguments = ["start"]
        // Inherit this app's own stdio so a manual `open`/direct-binary run
        // shows the embedded release's log output for debugging; the real
        // `.app` launch (Finder/LaunchServices) has no attached terminal
        // either way.
        process.terminationHandler = { [weak self] finishedProcess in
            self?.handleTermination(of: finishedProcess, status: finishedProcess.terminationStatus)
        }

        lock.lock()
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
            throw error
        }
    }

    /// [specs/43 Task 4, AC-01] Stops the child this controller holds and
    /// starts a fresh one, which loads whatever configuration is on disk
    /// now. That is how a just-stored configuration becomes a running
    /// worker without asking the already-booted node to start anything,
    /// which is a call Erlang distribution has to be available for.
    ///
    /// Reuses `stop`/`start` rather than a second launch path, so the
    /// stop stays graceful and the new child is watched exactly like the
    /// first one. A controller whose release is not running restarts fine:
    /// `stop` no-ops and this becomes the start.
    public func restartWorkerRuntime() -> Bool {
        stop()

        do {
            try start()
            return true
        } catch {
            FileHandle.standardError.write(
                Data("SDD Orchestrator Worker: failed to restart the embedded release: \(error)\n".utf8)
            )
            return false
        }
    }

    private func handleTermination(of process: Process, status: Int32) {
        lock.lock()
        let wasExpected = expectedStops.remove(ObjectIdentifier(process)) != nil
        lock.unlock()

        if !wasExpected {
            FileHandle.standardError.write(
                Data(
                    "SDD Orchestrator Worker: embedded worker process exited unexpectedly (status \(status))\n"
                        .utf8
                )
            )
            onUnexpectedExit?(status)
        }
    }

    /// Stops the embedded release: `bin/worker rpc "System.stop()"` for a
    /// graceful shutdown, then SIGTERM, then SIGKILL if it still has not
    /// exited within `timeout`. A no-op if the process is not running.
    public func stop(timeout: TimeInterval = 10) {
        lock.lock()
        let process = self.process
        let isRunning = process?.isRunning ?? false
        if let process, isRunning { expectedStops.insert(ObjectIdentifier(process)) }
        lock.unlock()

        guard let process, isRunning else { return }

        _ = runner.run(executable: workerBinaryPath, arguments: ["rpc", "System.stop()"], timeout: timeout)

        if waitUntilStopped(process, timeout: timeout) { return }

        process.terminate()
        if waitUntilStopped(process, timeout: 2) { return }

        kill(process.processIdentifier, SIGKILL)
        _ = waitUntilStopped(process, timeout: 2)
    }

    private func waitUntilStopped(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return !process.isRunning
    }
}
