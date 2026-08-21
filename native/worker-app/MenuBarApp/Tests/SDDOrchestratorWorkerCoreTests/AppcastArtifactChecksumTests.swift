import XCTest
@testable import SDDOrchestratorWorkerCore

final class AppcastArtifactChecksumTests: XCTestCase {
    private let artifactData = "fake-dmg-bytes-for-testing".data(using: .utf8)!

    // Independently computed (not via CryptoKit, to actually exercise
    // AppcastArtifactChecksum's hex encoding rather than just round-trip
    // the same library against itself):
    //   printf '%s' "fake-dmg-bytes-for-testing" | shasum -a 256
    private let correctHex = "7c6d9e388138afc5003a875a56ca4dd27a5dca8dd6c25bdd0b92aa58673fa8c7"

    func test_matches_correctChecksum_isTrue() {
        XCTAssertTrue(AppcastArtifactChecksum.matches(data: artifactData, expectedHexSHA256: correctHex))
    }

    func test_matches_mismatchedChecksum_isFalse() {
        let mismatched = "0000000000000000000000000000000000000000000000000000000000000000"
        XCTAssertFalse(AppcastArtifactChecksum.matches(data: artifactData, expectedHexSHA256: mismatched))
    }

    func test_matches_isCaseInsensitive() {
        XCTAssertTrue(AppcastArtifactChecksum.matches(data: artifactData, expectedHexSHA256: correctHex.uppercased()))
    }

    func test_matches_trimsSurroundingWhitespace() {
        XCTAssertTrue(AppcastArtifactChecksum.matches(data: artifactData, expectedHexSHA256: "  \(correctHex)  \n"))
    }

    func test_matches_differentData_isFalse() {
        let otherData = "different-bytes".data(using: .utf8)!

        XCTAssertFalse(AppcastArtifactChecksum.matches(data: otherData, expectedHexSHA256: correctHex))
    }
}
