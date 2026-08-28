import Foundation

/// **specs/39 Task 3's extension point.** A worker paired from this app's
/// menu bar is authorized for this Mac, not for a project, so the only
/// thing left to resolve before its configuration can be stored is the
/// coding agent this machine runs (`agent_adapter`/`agent_executable` —
/// see `SddOrchestrator.Worker.Configuration`'s required fields). Task 3
/// owns how that is resolved: auto-detection first, a manual-entry
/// fallback when detection finds none, and the choice stored once for the
/// Mac. `MacCodingAgentSetup` is that implementation, and the one the app
/// wires in.
///
/// Task 2 only defined where that work plugs in, so the retention path it
/// does own (`MacPairingRetention`) could be written and proved before
/// Task 3's UI existed. Deliberately narrower than
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

/// The honest inert double: logs once and resolves nothing. No detection,
/// no prompt, no stored choice — exactly like
/// `UnimplementedPostPairingSetupCoordinator` was for specs/36 Task 4.
///
/// It was the app's wiring while Task 3 was outstanding. The app now wires
/// `MacCodingAgentSetup` instead, so this type is kept only as the "no
/// agent could be resolved" double that `MacPairingRetention`'s tests drive
/// the nothing-is-half-stored path with.
///
/// What it still describes, exactly, is the shape of that path: with an
/// unresolvable agent a redemption stores nothing and the menu bar stays on
/// "Paired, setting up…", and nothing keeps the credential in the meantime,
/// because `MacPairingRetention` returns before it writes and this app
/// holds no store of its own.
public final class UnresolvedMacCodingAgent: MacCodingAgentResolving {
    public init() {}

    public func resolveMacCodingAgent() -> DetectedAgent? {
        FileHandle.standardError.write(
            Data("SDD Orchestrator Worker: this Mac's coding agent is not set up yet (specs/39 Task 3)\n".utf8)
        )
        return nil
    }
}
