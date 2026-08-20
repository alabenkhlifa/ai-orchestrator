import Foundation

/// The production `InstallExecuting`: writes `InstallHelperScriptBuilder`'s
/// script to a private temp file next to the downloaded artifact, makes it
/// executable, and spawns it as a detached `/bin/sh` process this app never
/// `waitUntilExit()`s or reaps.
///
/// On macOS a child process is not killed when its parent quits (there is
/// no automatic process-group teardown on a normal `NSApp` termination), and
/// a child this app never waits on is simply reparented to `launchd` once
/// this app's process actually exits -- not left as a zombie, since nothing
/// here ever calls `wait()`/`waitpid()` on it. So once `beginInstall`
/// returns `true` (the helper's own `Process.isRunning` was observed
/// `true` immediately after launch), the helper is safely independent of
/// this app's own lifetime, and `UpdateInstallCoordinator` is clear to
/// trigger `applicationShouldTerminate(_:)`.
///
/// Deliberately thin, matching this package's other real-OS-adapter
/// production classes (`ProcessCommandRunner`, `URLSessionPairingHTTPPoster`)
/// which likewise have no dedicated unit test of their own -- there is no
/// safe, fast way to unit-test a real detached-process spawn against a real
/// `.dmg` without either a signed artifact or a process left running past
/// the test. `UpdateInstallCoordinatorTests` covers every decision this
/// type's caller makes against a fake `InstallExecuting` instead; see this
/// task's brief for the manual, non-automated proof of the mount/copy/swap
/// mechanics this type's spawned script performs.
public final class HelperScriptInstallExecutor: InstallExecuting {
    private let fileManager: FileManager
    private let processIdentifier: () -> Int32

    public init(
        fileManager: FileManager = .default,
        processIdentifier: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier }
    ) {
        self.fileManager = fileManager
        self.processIdentifier = processIdentifier
    }

    public func beginInstall(artifact: PendingUpdateArtifact, runningAppBundlePath: String) -> Bool {
        let scriptURL = artifact.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("install-\(UUID().uuidString).sh", isDirectory: false)

        do {
            try InstallHelperScriptBuilder.build().write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(processIdentifier()),
            artifact.fileURL.path,
            runningAppBundlePath
        ]
        // No stdio this app can still read once it has quit -- the helper
        // logs to install.log next to the artifact instead (see
        // InstallHelperScriptBuilder).
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        return process.isRunning
    }
}
