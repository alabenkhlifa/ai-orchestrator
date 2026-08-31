import XCTest
@testable import SDDOrchestratorWorkerCore

/// [specs/40 Task 4] The app learns that a person is being asked to pick a
/// folder by reading `pending_selection.json`, the file
/// `SddOrchestrator.Worker.RepositorySelection` publishes while one request is
/// open. These cases write real files into a temp storage root and read them
/// back, because that is exactly what happens on the machine.
///
/// The failure these guard against is a panel opening for a question nobody is
/// waiting on an answer to, so every unreadable input has to answer `nil`.
final class PendingSelectionQuerierTests: XCTestCase {
    private var temporaryRoot = ""
    private var workerHome = ""

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingSelectionQuerierTests-\(UUID().uuidString)", isDirectory: true)
            .path
        workerHome = (temporaryRoot as NSString).appendingPathComponent(".sdd_orchestrator/worker")

        try FileManager.default.createDirectory(atPath: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: temporaryRoot)
        try super.tearDownWithError()
    }

    /// Named here rather than asked of the type under test. The release picks
    /// this location, so the test has to state it independently for the two
    /// sides to be pinned to one path.
    private var pendingFilePath: String {
        (workerHome as NSString).appendingPathComponent("pending_selection.json")
    }

    private func write(_ contents: String) throws {
        try contents.write(toFile: pendingFilePath, atomically: true, encoding: .utf8)
    }

    private func query() -> PendingSelection? {
        PendingSelectionQuerier.query(workerHomeOverride: workerHome)
    }

    // MARK: - The file is read from where the release writes it

    func test_pendingSelectionPath_isBesideTheWorkerConfiguration() {
        XCTAssertEqual(WorkerPaths.pendingSelectionPath(homeOverride: workerHome), pendingFilePath)
        XCTAssertEqual(
            (WorkerPaths.pendingSelectionPath(homeOverride: workerHome) as NSString).deletingLastPathComponent,
            (WorkerPaths.workerConfigurationPath(homeOverride: workerHome) as NSString).deletingLastPathComponent
        )
        XCTAssertTrue(
            WorkerPaths.pendingSelectionPath()
                .hasSuffix("/.sdd_orchestrator/worker/pending_selection.json")
        )
    }

    // MARK: - An open request reads back as itself

    /// Both sides have to agree on one file, so this case does not describe
    /// the shape in the test's own words. These are the bytes
    /// `RepositorySelection.encode_pending/1` produces: `Jason.encode!(…,
    /// pretty: true)`, which sorts the keys and ends without a trailing
    /// newline.
    func test_query_theExactBytesTheReleaseWrites_readBack() throws {
        try write("""
        {
          "expires_at": "2026-08-31T09:12:44.512000Z",
          "request_id": "3f0a9c6e-1b2d-4f77-9a51-8c0e2d4b6a10"
        }
        """)

        let pending = query()

        XCTAssertEqual(pending?.requestID, "3f0a9c6e-1b2d-4f77-9a51-8c0e2d4b6a10")
        XCTAssertNotNil(pending?.expiresAt)
    }

    func test_query_expiryWithoutFractionalSeconds_isRead() throws {
        try write(#"{"request_id": "r-1", "expires_at": "2026-08-31T09:12:44Z"}"#)

        XCTAssertEqual(
            query()?.expiresAt,
            ISO8601DateFormatter().date(from: "2026-08-31T09:12:44Z")
        )
    }

    // MARK: - The request id is what matters, so a bad expiry is not fatal

    func test_query_nullExpiry_stillReportsTheRequest() throws {
        try write("""
        {
          "expires_at": null,
          "request_id": "r-2"
        }
        """)

        let pending = query()

        XCTAssertEqual(pending?.requestID, "r-2")
        XCTAssertNil(pending?.expiresAt)
    }

    func test_query_unreadableExpiry_stillReportsTheRequest() throws {
        try write(#"{"request_id": "r-3", "expires_at": "some time next week"}"#)

        let pending = query()

        XCTAssertEqual(pending?.requestID, "r-3")
        XCTAssertNil(pending?.expiresAt)
    }

    func test_query_noExpiryKeyAtAll_stillReportsTheRequest() throws {
        try write(#"{"request_id": "r-4"}"#)

        XCTAssertEqual(query()?.requestID, "r-4")
    }

    // MARK: - Every way of not knowing answers nil

    func test_query_noFile_isNil() throws {
        XCTAssertNil(query())
    }

    func test_query_missingStorageRoot_isNil() throws {
        try FileManager.default.removeItem(atPath: workerHome)

        XCTAssertNil(query())
    }

    func test_query_bytesThatAreNotJSON_isNil() throws {
        try write("{\"request_id\": \"r-5\"")

        XCTAssertNil(query())

        try write("")

        XCTAssertNil(query())

        try write("not json at all")

        XCTAssertNil(query())

        try write(#"["r-5"]"#)

        XCTAssertNil(query())
    }

    func test_query_noRequestIDKey_isNil() throws {
        try write("""
        {
          "expires_at": "2026-08-31T09:12:44.512000Z"
        }
        """)

        XCTAssertNil(query())
    }

    func test_query_requestIDThatIsNotAString_isNil() throws {
        try write(#"{"request_id": 7}"#)

        XCTAssertNil(query())
    }

    func test_query_emptyRequestID_isNil() throws {
        try write(#"{"request_id": ""}"#)

        XCTAssertNil(query())
    }

    func test_query_unreadableFile_isNil() throws {
        // Root reads anything, so this file could not be made unreadable
        // there and the case would fail for a reason that is not the code's.
        try XCTSkipIf(getuid() == 0, "runs as root, which can read a 0o000 file")

        try write(#"{"request_id": "r-6"}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: pendingFilePath)

        XCTAssertNil(query())
    }
}
