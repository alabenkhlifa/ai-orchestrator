import Foundation

/// The result of running one external command to completion (or to a
/// timeout).
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

/// Runs one external command and waits (up to a timeout) for it to finish.
///
/// Every place this app shells out to the embedded release's
/// `bin/worker eval` (pairing status, run state, protocol version) goes
/// through this seam so those decisions can be unit tested against a fake
/// implementation instead of a real running process.
///
/// [specs/43 Task 5, AC-05] `eval` is the only release command left on this
/// seam. It boots a short-lived VM that reads a file, so it needs no name
/// service, no listening socket, and no incoming connection.
/// `DistributionFreeCallSitesTests` holds that line.
public protocol CommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult
}

/// The production `CommandRunning` implementation: a real `Process`.
public final class ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(
                exitCode: -1,
                standardOutput: "",
                standardError: "failed to launch \(executable): \(error)",
                timedOut: false
            )
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut

        if timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
