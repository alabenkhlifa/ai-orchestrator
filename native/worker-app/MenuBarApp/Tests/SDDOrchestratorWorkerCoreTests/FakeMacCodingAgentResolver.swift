@testable import SDDOrchestratorWorkerCore

/// A `MacCodingAgentResolving` fake: returns a canned result (a resolved
/// agent, or `nil` for "this Mac's coding agent is not set up yet") and
/// counts the calls, without running detection or presenting any UI.
final class FakeMacCodingAgentResolver: MacCodingAgentResolving {
    private let result: DetectedAgent?
    private(set) var callCount = 0

    init(result: DetectedAgent?) {
        self.result = result
    }

    func resolveMacCodingAgent() -> DetectedAgent? {
        callCount += 1
        return result
    }
}
