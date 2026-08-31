import XCTest
@testable import SDDOrchestratorWorkerCore

/// [specs/40 Task 4] `selection_answer.json` is the one place in the product a
/// repository path is written, so these cases check the bytes the release
/// decodes and the permissions the file is created with, not just that a write
/// happened.
final class SelectionAnswerWriterTests: XCTestCase {
    private var temporaryRoot = ""
    private var workerHome = ""

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionAnswerWriterTests-\(UUID().uuidString)", isDirectory: true)
            .path
        workerHome = (temporaryRoot as NSString).appendingPathComponent(".sdd_orchestrator/worker")

        try FileManager.default.createDirectory(atPath: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: temporaryRoot)
        try super.tearDownWithError()
    }

    /// Named here rather than asked of the type under test, because the
    /// release picks this location and the two sides must be pinned to one
    /// path.
    private var answerFilePath: String {
        (workerHome as NSString).appendingPathComponent("selection_answer.json")
    }

    private func answer() throws -> [String: Any] {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: answerFilePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func permissions(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    // MARK: - The file is written where the release reads it

    func test_selectionAnswerPath_isBesideTheWorkerConfiguration() {
        XCTAssertEqual(WorkerPaths.selectionAnswerPath(homeOverride: workerHome), answerFilePath)
        XCTAssertTrue(
            WorkerPaths.selectionAnswerPath()
                .hasSuffix("/.sdd_orchestrator/worker/selection_answer.json")
        )
    }

    // MARK: - The two shapes the release decodes

    func test_write_holdsTheRequestIDAndThePath() throws {
        XCTAssertTrue(
            SelectionAnswerWriter.write(
                requestID: "r-1",
                path: "/Users/someone/Code/orchestrator",
                homeOverride: workerHome
            )
        )

        let written = try answer()

        XCTAssertEqual(written["request_id"] as? String, "r-1")
        XCTAssertEqual(written["path"] as? String, "/Users/someone/Code/orchestrator")
        XCTAssertNil(written["cancelled"])
        XCTAssertEqual(Set(written.keys), ["request_id", "path"])
    }

    func test_writeCancellation_holdsCancelledAndNoPath() throws {
        XCTAssertTrue(SelectionAnswerWriter.writeCancellation(requestID: "r-2", homeOverride: workerHome))

        let written = try answer()

        XCTAssertEqual(written["request_id"] as? String, "r-2")
        XCTAssertEqual(written["cancelled"] as? Bool, true)
        XCTAssertNil(written["path"])
        XCTAssertEqual(Set(written.keys), ["request_id", "cancelled"])
    }

    // MARK: - Owner-only, from the instant the file exists

    func test_write_createsTheFileOwnerOnly() throws {
        XCTAssertTrue(
            SelectionAnswerWriter.write(requestID: "r-3", path: "/tmp/repo", homeOverride: workerHome)
        )

        XCTAssertEqual(try permissions(of: answerFilePath), 0o600)
    }

    func test_writeCancellation_createsTheFileOwnerOnly() throws {
        XCTAssertTrue(SelectionAnswerWriter.writeCancellation(requestID: "r-4", homeOverride: workerHome))

        XCTAssertEqual(try permissions(of: answerFilePath), 0o600)
    }

    func test_write_keepsTheStorageRootOwnerOnly() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workerHome)

        XCTAssertTrue(
            SelectionAnswerWriter.write(requestID: "r-5", path: "/tmp/repo", homeOverride: workerHome)
        )

        XCTAssertEqual(try permissions(of: workerHome), 0o700)
    }

    func test_write_createsTheStorageRootWhenItIsNotThereYet() throws {
        try FileManager.default.removeItem(atPath: temporaryRoot)

        XCTAssertTrue(
            SelectionAnswerWriter.write(requestID: "r-6", path: "/tmp/repo", homeOverride: workerHome)
        )

        XCTAssertEqual(try answer()["request_id"] as? String, "r-6")
        XCTAssertEqual(try permissions(of: workerHome), 0o700)
    }

    // MARK: - One answer, and nothing left beside it

    func test_write_replacesAnAnswerLeftByAnEarlierRequest() throws {
        XCTAssertTrue(SelectionAnswerWriter.writeCancellation(requestID: "r-7", homeOverride: workerHome))
        XCTAssertTrue(
            SelectionAnswerWriter.write(requestID: "r-8", path: "/tmp/newest", homeOverride: workerHome)
        )

        let written = try answer()

        XCTAssertEqual(written["request_id"] as? String, "r-8")
        XCTAssertEqual(written["path"] as? String, "/tmp/newest")
        XCTAssertNil(written["cancelled"])
    }

    func test_write_leavesNoTemporaryNeighbourBehind() throws {
        XCTAssertTrue(
            SelectionAnswerWriter.write(requestID: "r-9", path: "/tmp/repo", homeOverride: workerHome)
        )

        let contents = try FileManager.default.contentsOfDirectory(atPath: workerHome)

        XCTAssertEqual(contents, ["selection_answer.json"])
    }
}
