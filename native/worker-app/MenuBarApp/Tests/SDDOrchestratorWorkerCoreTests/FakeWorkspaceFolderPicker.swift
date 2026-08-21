@testable import SDDOrchestratorWorkerCore

/// A `WorkspaceFolderPicking` fake: returns a canned result (a path, or
/// `nil` for "operator canceled") without presenting any real UI.
final class FakeWorkspaceFolderPicker: WorkspaceFolderPicking {
    private let result: String?
    private(set) var callCount = 0

    init(result: String?) {
        self.result = result
    }

    func pickWorkspaceFolder() -> String? {
        callCount += 1
        return result
    }
}
