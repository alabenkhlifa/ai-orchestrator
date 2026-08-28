import Foundation

/// **specs/39 Task 3's extension point.** A worker paired from this app's
/// menu bar is authorized for this Mac, not for a project, so the only
/// thing left to resolve before its configuration can be stored is the
/// coding agent this machine runs (`agent_adapter`/`agent_executable` —
/// see `SddOrchestrator.Worker.Configuration`'s required fields). Task 3
/// owns how that is resolved: auto-detection first, a manual-entry
/// fallback when detection finds none, and the choice stored once for the
/// Mac.
///
/// Task 2 only defines where that work plugs in, so the retention path it
/// does own (`MacPairingRetention`) can be written and proved now without
/// Task 3's UI existing. Deliberately narrower than
/// `AgentSelectionPrompting`, which takes an already-detected candidate
/// list because `PostPairingSetupCoordinatorImpl` runs the detection
/// itself: here the detection *is* Task 3's, so the whole question is one
/// call with no input.
///
/// Returning `nil` means "no agent could be resolved". `MacPairingRetention`
/// then stops with nothing stored — never a half-configured worker whose
/// `worker.json` names an agent it cannot run.
public protocol MacCodingAgentResolving {
    func resolveMacCodingAgent() -> DetectedAgent?
}

/// The only implementation until Task 3 lands: logs once and resolves
/// nothing. Deliberately inert — no detection, no prompt, no stored
/// choice — exactly like `UnimplementedPostPairingSetupCoordinator` was
/// for specs/36 Task 4.
///
/// With this wired in, a redemption stores nothing and the menu bar stays
/// on "Paired, setting up…" for the rest of the launch, because the setup
/// Task 3 owns has not run. Nothing keeps the credential in the meantime:
/// `MacPairingRetention` returns before it writes, and this app holds no
/// store of its own. That is the interim state Task 3 closes, and it is why
/// AC-01's stored-credential outcome is only reachable in production once
/// Task 3 lands.
public final class UnresolvedMacCodingAgent: MacCodingAgentResolving {
    public init() {}

    public func resolveMacCodingAgent() -> DetectedAgent? {
        FileHandle.standardError.write(
            Data("SDD Orchestrator Worker: this Mac's coding agent is not set up yet (specs/39 Task 3)\n".utf8)
        )
        return nil
    }
}
