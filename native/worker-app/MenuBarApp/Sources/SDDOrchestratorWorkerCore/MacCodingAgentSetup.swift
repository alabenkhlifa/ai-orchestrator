import Foundation

/// [specs/39 Task 3, AC-03] This Mac's coding-agent setup step: the real
/// `MacCodingAgentResolving` that `UnresolvedMacCodingAgent` stood in for.
///
/// It answers the one question `MacPairingRetention` cannot answer itself —
/// which coding agent this machine runs (`agent_adapter`/`agent_executable`,
/// two of `SddOrchestrator.Worker.Configuration`'s required fields) — by
/// auto-detecting first and asking only when detection leaves the answer
/// open.
///
/// **The three branches, and why the middle one is not a violation of
/// AC-03's "manual entry only when detection finds none":**
///
///   * Exactly one agent detected — the whole point of AC-03's
///     auto-detection. `selectionPrompt` is never touched, so nothing is
///     shown and nothing is typed.
///   * None detected — `selectionPrompt.resolveCodingAgent(detected: [])`,
///     which is the manual-entry case by that protocol's own contract: an
///     empty list is the one input for which it offers a path field. This
///     is the only way manual entry is reached.
///   * Both detected — `selectionPrompt.resolveCodingAgent(detected:)` with
///     both candidates. It looks like a second prompt path, but it is not
///     manual entry: given a non-empty list the prompt offers a choice
///     between two *already-resolved* executables and no path may be typed
///     (see `AgentSelectionPrompting` and `AgentSelectionAlertPrompt`).
///     Auto-detection still decided the executable; the person only decides
///     which of the two found agents to use.
///
/// Mirrors `PostPairingSetupCoordinatorImpl`'s branching deliberately: that
/// is specs/36's project-scoped deep-link path, this is the Mac-scoped menu
/// bar path, and the two stay separate types rather than one shared one
/// because everything *around* the agent question differs (a folder, a
/// project id, a different stored configuration shape).
///
/// **It never asks the person for a repository folder.** It holds no
/// `WorkspaceFolderPicking`, takes no project id, and takes no repository
/// path — the type's own shape is the guarantee, the same way
/// `MacPairingRetention`'s is, not a check made at run time. A worker paired
/// from the menu bar is authorized for this Mac; which repository it later
/// works in is a question the dashboard asks.
public final class MacCodingAgentSetup: MacCodingAgentResolving {
    private let executableChecker: ExecutableChecking
    private let commandRunner: CommandRunning
    private let selectionPrompt: AgentSelectionPrompting

    private let lock = NSLock()
    private var resolvedAgent: DetectedAgent?

    public init(
        executableChecker: ExecutableChecking = FileManagerExecutableChecker(),
        commandRunner: CommandRunning,
        selectionPrompt: AgentSelectionPrompting
    ) {
        self.executableChecker = executableChecker
        self.commandRunner = commandRunner
        self.selectionPrompt = selectionPrompt
    }

    /// Resolves the agent once per instance and remembers it: AC-03 makes
    /// the choice a property of the Mac, made once, so a later call returns
    /// the same answer without re-detecting and without showing the person
    /// a dialog they already answered. (The pairing loop can complete more
    /// than once across a launch — see `MacPairingRetention`'s idempotency
    /// note — and each completion asks for the agent again.)
    ///
    /// A `nil` answer is deliberately *not* remembered. `nil` means the
    /// person canceled the prompt, and a cancel is a "not now", not a
    /// stored decision: the next attempt detects and asks again.
    ///
    /// Called from a background queue (`AppDelegate` runs the whole
    /// retention off the main thread because `bin/worker rpc` blocks), so
    /// the memo is guarded by an `NSLock` the same way
    /// `PairingFlowController` guards its session state. The lock is held
    /// only across reading and writing that memo, never across
    /// `selectionPrompt`: the real prompt blocks on the main thread, and
    /// holding a lock across it would deadlock any future main-thread
    /// caller. The cost is that two genuinely simultaneous first calls
    /// could both prompt, which this app cannot produce — retention runs
    /// one call per redemption and never two at once.
    public func resolveMacCodingAgent() -> DetectedAgent? {
        if let alreadyResolved = rememberedAgent() {
            return alreadyResolved
        }

        let detected = CodingAgentDetector.detect(
            executableChecker: executableChecker,
            commandRunner: commandRunner
        )

        let resolved: DetectedAgent?
        if detected.count == 1 {
            resolved = detected[0]
        } else {
            resolved = selectionPrompt.resolveCodingAgent(detected: detected)
        }

        if let resolved {
            remember(resolved)
        }

        return resolved
    }

    private func rememberedAgent() -> DetectedAgent? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedAgent
    }

    private func remember(_ agent: DetectedAgent) {
        lock.lock()
        resolvedAgent = agent
        lock.unlock()
    }
}
