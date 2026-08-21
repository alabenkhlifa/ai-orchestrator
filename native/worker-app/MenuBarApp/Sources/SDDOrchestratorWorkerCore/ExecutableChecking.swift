import Foundation

/// Checks whether a filesystem path is a directly-executable file — used by
/// `CodingAgentDetector` to probe common coding-agent install locations
/// (`/usr/local/bin/claude`, `/opt/homebrew/bin/claude`, and the `codex`
/// equivalents) without shelling out. Kept as a protocol, the same way
/// `CommandRunning` is, so detection stays unit-testable against a fake
/// instead of the real filesystem.
public protocol ExecutableChecking {
    func isExecutableFile(atPath path: String) -> Bool
}

/// The production `ExecutableChecking` implementation: a real `FileManager`
/// check.
public final class FileManagerExecutableChecker: ExecutableChecking {
    public init() {}

    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
