import Foundation
@testable import SDDOrchestratorWorkerCore

/// A `CommandRunning` fake: records the call it received and returns a
/// canned `CommandResult`, so tests never shell out to a real process.
final class FakeCommandRunner: CommandRunning {
    private(set) var lastExecutable: String?
    private(set) var lastArguments: [String]?
    private(set) var callCount = 0

    private let result: CommandResult

    init(result: CommandResult) {
        self.result = result
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        callCount += 1
        lastExecutable = executable
        lastArguments = arguments
        return result
    }
}
