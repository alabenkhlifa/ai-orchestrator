import XCTest
@testable import SDDOrchestratorWorkerCore

final class PendingUpdateArtifactStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingUpdateArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    func test_store_writesDataToFileURL_andReturnsMatchingDescriptor() throws {
        let data = "verified-artifact-bytes".data(using: .utf8)!

        let artifact = try PendingUpdateArtifactStore.store(
            data: data,
            version: "0.2.0",
            temporaryDirectory: tempRoot.path
        )

        XCTAssertEqual(artifact.version, "0.2.0")
        XCTAssertEqual(artifact.fileURL, PendingUpdateArtifactStore.fileURL(temporaryDirectory: tempRoot.path))
        XCTAssertEqual(try Data(contentsOf: artifact.fileURL), data)
    }

    func test_store_createsParentDirectory_whenItDoesNotExistYet() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.path))

        _ = try PendingUpdateArtifactStore.store(
            data: Data("x".utf8),
            version: "0.2.0",
            temporaryDirectory: tempRoot.path
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.path))
    }

    func test_store_overwritesAnyPreviouslyPendingArtifact() throws {
        _ = try PendingUpdateArtifactStore.store(
            data: Data("old".utf8),
            version: "0.1.0",
            temporaryDirectory: tempRoot.path
        )
        let newest = try PendingUpdateArtifactStore.store(
            data: Data("new".utf8),
            version: "0.2.0",
            temporaryDirectory: tempRoot.path
        )

        XCTAssertEqual(try Data(contentsOf: newest.fileURL), Data("new".utf8))
        XCTAssertEqual(newest.version, "0.2.0")
    }

    func test_fileURL_isStableForTheSameTemporaryDirectory() {
        let first = PendingUpdateArtifactStore.fileURL(temporaryDirectory: tempRoot.path)
        let second = PendingUpdateArtifactStore.fileURL(temporaryDirectory: tempRoot.path)

        XCTAssertEqual(first, second)
    }
}
