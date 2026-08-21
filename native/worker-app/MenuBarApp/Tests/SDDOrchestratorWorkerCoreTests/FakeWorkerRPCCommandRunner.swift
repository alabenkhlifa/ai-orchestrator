import Foundation
@testable import SDDOrchestratorWorkerCore

/// A `CommandRunning` fake for `PostPairingSetupCoordinatorImpl` tests:
/// distinguishes the `/usr/bin/which` shell-outs `CodingAgentDetector`
/// makes (always answered "not found" — these tests control detection
/// results through `FakeExecutableChecker` instead) from the one real
/// `bin/worker rpc` invocation the coordinator makes to store the
/// configuration and start the worker.
///
/// Without this split, a single canned-result `FakeCommandRunner` would
/// also answer `which codex` with the rpc's own "success" output, making
/// detection see a bogus second agent.
final class FakeWorkerRPCCommandRunner: CommandRunning {
    private let workerBinaryPath: String
    private let rpcResult: CommandResult

    private(set) var rpcCallCount = 0
    private(set) var lastRPCArguments: [String]?
    private(set) var whichCallCount = 0

    /// Invoked synchronously whenever the fake rpc call fires, with that
    /// call's arguments — lets a test inspect state (e.g. "does the temp
    /// config file still exist") at the moment the real call would happen.
    var onRPCCall: (([String]) -> Void)?

    init(workerBinaryPath: String, rpcResult: CommandResult) {
        self.workerBinaryPath = workerBinaryPath
        self.rpcResult = rpcResult
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        guard executable == workerBinaryPath else {
            whichCallCount += 1
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "not found", timedOut: false)
        }

        rpcCallCount += 1
        lastRPCArguments = arguments
        onRPCCall?(arguments)
        return rpcResult
    }
}
