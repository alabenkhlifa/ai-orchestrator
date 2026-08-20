import Foundation

/// [AC-20] The fallback UI, used only when `CodingAgentDetector` did not
/// land on exactly one candidate:
///
///   * `detected.isEmpty` — neither agent was found automatically. The
///     operator picks Claude Code or Codex and types its executable path —
///     the one place a path may be typed, gated on auto-detection finding
///     none.
///   * `detected.count > 1` — both were found. The operator (or a default)
///     picks between the two already-resolved candidates; no manual path
///     entry, since both already have resolved paths.
///
/// Returns `nil` if the operator canceled.
///
/// The real implementation (`AgentSelectionAlertPrompt`, in the
/// `SDDOrchestratorWorkerApp` target) wraps `NSAlert`. Kept as a protocol
/// here, in the plain-Foundation Core target, so
/// `PostPairingSetupCoordinatorImpl`'s branching is unit-testable against a
/// fake instead of a real modal dialog.
public protocol AgentSelectionPrompting {
    func resolveCodingAgent(detected: [DetectedAgent]) -> DetectedAgent?
}
