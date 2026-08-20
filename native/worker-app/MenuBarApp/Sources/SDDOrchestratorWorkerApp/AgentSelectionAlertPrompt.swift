import AppKit
import SDDOrchestratorWorkerCore

/// The real `AgentSelectionPrompting`: a native `NSAlert`-based fallback,
/// used only when auto-detection did not land on exactly one candidate.
///
///   * Auto-detection found nothing (`detected.isEmpty`): the operator
///     picks Claude Code or Codex and types its executable path — the one
///     place a path may be typed, gated on AC-20's "offers manual path
///     entry only when auto-detection finds none".
///   * Auto-detection found both (`detected.count > 1`): the operator picks
///     between the two already-resolved candidates; no manual entry, since
///     both already have resolved paths.
///
/// Runs on the main thread the same way `NSOpenPanelWorkspaceFolderPicker`
/// does, for the same reason: `beginPostPairingSetup` runs on a background
/// queue, but `NSAlert.runModal()` must run on the main thread.
final class AgentSelectionAlertPrompt: AgentSelectionPrompting {
    func resolveCodingAgent(detected: [DetectedAgent]) -> DetectedAgent? {
        if Thread.isMainThread {
            return present(detected: detected)
        }

        var result: DetectedAgent?
        DispatchQueue.main.sync {
            result = present(detected: detected)
        }
        return result
    }

    private func present(detected: [DetectedAgent]) -> DetectedAgent? {
        detected.isEmpty ? presentManualEntry() : presentChoiceAmongDetected(detected)
    }

    // MARK: - Both found: choose between two already-resolved candidates

    private func presentChoiceAmongDetected(_ detected: [DetectedAgent]) -> DetectedAgent? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Choose a coding agent"
        alert.informativeText = "Both Claude Code and Codex were found. Choose which one this worker will use."

        for agent in detected {
            alert.addButton(withTitle: "Use \(displayName(for: agent.adapter)) (\(agent.executablePath))")
        }
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue

        guard index >= 0, index < detected.count else { return nil }
        return detected[index]
    }

    // MARK: - None found: pick an agent type and type its path

    private func presentManualEntry() -> DetectedAgent? {
        var chosenAdapterIsClaudeCode = true

        while true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Coding agent not found automatically"
            alert.informativeText =
                "Neither Claude Code nor Codex was found automatically. Choose which one this worker will use, and enter its executable path."

            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 300, height: 25))
            picker.addItems(withTitles: ["Claude Code", "Codex"])
            picker.selectItem(at: chosenAdapterIsClaudeCode ? 0 : 1)

            let pathField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            pathField.placeholderString = "/path/to/executable"

            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
            accessory.addSubview(picker)
            accessory.addSubview(pathField)
            alert.accessoryView = accessory

            alert.addButton(withTitle: "Use This Agent")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            chosenAdapterIsClaudeCode = picker.indexOfSelectedItem == 0
            let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            if !path.isEmpty {
                return DetectedAgent(adapter: chosenAdapterIsClaudeCode ? "claude_code" : "codex", executablePath: path)
            }
            // Empty path: loop and re-prompt rather than storing a blank
            // executable path or silently pretending setup succeeded.
        }
    }

    private func displayName(for adapter: String) -> String {
        adapter == "claude_code" ? "Claude Code" : "Codex"
    }
}
