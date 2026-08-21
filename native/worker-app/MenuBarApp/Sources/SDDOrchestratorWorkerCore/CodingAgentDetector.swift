import Foundation

/// One coding-agent executable `CodingAgentDetector` resolved (or the
/// operator confirmed through `AgentSelectionPrompting`'s fallback UI).
///
/// `adapter` is one of `SddOrchestrator.Worker.Configuration`'s own
/// `@agent_adapters` closed set (`"claude_code"`/`"codex"`) — duplicated
/// here as a literal, the same way `ActiveRunChecker.activeLifecycles`
/// mirrors `run_state.ex`'s lifecycle set: this app never derives the set
/// live from the embedded release, and the source of truth for the set
/// itself stays `configuration.ex`.
public struct DetectedAgent: Equatable, Sendable {
    public let adapter: String
    public let executablePath: String

    public init(adapter: String, executablePath: String) {
        self.adapter = adapter
        self.executablePath = executablePath
    }
}

/// [AC-20] Auto-detects a working `claude` (Claude Code) and `codex`
/// (Codex) executable, in order, per agent: common install locations first
/// (no shell-out needed), then `which <command>` via `CommandRunning`.
///
/// Returns at most one `DetectedAgent` per supported adapter, in probe
/// order. Deliberately reports what exists rather than deciding what to do
/// about it — `PostPairingSetupCoordinatorImpl` is the one place that
/// decides what "exactly one found" / "none found" / "both found" means for
/// setup.
enum CodingAgentDetector {
    struct Probe {
        let adapter: String
        let commandName: String
        let commonPaths: [String]
    }

    static let probes: [Probe] = [
        Probe(
            adapter: "claude_code",
            commandName: "claude",
            commonPaths: ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        ),
        Probe(
            adapter: "codex",
            commandName: "codex",
            commonPaths: ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        )
    ]

    static func detect(executableChecker: ExecutableChecking, commandRunner: CommandRunning) -> [DetectedAgent] {
        probes.compactMap { probe in
            if let path = probe.commonPaths.first(where: { executableChecker.isExecutableFile(atPath: $0) }) {
                return DetectedAgent(adapter: probe.adapter, executablePath: path)
            }
            if let path = resolveViaWhich(probe.commandName, runner: commandRunner) {
                return DetectedAgent(adapter: probe.adapter, executablePath: path)
            }
            return nil
        }
    }

    private static func resolveViaWhich(_ command: String, runner: CommandRunning) -> String? {
        let result = runner.run(executable: "/usr/bin/which", arguments: [command], timeout: 3)
        guard !result.timedOut, result.exitCode == 0 else { return nil }

        let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
