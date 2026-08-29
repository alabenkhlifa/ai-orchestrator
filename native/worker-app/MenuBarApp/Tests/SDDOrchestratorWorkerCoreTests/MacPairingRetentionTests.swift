import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/39 Task 2 proof for AC-01: "Given the dashboard redeemed this
/// app's pairing code, when the app completes pairing, then it stores the
/// issued credential and worker identity and reports no project, without
/// asking the person for one."
///
/// specs/43 Task 4 proof for its own AC-01: "Given Erlang distribution is
/// unavailable, when a person pairs the app from the menu bar, then the
/// configuration is stored, the worker runtime starts, and the worker
/// connects." Retention now writes `worker.json` itself and restarts the
/// embedded release, so these tests read the real file at the real storage
/// root (pointed at a temp directory) and assert the restart seam was
/// used. Nothing here shells out, because the path no longer runs a command
/// at all.
///
/// **On "without asking the person for one":** there is deliberately no
/// test that a folder picker went uncalled, because `MacPairingRetention`
/// has no folder picker and no project parameter to begin with. `retain`
/// takes a credential and a worker identity and nothing else, and the
/// initializer takes no `WorkspaceFolderPicking`. The type's own shape is
/// the guarantee — a run-time check would only prove that a seam nobody
/// wired stayed unused. What is checked below instead is the observable
/// half of the same promise: what reaches disk carries no `project_id` and
/// no `workspace_root`.
///
/// **On "the credential reaches no command argument":** the same reasoning
/// now covers the credential too. This type holds no `CommandRunning` and
/// its one remaining seam, `WorkerRuntimeRestarting`, takes no arguments,
/// so there is no argument list for a secret to leak into. What is checked
/// below is that the credential reaches the configuration file and that
/// nothing else is left behind on disk. `PostPairingSetupCoordinatorImplTests`
/// still asserts the argument list directly, because that path does keep a
/// command runner for agent detection.
final class MacPairingRetentionTests: XCTestCase {
    private let controlPlaneURL = URL(string: "http://localhost:4000")!

    private var workerHome = ""
    private var temporaryRoot = ""

    private let worker = WorkerIdentity(
        id: "worker-1",
        deviceWorkspaceID: "ws-1",
        osFamily: "macos",
        osMajor: "15",
        protocolVersion: "1",
        appVersion: "1.0.0",
        state: "active"
    )

    private let agent = DetectedAgent(adapter: "claude_code", executablePath: "/usr/local/bin/claude")

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mac-pairing-retention-tests-\(UUID().uuidString)")
        // The storage root itself is deliberately *not* created here: the
        // real one does not exist before the first pairing, so creating it
        // is part of what is under test.
        workerHome = (temporaryRoot as NSString).appendingPathComponent(".sdd_orchestrator/worker")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: temporaryRoot)
        try super.tearDownWithError()
    }

    private var configurationPath: String {
        WorkerPaths.workerConfigurationPath(homeOverride: workerHome)
    }

    private func makeRetention(
        restarter: WorkerRuntimeRestarting,
        agentResolver: MacCodingAgentResolving,
        workerHome: String? = nil
    ) -> MacPairingRetention {
        MacPairingRetention(
            controlPlaneURL: controlPlaneURL,
            runtimeRestarter: restarter,
            agentResolver: agentResolver,
            workerHome: workerHome ?? self.workerHome
        )
    }

    private func storedConfiguration(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: configurationPath),
            "expected a worker configuration at the storage root",
            file: file,
            line: line
        )

        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the release decodes this file with Jason.decode!/1, so it must be a JSON object",
            file: file,
            line: line
        )
    }

    private func permissions(ofItemAtPath path: String) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - AC-01: a completed redemption stores the credential and worker identity, with no project

    func test_retain_resolvableAgent_storesTheCredentialAndTheWorkerIdentityWithNoProject() throws {
        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        let stored = retention.retain(credential: "worker-1.super-secret-credential", worker: worker)

        XCTAssertTrue(stored)
        XCTAssertEqual(restarter.restartCount, 1, "the runtime starts by restarting the release, not by calling into it")

        let configuration = try storedConfiguration()

        XCTAssertEqual(configuration["worker_credential"] as? String, "worker-1.super-secret-credential")
        XCTAssertEqual(configuration["worker_id"] as? String, "worker-1")
        XCTAssertEqual(configuration["device_workspace_id"] as? String, "ws-1")
        XCTAssertEqual(configuration["control_plane_address"] as? String, "http://localhost:4000")
        XCTAssertEqual(configuration["agent_adapter"] as? String, "claude_code")
        XCTAssertEqual(configuration["agent_executable"] as? String, "/usr/local/bin/claude")

        // Reports no project: absent keys, not empty strings and not nulls.
        XCTAssertFalse(configuration.keys.contains("project_id"))
        XCTAssertFalse(configuration.keys.contains("workspace_root"))

        // Exactly the six keys `Configuration`'s `@required_keys` lists, so
        // the release loads this file without any renaming or defaulting.
        XCTAssertEqual(configuration.count, 6)
    }

    func test_retain_writesTheConfigurationAtTheReleaseSOwnStorageRoot() {
        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        retention.retain(credential: "worker-1.secret", worker: worker)

        // The one durable store, resolved the way the release resolves it.
        XCTAssertEqual((configurationPath as NSString).lastPathComponent, "worker.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurationPath))
        XCTAssertTrue(
            WorkerPaths.workerConfigurationPath().hasSuffix("/.sdd_orchestrator/worker/worker.json"),
            "without an override the app writes where the release reads: ~/.sdd_orchestrator/worker/worker.json"
        )
    }

    // MARK: - The configuration is owner-only, like the release writes it

    func test_retain_writesAnOwnerOnlyFileInAnOwnerOnlyDirectory() throws {
        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        retention.retain(credential: "worker-1.secret", worker: worker)

        XCTAssertEqual(try permissions(ofItemAtPath: configurationPath), 0o600)
        XCTAssertEqual(try permissions(ofItemAtPath: workerHome), 0o700)
    }

    func test_retain_reappliesOwnerOnlyPermissionsToAnAlreadyLooseStorageRoot() throws {
        try FileManager.default.createDirectory(
            atPath: workerHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        retention.retain(credential: "worker-1.secret", worker: worker)

        // `Configuration.store/2` re-applies both permissions on every
        // write, so a storage root left loose by anything else is closed
        // again rather than trusted.
        XCTAssertEqual(try permissions(ofItemAtPath: workerHome), 0o700)
        XCTAssertEqual(try permissions(ofItemAtPath: configurationPath), 0o600)
    }

    // MARK: - The credential is in the file and nowhere else on disk

    func test_retain_leavesTheCredentialOnlyInTheConfigurationFile() throws {
        let credential = "worker-1.super-secret-credential"
        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        retention.retain(credential: credential, worker: worker)

        let contents = try XCTUnwrap(String(data: XCTUnwrap(FileManager.default.contents(atPath: configurationPath)), encoding: .utf8))
        XCTAssertTrue(contents.contains(credential))

        // No temporary neighbour outlives the write: an atomic write
        // renames its temp file into place, and this path writes nothing
        // else anywhere.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workerHome), ["worker.json"])
    }

    // MARK: - The release is restarted, and only after the configuration is on disk

    func test_retain_restartsTheReleaseOnlyOnceTheConfigurationIsReadable() throws {
        let restarter = FakeWorkerRuntimeRestarter()
        var configurationAtRestart: [String: Any]?

        // The rebooting release reads the file at exactly this moment, so
        // this is where a complete configuration has to already be there.
        restarter.onRestart = { [weak self] in
            guard
                let self,
                let data = FileManager.default.contents(atPath: self.configurationPath)
            else { return XCTFail("expected a readable configuration when the release restarts") }

            configurationAtRestart = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        XCTAssertTrue(retention.retain(credential: "worker-1.secret", worker: worker))
        XCTAssertEqual(restarter.restartCount, 1)

        let configuration = try XCTUnwrap(configurationAtRestart)
        XCTAssertEqual(configuration["worker_credential"] as? String, "worker-1.secret")
        XCTAssertEqual(configuration.count, 6)
    }

    func test_retain_reportsFalse_whenTheReleaseDoesNotComeBackUp() throws {
        let restarter = FakeWorkerRuntimeRestarter(result: false)
        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        // The configuration was stored, so the next launch starts against
        // it — but no worker is running yet, so the menu must keep saying
        // the setup is unfinished rather than claim a paired, live worker.
        XCTAssertFalse(retention.retain(credential: "worker-1.secret", worker: worker))
        XCTAssertEqual(restarter.restartCount, 1)
        XCTAssertEqual(try storedConfiguration()["worker_credential"] as? String, "worker-1.secret")
    }

    // MARK: - Re-pairing

    func test_retain_twice_overwritesWithTheNewestCredential() throws {
        // The pairing loop can complete more than once across a launch, and
        // a fresh boot has nothing started, so the second pass is an
        // ordinary overwrite-and-restart rather than a case to special-case.
        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(restarter: restarter, agentResolver: FakeMacCodingAgentResolver(result: agent))

        XCTAssertTrue(retention.retain(credential: "worker-1.first", worker: worker))
        XCTAssertTrue(retention.retain(credential: "worker-1.second", worker: worker))

        XCTAssertEqual(restarter.restartCount, 2)
        XCTAssertEqual(try storedConfiguration()["worker_credential"] as? String, "worker-1.second")
        XCTAssertEqual(try permissions(ofItemAtPath: configurationPath), 0o600)
    }

    // MARK: - Nothing is half-stored

    func test_retain_unresolvedAgent_storesNothingAndRestartsNothing() {
        let restarter = FakeWorkerRuntimeRestarter()
        let resolver = FakeMacCodingAgentResolver(result: nil)
        let retention = makeRetention(restarter: restarter, agentResolver: resolver)

        let stored = retention.retain(credential: "worker-1.secret", worker: worker)

        XCTAssertFalse(stored)
        XCTAssertEqual(resolver.callCount, 1)
        XCTAssertEqual(restarter.restartCount, 0, "an unresolved coding agent must stop before anything is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workerHome), "not even the storage root is created")
    }

    func test_retain_unwritableStorageRoot_storesNothingAndDoesNotRestartTheRelease() throws {
        // A file where the storage root's parent should be: creating the
        // directory fails, so the write fails as a whole.
        let blocked = (temporaryRoot as NSString).appendingPathComponent("blocked")
        try FileManager.default.createDirectory(
            atPath: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: nil
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked, contents: Data("not a directory".utf8)))

        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(
            restarter: restarter,
            agentResolver: FakeMacCodingAgentResolver(result: agent),
            workerHome: (blocked as NSString).appendingPathComponent("worker")
        )

        XCTAssertFalse(retention.retain(credential: "worker-1.secret", worker: worker))
        XCTAssertEqual(
            restarter.restartCount,
            0,
            "a release restarted against a configuration that was never written would come up unpaired"
        )
        XCTAssertEqual(
            try String(contentsOfFile: blocked, encoding: .utf8),
            "not a directory",
            "a failed write leaves nothing behind, not even a partial file"
        )
    }

    // MARK: - The stand-in Task 3 replaces

    func test_unresolvedMacCodingAgent_resolvesNothing_soNothingIsStoredYet() {
        let restarter = FakeWorkerRuntimeRestarter()
        let retention = makeRetention(restarter: restarter, agentResolver: UnresolvedMacCodingAgent())

        XCTAssertNil(UnresolvedMacCodingAgent().resolveMacCodingAgent())
        XCTAssertFalse(retention.retain(credential: "worker-1.secret", worker: worker))
        XCTAssertEqual(restarter.restartCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationPath))
    }
}
