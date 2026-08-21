import AppKit
import SDDOrchestratorWorkerCore

/// The real `WorkspaceFolderPicking`: a native `NSOpenPanel` restricted to
/// directories (AC-19 — no manual path entry).
///
/// `beginPostPairingSetup` runs on `PairingFlowController`'s background
/// scheduler, not the main thread, but `NSOpenPanel.runModal()` must run on
/// the main thread. This hops to main and blocks the calling (background)
/// thread until the operator responds, which is safe here because the main
/// thread is never itself waiting on that background work.
final class NSOpenPanelWorkspaceFolderPicker: WorkspaceFolderPicking {
    func pickWorkspaceFolder() -> String? {
        if Thread.isMainThread {
            return presentPanel()
        }

        var result: String?
        DispatchQueue.main.sync {
            result = presentPanel()
        }
        return result
    }

    private func presentPanel() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repository"
        panel.message = "Choose the repository this worker will use"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
