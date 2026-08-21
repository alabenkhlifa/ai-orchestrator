import XCTest
@testable import SDDOrchestratorWorkerCore

final class AppcastUpdateCheckerTests: XCTestCase {
    private let appcastURL = URL(string: "http://localhost:4000/appcast.json")!
    private let downloadURL = URL(string: "http://localhost:4000/downloads/SDD-Orchestrator-Worker-0.2.0.dmg")!
    private let artifactData = "fake-dmg-bytes-for-testing".data(using: .utf8)!
    // sha256("fake-dmg-bytes-for-testing"), independently computed via
    // `printf '%s' "fake-dmg-bytes-for-testing" | shasum -a 256` — see
    // AppcastArtifactChecksumTests's identical fixture.
    private let artifactSHA256 = "7c6d9e388138afc5003a875a56ca4dd27a5dca8dd6c25bdd0b92aa58673fa8c7"

    /// Collects every `PendingUpdateArtifact` `onUpdateAvailable` was called
    /// with, in order — mirrors `PairingFlowControllerTests.StateRecorder`.
    private final class ArtifactRecorder {
        private(set) var artifacts: [PendingUpdateArtifact] = []
        func record(_ artifact: PendingUpdateArtifact) { artifacts.append(artifact) }
    }

    private func signedNewerEntry() -> AppcastEntry {
        AppcastTestSigning.sign(
            AppcastEntry(
                latestVersion: "0.2.0",
                minimumOS: "14.0",
                downloadURL: downloadURL.absoluteString,
                sha256: artifactSHA256,
                signatureBase64: ""
            )
        )
    }

    private func appcastJSON(for entry: AppcastEntry) -> Data {
        let object: [String: String] = [
            "latest_version": entry.latestVersion,
            "minimum_os": entry.minimumOS,
            "download_url": entry.downloadURL,
            "sha256": entry.sha256,
            "signature": entry.signatureBase64
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeChecker(
        fetcher: FakeAppcastHTTPFetcher,
        currentAppVersion: String = "0.1.0",
        publicKeyBase64: String? = AppcastTestSigning.publicKeyBase64,
        artifactStore: @escaping (Data, String) throws -> PendingUpdateArtifact,
        recorder: ArtifactRecorder
    ) -> AppcastUpdateChecker {
        AppcastUpdateChecker(
            appcastURL: appcastURL,
            currentAppVersion: currentAppVersion,
            publicKeyBase64: publicKeyBase64,
            httpFetcher: fetcher,
            artifactStore: artifactStore,
            onUpdateAvailable: { recorder.record($0) }
        )
    }

    // MARK: - AC-12: valid newer signed appcast + matching artifact

    func test_checkNow_validNewerSignedAppcast_matchingArtifact_reachesUpdateAvailableExactlyOnce_withCorrectVersion() {
        let entry = signedNewerEntry()
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: appcastJSON(for: entry), statusCode: 200)
        fetcher.stub(url: downloadURL, data: artifactData, statusCode: 200)
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            artifactStore: { data, version in
                PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null/\(data.count)"))
            },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertEqual(recorder.artifacts.count, 1)
        XCTAssertEqual(recorder.artifacts.first?.version, "0.2.0")
        XCTAssertEqual(fetcher.requestedURLs, [appcastURL, downloadURL])
    }

    // MARK: - AC-11: invalid signature -> no state change

    func test_checkNow_invalidSignature_noStateChange_andDownloadNeverAttempted() {
        let entry = signedNewerEntry()
        // Tamper with a field after signing, invalidating the signature
        // without touching it directly.
        let tampered = AppcastEntry(
            latestVersion: entry.latestVersion,
            minimumOS: entry.minimumOS,
            downloadURL: "http://localhost:4000/downloads/attacker.dmg",
            sha256: entry.sha256,
            signatureBase64: entry.signatureBase64
        )
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: appcastJSON(for: tampered), statusCode: 200)
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            artifactStore: { data, version in PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null")) },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertTrue(recorder.artifacts.isEmpty)
        XCTAssertEqual(fetcher.requestedURLs, [appcastURL], "an invalid signature must never trigger an artifact download")
    }

    func test_checkNow_missingSignature_noStateChange() {
        let unsigned = """
        {"latest_version": "0.2.0", "minimum_os": "14.0", "download_url": "\(downloadURL.absoluteString)", "sha256": "\(artifactSHA256)"}
        """.data(using: .utf8)!
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: unsigned, statusCode: 200)
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            artifactStore: { data, version in PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null")) },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertTrue(recorder.artifacts.isEmpty)
        XCTAssertEqual(fetcher.requestedURLs, [appcastURL])
    }

    // MARK: - AC-11: not-newer version -> no action, no download attempted at all

    func test_checkNow_notNewerVersion_noStateChange_andDownloadNeverAttempted() {
        let sameVersion = AppcastTestSigning.sign(
            AppcastEntry(
                latestVersion: "0.1.0",
                minimumOS: "14.0",
                downloadURL: downloadURL.absoluteString,
                sha256: artifactSHA256,
                signatureBase64: ""
            )
        )
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: appcastJSON(for: sameVersion), statusCode: 200)
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            currentAppVersion: "0.1.0",
            artifactStore: { data, version in PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null")) },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertTrue(recorder.artifacts.isEmpty)
        XCTAssertEqual(
            fetcher.requestedURLs,
            [appcastURL],
            "a not-newer version must short-circuit before any artifact download is attempted"
        )
    }

    func test_checkNow_olderVersion_noStateChange() {
        let olderVersion = AppcastTestSigning.sign(
            AppcastEntry(
                latestVersion: "0.1.0",
                minimumOS: "14.0",
                downloadURL: downloadURL.absoluteString,
                sha256: artifactSHA256,
                signatureBase64: ""
            )
        )
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: appcastJSON(for: olderVersion), statusCode: 200)
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            currentAppVersion: "0.5.0",
            artifactStore: { data, version in PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null")) },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertTrue(recorder.artifacts.isEmpty)
        XCTAssertEqual(fetcher.requestedURLs, [appcastURL])
    }

    // MARK: - AC-12: checksum mismatch -> discarded, no .updateAvailable

    func test_checkNow_checksumMismatch_discardsDownload_doesNotReachUpdateAvailable() {
        let entry = signedNewerEntry()
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: appcastJSON(for: entry), statusCode: 200)
        // Wrong bytes: won't match entry.sha256.
        fetcher.stub(url: downloadURL, data: "not-the-signed-artifact".data(using: .utf8)!, statusCode: 200)
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            artifactStore: { data, version in PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null")) },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertTrue(recorder.artifacts.isEmpty, "a checksum mismatch must never reach .updateAvailable")
        XCTAssertEqual(fetcher.requestedURLs, [appcastURL, downloadURL], "the download is attempted before the checksum is known")
    }

    func test_checkNow_downloadTransportFailure_doesNotReachUpdateAvailable() {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "connection reset" }
        }

        let entry = signedNewerEntry()
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: appcastJSON(for: entry), statusCode: 200)
        fetcher.stubTransportError(url: downloadURL, error: FakeError())
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            artifactStore: { data, version in PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null")) },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertTrue(recorder.artifacts.isEmpty)
    }

    // MARK: - Fetch-level failures collapse to "no action" too

    func test_checkNow_appcastFetchTransportFailure_doesNotReachUpdateAvailable_andNeverDownloads() {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "host unreachable" }
        }

        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stubTransportError(url: appcastURL, error: FakeError())
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            artifactStore: { data, version in PendingUpdateArtifact(version: version, fileURL: URL(fileURLWithPath: "/dev/null")) },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertTrue(recorder.artifacts.isEmpty)
        XCTAssertEqual(fetcher.requestedURLs, [appcastURL])
    }

    // MARK: - End-to-end against the real PendingUpdateArtifactStore

    func test_checkNow_realArtifactStore_writesVerifiedBytesToDisk() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppcastUpdateCheckerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let entry = signedNewerEntry()
        let fetcher = FakeAppcastHTTPFetcher()
        fetcher.stub(url: appcastURL, data: appcastJSON(for: entry), statusCode: 200)
        fetcher.stub(url: downloadURL, data: artifactData, statusCode: 200)
        let recorder = ArtifactRecorder()

        let checker = makeChecker(
            fetcher: fetcher,
            artifactStore: { data, version in
                try PendingUpdateArtifactStore.store(data: data, version: version, temporaryDirectory: tempRoot.path)
            },
            recorder: recorder
        )

        checker.checkNow()

        XCTAssertEqual(recorder.artifacts.count, 1)
        let artifact = try XCTUnwrap(recorder.artifacts.first)
        XCTAssertEqual(artifact.version, "0.2.0")
        XCTAssertEqual(try Data(contentsOf: artifact.fileURL), artifactData)
    }

    // MARK: - Scheduling default

    func test_defaultInterval_is24Hours() {
        XCTAssertEqual(AppcastUpdateChecker.defaultInterval, 24 * 60 * 60)
    }
}
