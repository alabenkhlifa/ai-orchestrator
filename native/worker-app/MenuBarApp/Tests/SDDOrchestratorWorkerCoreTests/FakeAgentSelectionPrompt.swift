@testable import SDDOrchestratorWorkerCore

/// An `AgentSelectionPrompting` fake: returns a canned result (a chosen
/// agent, or `nil` for "operator canceled") and records what it was called
/// with, without presenting any real UI.
final class FakeAgentSelectionPrompt: AgentSelectionPrompting {
    private let result: DetectedAgent?
    private(set) var callCount = 0
    private(set) var lastDetected: [DetectedAgent]?

    init(result: DetectedAgent?) {
        self.result = result
    }

    func resolveCodingAgent(detected: [DetectedAgent]) -> DetectedAgent? {
        callCount += 1
        lastDetected = detected
        return result
    }
}
