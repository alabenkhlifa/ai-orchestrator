import Foundation

/// specs/36 Task 11's pre-install safety gate: verifies a downloaded update
/// artifact still passes Gatekeeper assessment before anything on disk is
/// touched to install it — `spctl --assess --type open <path>`, via
/// `CommandRunning` exactly like every other subprocess check in this
/// package (see `RunStateQuerier`, `PairingStatusChecker`), so this is fully
/// fake-testable against a canned exit code without a real signed/notarized
/// artifact.
///
/// This is a belt-and-suspenders check on top of `AppcastArtifactChecksum`
/// (Task 10's already-verified checksum): the checksum proves the bytes
/// match what the signed appcast entry claimed, while this proves the
/// artifact itself is one Gatekeeper is willing to run — the actual
/// authority macOS applies at real install/launch time. A failed or
/// unparseable assessment must abort the install; there is no fallback
/// "install anyway" path.
public enum GatekeeperAssessor {
    static let executablePath = "/usr/sbin/spctl"

    /// `true` only when `spctl` exits `0` (assessment passed) without
    /// timing out. Any other outcome — a non-zero exit, a timeout, or the
    /// command failing to launch at all (`CommandRunning` reports that as a
    /// non-zero exit itself) — is treated as "not assessed" and must block
    /// the install.
    public static func assess(artifactURL: URL, runner: CommandRunning, timeout: TimeInterval = 15) -> Bool {
        let result = runner.run(
            executable: executablePath,
            arguments: ["--assess", "--type", "open", artifactURL.path],
            timeout: timeout
        )
        return !result.timedOut && result.exitCode == 0
    }
}
