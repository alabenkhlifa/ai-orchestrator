import Foundation
import XCTest
@testable import SDDOrchestratorWorkerCore

/// [specs/43 Task 5, AC-03] The stop path, exercised against a real child
/// process.
///
/// A stand-in stands in for `bin/worker`: a shell script that records every
/// invocation of itself and then stays alive. That is what makes "no command
/// was run" observable — a stop that shelled out to `bin/worker rpc` would
/// run the very same script and leave a second line in the log. A fake
/// `CommandRunning` could not prove this any more, because the controller no
/// longer has one to fake.
final class WorkerProcessControllerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worker-process-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    // MARK: - Stopping a running child

    func test_stop_endsTheRunningChildWithoutRunningAnyCommand() throws {
        let binary = try installWorkerStandIn(ignoresSIGTERM: false)
        let controller = WorkerProcessController(workerBinaryPath: binary)

        try controller.start()
        try waitUntilStandInIsUp()
        XCTAssertTrue(controller.isRunning)

        controller.stop(timeout: 3)

        XCTAssertFalse(controller.isRunning, "the embedded release must be stopped once stop returns")
        // The only invocation of the binary is the launch itself. AC-03 is
        // that quitting works where Erlang distribution does not, so the
        // stop must not reach for the release's start script at all.
        XCTAssertEqual(try invocations(), ["start"])
    }

    func test_stop_returnsWellWithinItsBudgetForAChildThatHonorsSIGTERM() throws {
        // The old sequence spent its whole timeout on an rpc round trip that
        // could never answer on a distribution-blocked Mac, and only then
        // signalled. A signal is immediate, so this is now fast.
        let binary = try installWorkerStandIn(ignoresSIGTERM: false)
        let controller = WorkerProcessController(workerBinaryPath: binary)

        try controller.start()
        try waitUntilStandInIsUp()

        let started = Date()
        controller.stop(timeout: 5)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(controller.isRunning)
        XCTAssertLessThan(elapsed, 2, "a child that honors SIGTERM must not cost the whole budget")
    }

    func test_stop_killsAChildThatIgnoresSIGTERM() throws {
        let binary = try installWorkerStandIn(ignoresSIGTERM: true)
        let controller = WorkerProcessController(workerBinaryPath: binary)

        try controller.start()
        try waitUntilStandInIsUp()
        XCTAssertTrue(controller.isRunning)

        // A small budget so the graceful grace period is the floor, not four
        // seconds of a test suite's time. SIGKILL is the last resort and
        // cannot be refused.
        controller.stop(timeout: 0.6)

        XCTAssertFalse(controller.isRunning, "a child that ignores SIGTERM must still be killed")
        XCTAssertEqual(try invocations(), ["start"])
    }

    // MARK: - Nothing running

    func test_stop_withNothingRunning_isANoOp() throws {
        let binary = try installWorkerStandIn(ignoresSIGTERM: false)
        let controller = WorkerProcessController(workerBinaryPath: binary)

        XCTAssertFalse(controller.isRunning)
        controller.stop(timeout: 3)

        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: invocationLogPath),
            "a stop with nothing running must not launch or signal anything"
        )
    }

    func test_stop_afterTheChildAlreadyExited_isANoOpAndDoesNotSignalAgain() throws {
        let binary = try installWorkerStandIn(ignoresSIGTERM: false)
        let controller = WorkerProcessController(workerBinaryPath: binary)

        try controller.start()
        try waitUntilStandInIsUp()
        controller.stop(timeout: 3)

        controller.stop(timeout: 3)

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(try invocations(), ["start"])
    }

    // MARK: - A stop this controller asked for is not an unexpected exit

    func test_stop_doesNotReportTheExitItCausedAsUnexpected() throws {
        let binary = try installWorkerStandIn(ignoresSIGTERM: false)
        let controller = WorkerProcessController(workerBinaryPath: binary)

        let unexpected = expectation(description: "unexpected exit reported")
        unexpected.isInverted = true
        controller.onUnexpectedExit = { _ in unexpected.fulfill() }

        try controller.start()
        try waitUntilStandInIsUp()
        controller.stop(timeout: 3)

        wait(for: [unexpected], timeout: 0.5)
    }

    // MARK: - The quit flow's active-run check

    func test_theQuitFlowChecksForAnActiveRunBeforeStopping() {
        // `stop` is unconditional by design: it signals whatever child it
        // holds and asks nothing about runs. So the check has to come first,
        // and it does — `AppDelegate.applicationShouldTerminate` queries the
        // run state and consults `ActiveRunChecker` before it ever calls
        // `stopEmbeddedWorkerAndReply`.
        //
        // Only this decision is reachable from the Core target. The ordering
        // itself, the NSAlert, and `.terminateLater` are AppKit and live in
        // `AppDelegate`; they are covered by the browser-free product proof
        // at the slice gate, not here.
        XCTAssertTrue(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .success(currentLifecycle: "accepted")))
        XCTAssertTrue(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .queryFailed))
        XCTAssertFalse(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .success(currentLifecycle: nil)))
    }

    // MARK: - Helpers

    private var invocationLogPath: String {
        directory.appendingPathComponent("invocations.log").path
    }

    /// Writes an executable stand-in for `bin/worker` that logs how it was
    /// called and then stays alive until it is signalled.
    private func installWorkerStandIn(ignoresSIGTERM: Bool) throws -> String {
        let binary = directory.appendingPathComponent("worker")
        let trap = ignoresSIGTERM ? "trap '' TERM\n" : ""
        let script = """
            #!/bin/sh
            echo "$@" >> '\(invocationLogPath)'
            \(trap)while :; do sleep 0.05; done
            """

        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        return binary.path
    }

    /// The stand-in logs its arguments as its first act, so the log
    /// appearing means the child is really up and past `exec`.
    private func waitUntilStandInIsUp(timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: invocationLogPath) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTFail("the worker stand-in never started")
    }

    private func invocations() throws -> [String] {
        let contents = try String(contentsOfFile: invocationLogPath, encoding: .utf8)
        return contents.split(separator: "\n").map(String.init)
    }
}
