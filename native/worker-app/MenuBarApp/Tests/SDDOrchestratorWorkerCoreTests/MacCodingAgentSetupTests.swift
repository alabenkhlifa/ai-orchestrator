import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/39 Task 3 proof for AC-03: "Given the worker is starting for the
/// first time after pairing, when it resolves the coding agent, then it
/// auto-detects a supported executable and offers manual entry only when
/// detection finds none, and the choice is stored for the Mac."
///
/// **On "and does not ask for a repository folder":** there is deliberately
/// no test that a folder picker went uncalled, because `MacCodingAgentSetup`
/// has no folder picker, no project id, and no repository path to begin
/// with — its initializer takes an executable checker, a command runner and
/// a selection prompt, and nothing else. The type's own shape is the
/// guarantee, the same way `MacPairingRetentionTests` argues it. What is
/// checked below instead is the observable half: what this step's choice
/// puts on disk carries no `project_id` and no `workspace_root`.
final class MacCodingAgentSetupTests: XCTestCase {
    private let claudePath = "/usr/local/bin/claude"
    private let codexPath = "/opt/homebrew/bin/codex"

    private let manuallyEnteredAgent = DetectedAgent(
        adapter: "codex",
        executablePath: "/Users/me/tools/codex"
    )

    private func makeSetup(
        executablePaths: [String],
        prompt: FakeAgentSelectionPrompt,
        commandRunner: FakeWhichCommandRunner
    ) -> MacCodingAgentSetup {
        MacCodingAgentSetup(
            executableChecker: FakeExecutableChecker(executablePaths: executablePaths),
            commandRunner: commandRunner,
            selectionPrompt: prompt
        )
    }

    // MARK: - AC-03: auto-detection resolves a supported executable

    func test_resolveMacCodingAgent_exactlyOneDetected_isUsedWithoutAnyPrompt() {
        let prompt = FakeAgentSelectionPrompt(result: manuallyEnteredAgent)
        let runner = FakeWhichCommandRunner(paths: [:])
        let setup = makeSetup(executablePaths: [claudePath], prompt: prompt, commandRunner: runner)

        XCTAssertEqual(
            setup.resolveMacCodingAgent(),
            DetectedAgent(adapter: "claude_code", executablePath: claudePath)
        )
        XCTAssertEqual(prompt.callCount, 0, "one detected agent is the answer; the person is asked nothing")
    }

    // MARK: - AC-03: manual entry only when detection finds none

    func test_resolveMacCodingAgent_noneDetected_offersManualEntryAndUsesItsAnswer() {
        let prompt = FakeAgentSelectionPrompt(result: manuallyEnteredAgent)
        let runner = FakeWhichCommandRunner(paths: [:])
        let setup = makeSetup(executablePaths: [], prompt: prompt, commandRunner: runner)

        XCTAssertEqual(setup.resolveMacCodingAgent(), manuallyEnteredAgent)
        XCTAssertEqual(prompt.callCount, 1)
        // An empty `detected` list is exactly what makes the prompt a manual
        // entry: see `AgentSelectionPrompting`, where the path field is
        // offered for that input and only that input.
        XCTAssertEqual(prompt.lastDetected, [], "manual entry is reached by handing the prompt an empty list")
    }

    func test_resolveMacCodingAgent_bothDetected_choosesBetweenResolvedPaths_soNoManualEntryIsOffered() {
        let prompt = FakeAgentSelectionPrompt(result: DetectedAgent(adapter: "codex", executablePath: codexPath))
        let runner = FakeWhichCommandRunner(paths: [:])
        let setup = makeSetup(executablePaths: [claudePath, codexPath], prompt: prompt, commandRunner: runner)

        XCTAssertEqual(setup.resolveMacCodingAgent(), DetectedAgent(adapter: "codex", executablePath: codexPath))
        XCTAssertEqual(prompt.callCount, 1)
        // The prompt is called with a non-empty list, which is the branch
        // that offers a choice between two already-detected executables and
        // no path field. Detection still resolved both paths, so AC-03's
        // "manual entry only when detection finds none" holds.
        XCTAssertEqual(
            prompt.lastDetected,
            [
                DetectedAgent(adapter: "claude_code", executablePath: claudePath),
                DetectedAgent(adapter: "codex", executablePath: codexPath)
            ]
        )
    }

    // MARK: - AC-03: the choice is stored for the Mac, and made once

    func test_resolveMacCodingAgent_answersOnce_thenRepeatsItWithoutDetectingOrPromptingAgain() {
        let prompt = FakeAgentSelectionPrompt(result: manuallyEnteredAgent)
        let runner = FakeWhichCommandRunner(paths: [:])
        let setup = makeSetup(executablePaths: [], prompt: prompt, commandRunner: runner)

        XCTAssertEqual(setup.resolveMacCodingAgent(), manuallyEnteredAgent)
        let whichCallsAfterFirstAnswer = runner.callCount
        XCTAssertEqual(prompt.callCount, 1)

        XCTAssertEqual(setup.resolveMacCodingAgent(), manuallyEnteredAgent, "the Mac's agent is decided once")
        XCTAssertEqual(runner.callCount, whichCallsAfterFirstAnswer, "a decided agent is not detected again")
        XCTAssertEqual(prompt.callCount, 1, "a decided agent is not asked about again")
    }

    func test_resolveMacCodingAgent_canceledPrompt_isNotRemembered_soTheNextAttemptAsksAgain() {
        let prompt = FakeAgentSelectionPrompt(result: nil)
        let runner = FakeWhichCommandRunner(paths: [:])
        let setup = makeSetup(executablePaths: [], prompt: prompt, commandRunner: runner)

        XCTAssertNil(setup.resolveMacCodingAgent())
        let whichCallsAfterCancel = runner.callCount
        XCTAssertEqual(prompt.callCount, 1)

        // A cancel is "not now", not a stored decision.
        XCTAssertNil(setup.resolveMacCodingAgent())
        XCTAssertGreaterThan(runner.callCount, whichCallsAfterCancel, "a canceled attempt detects again")
        XCTAssertEqual(prompt.callCount, 2, "a canceled attempt asks again")
    }

    // MARK: - AC-03: the resolved choice reaches this Mac's stored configuration

    func test_resolvedAgent_isStoredForTheMac_withNoProjectAndNoRepositoryFolder() throws {
        let worker = WorkerIdentity(
            id: "worker-1",
            deviceWorkspaceID: "ws-1",
            osFamily: "macos",
            osMajor: "15",
            protocolVersion: "1",
            appVersion: "1.0.0",
            state: "active"
        )

        // Detection's own `which` shell-outs, answered "not found" so that
        // detection is driven by the executable checker below.
        let runner = FakeWhichCommandRunner(paths: [:])
        let prompt = FakeAgentSelectionPrompt(result: nil)

        // [specs/43 Task 4] Retention writes the configuration itself now,
        // so this reads the real file at a storage root pointed into a temp
        // directory, instead of the temp file the old `rpc` call read.
        let workerHome = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mac-coding-agent-setup-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: workerHome) }

        let setup = MacCodingAgentSetup(
            executableChecker: FakeExecutableChecker(executablePaths: [codexPath]),
            commandRunner: runner,
            selectionPrompt: prompt
        )

        let retention = MacPairingRetention(
            controlPlaneURL: URL(string: "http://localhost:4000")!,
            runtimeRestarter: FakeWorkerRuntimeRestarter(),
            agentResolver: setup,
            workerHome: workerHome
        )

        XCTAssertTrue(retention.retain(credential: "worker-1.super-secret-credential", worker: worker))
        XCTAssertEqual(prompt.callCount, 0, "one detected agent needs no prompt")

        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: WorkerPaths.workerConfigurationPath(homeOverride: workerHome))
        )
        let storedConfig = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(storedConfig["agent_adapter"] as? String, "codex")
        XCTAssertEqual(storedConfig["agent_executable"] as? String, codexPath)

        // Setting up this Mac's coding agent never asks for a repository
        // folder, so nothing project-scoped reaches disk: absent keys, not
        // empty strings and not nulls.
        XCTAssertFalse(storedConfig.keys.contains("project_id"))
        XCTAssertFalse(storedConfig.keys.contains("workspace_root"))
    }
}
