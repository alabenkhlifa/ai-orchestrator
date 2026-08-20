import Foundation

/// Launches, supervises, and stops the embedded release's `bin/worker
/// start` child process.
///
/// `bin/worker start` (see the release's own shell script) `exec`s the real
/// BEAM VM in place — it never forks a grandchild — so this one `Process`
/// handle is the running worker for as long as it is alive.
///
/// Supervision here is intentionally simple, per this task's scope: detect
/// and log an unexpected exit (the child dying on its own, not from a Quit
/// this controller itself requested). No auto-restart — that is explicitly
/// deferred.
public final class WorkerProcessController {
    private let workerBinaryPath: String
    private let runner: CommandRunning
    private let process: Process
    private let lock = NSLock()
    private var expectedStop = false
    private var started = false

    /// Called (on an arbitrary queue — hop to main yourself if touching UI)
    /// when the embedded process exits without this controller having
    /// requested it.
    public var onUnexpectedExit: ((Int32) -> Void)?

    public init(workerBinaryPath: String, runner: CommandRunning = ProcessCommandRunner()) {
        self.workerBinaryPath = workerBinaryPath
        self.runner = runner
        self.process = Process()
    }

    /// Whether the embedded process is currently believed to be running.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && process.isRunning
    }

    /// Starts `bin/worker start` as a child process.
    public func start() throws {
        process.executableURL = URL(fileURLWithPath: workerBinaryPath)
        process.arguments = ["start"]
        // Inherit this app's own stdio so a manual `open`/direct-binary run
        // shows the embedded release's log output for debugging; the real
        // `.app` launch (Finder/LaunchServices) has no attached terminal
        // either way.
        process.terminationHandler = { [weak self] finishedProcess in
            self?.handleTermination(status: finishedProcess.terminationStatus)
        }

        try process.run()

        lock.lock()
        started = true
        lock.unlock()
    }

    private func handleTermination(status: Int32) {
        lock.lock()
        let wasExpected = expectedStop
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
        guard isRunning else { return }

        lock.lock()
        expectedStop = true
        lock.unlock()

        _ = runner.run(executable: workerBinaryPath, arguments: ["rpc", "System.stop()"], timeout: timeout)

        if waitUntilStopped(timeout: timeout) { return }

        process.terminate()
        if waitUntilStopped(timeout: 2) { return }

        kill(process.processIdentifier, SIGKILL)
        _ = waitUntilStopped(timeout: 2)
    }

    private func waitUntilStopped(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return !process.isRunning
    }
}
