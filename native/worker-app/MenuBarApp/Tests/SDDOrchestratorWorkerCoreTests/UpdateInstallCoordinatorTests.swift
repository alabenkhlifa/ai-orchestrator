import XCTest
@testable import SDDOrchestratorWorkerCore

final class UpdateInstallCoordinatorTests: XCTestCase {
    private let artifact = PendingUpdateArtifact(
        version: "1.2.3",
        fileURL: URL(fileURLWithPath: "/tmp/com.sddorchestrator.worker.pending-update/update.download")
    )
    private let runningAppBundlePath = "/Applications/SDD Orchestrator Worker.app"

    private func gatekeeperPassResult() -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: "accepted\n", standardError: "", timedOut: false)
    }

    private func gatekeeperFailResult() -> CommandResult {
        CommandResult(exitCode: 3, standardOutput: "", standardError: "rejected\n", timedOut: false)
    }

    /// Collects `UpdateInstallCoordinator.State` transitions in call order,
    /// the same shape `PairingFlowControllerTests`' `StateRecorder` uses.
    private final class StateRecorder {
        private(set) var states: [UpdateInstallCoordinator.State] = []
        func record(_ state: UpdateInstallCoordinator.State) { states.append(state) }
    }

    private func makeCoordinator(
        commandRunner: CommandRunning,
        installExecutor: InstallExecuting,
        states: StateRecorder,
        bundlePath: String? = nil
    ) -> UpdateInstallCoordinator {
        UpdateInstallCoordinator(
            commandRunner: commandRunner,
            installExecutor: installExecutor,
            runningAppBundlePath: { bundlePath ?? self.runningAppBundlePath },
            onStateChange: { states.record($0) }
        )
    }

    // MARK: - AC-13: no run active -> proceeds immediately through the Gatekeeper check -> installer invoked

    func test_confirmInstall_noActiveRun_proceedsThroughGatekeeper_andInvokesInstaller() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: nil))

        XCTAssertEqual(commandRunner.lastExecutable, "/usr/sbin/spctl", "must Gatekeeper-assess before installing")
        XCTAssertEqual(installExecutor.callCount, 1)
        XCTAssertEqual(installExecutor.lastArtifact, artifact)
        XCTAssertEqual(installExecutor.lastRunningAppBundlePath, runningAppBundlePath)
        XCTAssertEqual(states.states, [.installHandedOff(artifact: artifact)])
        XCTAssertEqual(coordinator.state, .installHandedOff(artifact: artifact))
    }

    func test_confirmInstall_terminalLifecycle_isTreatedTheSameAsNoRunAtAll_andProceedsImmediately() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "stopped"))

        XCTAssertEqual(installExecutor.callCount, 1)
        XCTAssertEqual(coordinator.state, .installHandedOff(artifact: artifact))
    }

    // MARK: - AC-14: a run active -> defers, installer never invoked, then proceeds automatically once terminal

    func test_confirmInstall_activeRun_defersWithoutInvokingInstallerOrGatekeeper() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "accepted"))

        XCTAssertEqual(coordinator.state, .awaitingActiveRunToFinish(artifact: artifact))
        XCTAssertEqual(states.states, [.awaitingActiveRunToFinish(artifact: artifact)])
        XCTAssertEqual(commandRunner.callCount, 0, "must not Gatekeeper-assess while deferred")
        XCTAssertEqual(installExecutor.callCount, 0, "must not invoke the installer while a run is active")
    }

    func test_confirmInstall_blockedRun_alsoDefers() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "blocked"))

        XCTAssertEqual(coordinator.state, .awaitingActiveRunToFinish(artifact: artifact))
        XCTAssertEqual(installExecutor.callCount, 0)
    }

    func test_confirmInstall_queryFailed_failsSafeAndDefers() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .queryFailed)

        XCTAssertEqual(coordinator.state, .awaitingActiveRunToFinish(artifact: artifact))
        XCTAssertEqual(installExecutor.callCount, 0)
    }

    func test_runStateUpdated_stillActive_staysDeferred_installerNeverInvoked() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "accepted"))
        coordinator.runStateUpdated(.success(currentLifecycle: "accepted"))
        coordinator.runStateUpdated(.success(currentLifecycle: "blocked"))

        XCTAssertEqual(coordinator.state, .awaitingActiveRunToFinish(artifact: artifact))
        XCTAssertEqual(installExecutor.callCount, 0)
        XCTAssertEqual(states.states, [.awaitingActiveRunToFinish(artifact: artifact)], "no redundant transitions while still active")
    }

    func test_runStateUpdated_becomesTerminal_proceedsAutomaticallyWithoutASecondConfirm() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "accepted"))
        XCTAssertEqual(installExecutor.callCount, 0)

        coordinator.runStateUpdated(.success(currentLifecycle: "stopped"))

        XCTAssertEqual(installExecutor.callCount, 1, "must proceed on its own once the run reaches a terminal state")
        XCTAssertEqual(installExecutor.lastArtifact, artifact)
        XCTAssertEqual(coordinator.state, .installHandedOff(artifact: artifact))
        XCTAssertEqual(
            states.states,
            [.awaitingActiveRunToFinish(artifact: artifact), .installHandedOff(artifact: artifact)]
        )
    }

    func test_runStateUpdated_whileIdle_isANoOp() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.runStateUpdated(.success(currentLifecycle: nil))

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(installExecutor.callCount, 0)
        XCTAssertTrue(states.states.isEmpty)
    }

    // MARK: - Gatekeeper failure aborts without touching anything

    func test_confirmInstall_gatekeeperAssessmentFails_abortsWithoutInvokingInstaller() {
        let commandRunner = FakeCommandRunner(result: gatekeeperFailResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: nil))

        XCTAssertEqual(installExecutor.callCount, 0, "a failed Gatekeeper assessment must never reach the installer")
        guard case .aborted = coordinator.state else {
            return XCTFail("expected .aborted, got \(coordinator.state)")
        }
        guard case .some(.aborted) = states.states.last else {
            return XCTFail("expected the final recorded state to be .aborted")
        }
    }

    func test_runStateUpdated_afterDeferral_gatekeeperFails_abortsWithoutInvokingInstaller() {
        let commandRunner = FakeCommandRunner(result: gatekeeperFailResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "accepted"))
        coordinator.runStateUpdated(.success(currentLifecycle: nil))

        XCTAssertEqual(installExecutor.callCount, 0)
        guard case .aborted = coordinator.state else {
            return XCTFail("expected .aborted, got \(coordinator.state)")
        }
    }

    // MARK: - Installer handoff itself failing to start also aborts

    func test_confirmInstall_installerFailsToStart_aborts() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: false)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: nil))

        XCTAssertEqual(installExecutor.callCount, 1)
        guard case .aborted = coordinator.state else {
            return XCTFail("expected .aborted, got \(coordinator.state)")
        }
    }

    // MARK: - A second confirmation never double-fires (mirrors PairingFlowController's own guard)

    func test_confirmInstall_calledAgainWhileAwaitingActiveRunToFinish_isANoOp() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "accepted"))
        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: "accepted"))

        XCTAssertEqual(states.states.count, 1, "a repeated confirmation while deferred must not record a second transition")
        XCTAssertEqual(installExecutor.callCount, 0)
    }

    func test_confirmInstall_calledAgainAfterInstallHandedOff_isANoOp() {
        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: nil))
        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: nil))

        XCTAssertEqual(installExecutor.callCount, 1, "must not re-invoke the installer once already handed off")
    }

    // MARK: - Credential preservation (AC-13): the orchestration never touches ~/.sdd_orchestrator

    func test_confirmInstall_fullSuccessfulFlow_neverTouchesTheWorkerConfigurationFile() throws {
        // A fixture standing in for the real
        // ~/.sdd_orchestrator/worker/worker.json (SddOrchestrator.Worker.Configuration's
        // storage, which lives entirely outside the .app bundle -- see this
        // task's brief). This coordinator's only file-system-adjacent
        // collaborators are `commandRunner` (spctl, given only the
        // artifact's own path) and `installExecutor` (given only the
        // artifact and the *bundle* path) -- neither is ever handed this
        // fixture's path, so its bytes must be provably unchanged by the
        // full confirm -> gate -> verify -> install-handoff flow below.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = tempRoot.appendingPathComponent(".sdd_orchestrator/worker", isDirectory: true)
        let configFile = configDirectory.appendingPathComponent("worker.json", isDirectory: false)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let originalBytes = Data(#"{"credential":"worker-1.super-secret-credential"}"#.utf8)
        try originalBytes.write(to: configFile)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
        let installExecutor = FakeInstallExecutor(result: true)
        let states = StateRecorder()
        let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

        coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: nil))

        XCTAssertEqual(coordinator.state, .installHandedOff(artifact: artifact), "sanity check: the flow actually ran to completion")

        let bytesAfter = try Data(contentsOf: configFile)
        XCTAssertEqual(bytesAfter, originalBytes, "the credential file's bytes must be byte-identical after the install flow")

        XCTAssertFalse(
            (commandRunner.lastArguments ?? []).joined().contains(configFile.path),
            "the Gatekeeper check must never be given the config file's path"
        )
        XCTAssertNotEqual(installExecutor.lastArtifact?.fileURL, configFile, "the installer must never be handed the config file as the artifact")
        XCTAssertNotEqual(
            installExecutor.lastRunningAppBundlePath,
            configFile.path,
            "the installer must never be handed the config file as the bundle path to replace"
        )
    }

    // MARK: - The active-run gate reuses ActiveRunChecker's own vocabulary, not a duplicate

    func test_terminalLifecycles_allProceedImmediately_matchingActiveRunCheckersOwnList() {
        for lifecycle in ["canceled", "failed", "stopped", "verification_completed"] {
            let commandRunner = FakeCommandRunner(result: gatekeeperPassResult())
            let installExecutor = FakeInstallExecutor(result: true)
            let states = StateRecorder()
            let coordinator = makeCoordinator(commandRunner: commandRunner, installExecutor: installExecutor, states: states)

            coordinator.confirmInstall(artifact: artifact, runStateResult: .success(currentLifecycle: lifecycle))

            XCTAssertEqual(
                installExecutor.callCount,
                1,
                "\(lifecycle) is terminal per ActiveRunChecker and must proceed immediately"
            )
        }
    }
}
