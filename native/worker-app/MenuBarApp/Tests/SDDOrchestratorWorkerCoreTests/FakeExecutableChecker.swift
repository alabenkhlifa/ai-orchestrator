@testable import SDDOrchestratorWorkerCore

/// An `ExecutableChecking` fake: reports a fixed set of paths as
/// executable, everything else as not — never touches the real filesystem.
final class FakeExecutableChecker: ExecutableChecking {
    private let executablePaths: Set<String>

    init(executablePaths: [String]) {
        self.executablePaths = Set(executablePaths)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}
