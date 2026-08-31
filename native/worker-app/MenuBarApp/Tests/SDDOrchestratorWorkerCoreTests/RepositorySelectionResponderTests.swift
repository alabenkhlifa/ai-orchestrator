import XCTest
@testable import SDDOrchestratorWorkerCore

/// [specs/40 Task 4] The app's half of the folder-picker exchange, driven the
/// way the two-second poll drives it: a real pending file in a temp storage
/// root, a fake picker in place of the panel, and the real answer file read
/// back afterwards.
///
/// The case that carries the most weight here is the one that opens no second
/// panel. The poll fires every two seconds and a person takes tens of seconds
/// to choose a folder, so a responder that does not remember what it has
/// already asked would stack panels on the screen.
final class RepositorySelectionResponderTests: XCTestCase {
    private var temporaryRoot = ""
    private var workerHome = ""

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositorySelectionResponderTests-\(UUID().uuidString)", isDirectory: true)
            .path
        workerHome = (temporaryRoot as NSString).appendingPathComponent(".sdd_orchestrator/worker")

        try FileManager.default.createDirectory(atPath: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: temporaryRoot)
        try super.tearDownWithError()
    }

    // MARK: - The two files, named here so both sides stay pinned to one path

    private var pendingFilePath: String {
        (workerHome as NSString).appendingPathComponent("pending_selection.json")
    }

    private var answerFilePath: String {
        (workerHome as NSString).appendingPathComponent("selection_answer.json")
    }

    private func publishPendingRequest(_ requestID: String) throws {
        try """
        {
          "expires_at": "2026-08-31T09:12:44.512000Z",
          "request_id": "\(requestID)"
        }
        """.write(toFile: pendingFilePath, atomically: true, encoding: .utf8)
    }

    private func removePendingRequest() throws {
        try FileManager.default.removeItem(atPath: pendingFilePath)
    }

    private func answer() throws -> [String: Any] {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: answerFilePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var answerExists: Bool {
        FileManager.default.fileExists(atPath: answerFilePath)
    }

    /// One poll tick, waited on. The responder does its work on its own queue,
    /// so the cycle's completion is what the test waits for rather than a
    /// duration it guessed at.
    private func respond(_ responder: RepositorySelectionResponder) {
        let finished = expectation(description: "one repository selection cycle")

        responder.respondToPendingSelection(homeOverride: workerHome) { finished.fulfill() }

        wait(for: [finished], timeout: 5)
    }

    // MARK: - A pending file produces one panel

    func test_respond_pendingRequest_presentsThePanelExactlyOnce() throws {
        try publishPendingRequest("r-1")
        let picker = FakeWorkspaceFolderPicker(result: "/Users/someone/Code/orchestrator")

        respond(RepositorySelectionResponder(picker: picker))

        XCTAssertEqual(picker.callCount, 1)
    }

    // MARK: - A chosen folder becomes one answer

    func test_respond_chosenFolder_writesThatPathForThatRequest() throws {
        try publishPendingRequest("r-2")
        let picker = FakeWorkspaceFolderPicker(result: "/Users/someone/Code/orchestrator")

        respond(RepositorySelectionResponder(picker: picker))

        let written = try answer()

        XCTAssertEqual(written["request_id"] as? String, "r-2")
        XCTAssertEqual(written["path"] as? String, "/Users/someone/Code/orchestrator")
        XCTAssertNil(written["cancelled"])
    }

    // MARK: - A dismissed panel becomes one cancellation, with no path

    func test_respond_dismissedPanel_writesACancellationAndNoPath() throws {
        try publishPendingRequest("r-3")
        let picker = FakeWorkspaceFolderPicker(result: nil)

        respond(RepositorySelectionResponder(picker: picker))

        let written = try answer()

        XCTAssertEqual(picker.callCount, 1)
        XCTAssertEqual(written["request_id"] as? String, "r-3")
        XCTAssertEqual(written["cancelled"] as? Bool, true)
        XCTAssertNil(written["path"])
        XCTAssertEqual(Set(written.keys), ["request_id", "cancelled"])
    }

    // MARK: - No pending file means no panel

    func test_respond_noPendingFile_presentsNothingAndWritesNothing() {
        let picker = FakeWorkspaceFolderPicker(result: "/Users/someone/Code/orchestrator")

        respond(RepositorySelectionResponder(picker: picker))

        XCTAssertEqual(picker.callCount, 0)
        XCTAssertFalse(answerExists)
    }

    func test_respond_afterThePendingFileDisappears_presentsNothingFurther() throws {
        try publishPendingRequest("r-4")
        let picker = FakeWorkspaceFolderPicker(result: "/Users/someone/Code/orchestrator")
        let responder = RepositorySelectionResponder(picker: picker)

        respond(responder)
        try removePendingRequest()
        try FileManager.default.removeItem(atPath: answerFilePath)

        respond(responder)
        respond(responder)

        XCTAssertEqual(picker.callCount, 1)
        XCTAssertFalse(answerExists)
    }

    // MARK: - Never a second panel while one is open

    func test_respond_twiceForTheSameRequest_presentsOnlyOnePanel() throws {
        try publishPendingRequest("r-5")
        let picker = FakeWorkspaceFolderPicker(result: "/Users/someone/Code/orchestrator")
        let responder = RepositorySelectionResponder(picker: picker)

        respond(responder)
        respond(responder)
        respond(responder)

        XCTAssertEqual(picker.callCount, 1)
        XCTAssertEqual(try answer()["request_id"] as? String, "r-5")
    }

    /// The panel is what the poll interval is racing, so this is the same rule
    /// under the timing that actually produces it: ticks that arrive while the
    /// panel is still up must not open another one. The picker blocks until
    /// the test lets it go, exactly as a real panel blocks until a person
    /// answers it.
    func test_respond_whileThePanelIsStillOpen_presentsNoSecondPanel() throws {
        try publishPendingRequest("r-6")

        // Over-fulfilment is allowed, and the semaphore is signalled once per
        // tick that could reach the picker, so a responder that wrongly opens
        // a second panel fails on the call count below rather than tripping
        // XCTest or hanging on the semaphore.
        let panelIsUp = expectation(description: "the panel is on screen")
        panelIsUp.assertForOverFulfill = false
        let letThePanelClose = DispatchSemaphore(value: 0)
        let picker = ScriptedWorkspaceFolderPicker {
            panelIsUp.fulfill()
            letThePanelClose.wait()
            return "/Users/someone/Code/orchestrator"
        }
        let responder = RepositorySelectionResponder(picker: picker)

        let firstCycle = expectation(description: "the cycle holding the panel finished")
        responder.respondToPendingSelection(homeOverride: workerHome) { firstCycle.fulfill() }
        wait(for: [panelIsUp], timeout: 5)

        // Two poll ticks land while the person is still looking at the panel.
        let laterTicks = expectation(description: "the ticks that arrived during the panel finished")
        laterTicks.expectedFulfillmentCount = 2
        responder.respondToPendingSelection(homeOverride: workerHome) { laterTicks.fulfill() }
        responder.respondToPendingSelection(homeOverride: workerHome) { laterTicks.fulfill() }

        letThePanelClose.signal()
        letThePanelClose.signal()
        letThePanelClose.signal()
        wait(for: [firstCycle, laterTicks], timeout: 5)

        XCTAssertEqual(picker.callCount, 1)
        XCTAssertEqual(try answer()["path"] as? String, "/Users/someone/Code/orchestrator")
    }

    // MARK: - A genuinely new request is asked again

    func test_respond_newRequestID_presentsASecondPanelAndAnswersTheNewOne() throws {
        try publishPendingRequest("r-7")
        let picker = FakeWorkspaceFolderPicker(result: "/Users/someone/Code/orchestrator")
        let responder = RepositorySelectionResponder(picker: picker)

        respond(responder)
        try publishPendingRequest("r-8")
        respond(responder)

        XCTAssertEqual(picker.callCount, 2)
        XCTAssertEqual(try answer()["request_id"] as? String, "r-8")
    }

    // MARK: - A request that ended while the panel was open

    /// `WorkspaceFolderPicking` is synchronous and an `NSOpenPanel` cannot be
    /// dismissed from this target, so a request cancelled while the panel is
    /// up stays on screen until the person answers it. What this pins is what
    /// happens then: nothing is written at all.
    ///
    /// This is a deliberate contract change, not a weakened case. It first
    /// asserted that the answer was written anyway and left to the release to
    /// refuse, which the release does. But `selection_answer.json` is the only
    /// place a path is ever written, `AC-11` requires that no path is left on
    /// disk, and the release deletes that file only while it is polling for an
    /// answer. With no request open behind it, an answer written for a dead
    /// request would hold a path on disk until some later request or the next
    /// release start. Writing it bought nothing and cost that, so it is not
    /// written.
    func test_respond_pendingFileRemovedWhileThePanelIsOpen_writesNoAnswerAtAll() throws {
        try publishPendingRequest("r-9")

        // The release removes the pending file the moment the request ends,
        // which here is while the panel is up.
        let pendingFile = pendingFilePath
        let picker = ScriptedWorkspaceFolderPicker {
            try? FileManager.default.removeItem(atPath: pendingFile)
            return "/Users/someone/Code/orchestrator"
        }
        let responder = RepositorySelectionResponder(picker: picker)

        respond(responder)
        respond(responder)

        XCTAssertEqual(picker.callCount, 1)
        XCTAssertFalse(answerExists)
    }

    /// The same rule on the other branch. A dismissed panel for a request that
    /// has ended writes no cancellation either, so one rule covers both
    /// answers rather than two that could drift apart.
    func test_respond_pendingRequestReplacedWhileThePanelIsOpen_writesNoCancellation() throws {
        try publishPendingRequest("r-10")

        // The control plane opened a second request, so the release replaced
        // the one this panel belongs to.
        let pendingFile = pendingFilePath
        let picker = ScriptedWorkspaceFolderPicker {
            try? """
            {
              "expires_at": null,
              "request_id": "r-11"
            }
            """.write(toFile: pendingFile, atomically: true, encoding: .utf8)

            return nil
        }

        respond(RepositorySelectionResponder(picker: picker))

        XCTAssertEqual(picker.callCount, 1)
        XCTAssertFalse(answerExists)
    }
}

/// A `WorkspaceFolderPicking` fake whose body the case decides, for the two
/// cases that need something to happen while the panel is up. The shared
/// `FakeWorkspaceFolderPicker` answers a canned result and cannot express
/// that.
private final class ScriptedWorkspaceFolderPicker: WorkspaceFolderPicking {
    private let body: () -> String?
    private let lock = NSLock()
    private var calls = 0

    init(body: @escaping () -> String?) {
        self.body = body
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func pickWorkspaceFolder() -> String? {
        lock.lock()
        calls += 1
        lock.unlock()

        return body()
    }
}
