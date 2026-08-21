import Foundation

/// [AC-19] Presents the native repository-folder picker — no manual path
/// entry — and returns the operator's chosen absolute path, or `nil` if the
/// operator canceled.
///
/// The real implementation (`NSOpenPanelWorkspaceFolderPicker`, in the
/// `SDDOrchestratorWorkerApp` target) wraps `NSOpenPanel`. Kept as a
/// protocol here, in the plain-Foundation Core target, so
/// `PostPairingSetupCoordinatorImpl`'s cancel-aborts-cleanly decision is
/// unit-testable against a fake instead of a real modal dialog — matching
/// this package's "thin AppKit glue over a testable Core" split.
public protocol WorkspaceFolderPicking {
    func pickWorkspaceFolder() -> String?
}
