import Foundation
@testable import SDDOrchestratorWorkerCore

/// A `CommandRunning` fake for `CodingAgentDetector`'s `which <command>`
/// fallback: returns a canned resolved path per command name (the last
/// argument passed to `/usr/bin/which`), or a failing result for any
/// command not in `paths`.
final class FakeWhichCommandRunner: CommandRunning {
    private let paths: [String: String]
    private(set) var callCount = 0
    private(set) var lastArguments: [String]?

    init(paths: [String: String]) {
        self.paths = paths
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        callCount += 1
        lastArguments = arguments

        guard let command = arguments.last, let path = paths[command] else {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "", timedOut: false)
        }
        return CommandResult(exitCode: 0, standardOutput: path + "\n", standardError: "", timedOut: false)
    }
}
