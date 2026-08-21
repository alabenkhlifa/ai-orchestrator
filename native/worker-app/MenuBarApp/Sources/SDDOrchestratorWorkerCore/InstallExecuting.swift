import Foundation

/// specs/36 Task 11's install-and-relaunch handoff seam: given a verified
/// (checksum-matched — Task 10 — and Gatekeeper-assessed — `GatekeeperAssessor`)
/// update artifact and this app's own running bundle path, hands off to the
/// actual install-and-relaunch mechanism and reports whether the handoff
/// itself succeeded.
///
/// Deliberately synchronous and fire-and-forget beyond that one `Bool`: the
/// real install (mounting the `.dmg`, replacing the bundle, relaunching)
/// happens in a detached helper process *after* this app has quit (see
/// `HelperScriptInstallExecutor`), so there is nothing further for a caller
/// to await here — `UpdateInstallCoordinator` only needs to know "did the
/// helper actually start" before triggering
/// `applicationShouldTerminate(_:)`.
///
/// Kept as a protocol specifically so `UpdateInstallCoordinator`'s
/// confirm -> gate -> verify -> install decision chain is unit-testable
/// against a fake, matching this package's "thin AppKit glue over a
/// testable Core" split (see `PostPairingSetupCoordinator`,
/// `WorkspaceFolderPicking`).
public protocol InstallExecuting {
    func beginInstall(artifact: PendingUpdateArtifact, runningAppBundlePath: String) -> Bool
}
