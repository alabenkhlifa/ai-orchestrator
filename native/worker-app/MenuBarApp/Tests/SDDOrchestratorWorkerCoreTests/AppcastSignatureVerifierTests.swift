import XCTest
@testable import SDDOrchestratorWorkerCore

final class AppcastSignatureVerifierTests: XCTestCase {
    private let baseEntry = AppcastEntry(
        latestVersion: "0.2.0",
        minimumOS: "14.0",
        downloadURL: "https://example.com/SDD-Orchestrator-Worker-0.2.0.dmg",
        sha256: "abcdef0123456789",
        signatureBase64: ""
    )

    func test_verify_validlySignedEntry_passes() {
        let signed = AppcastTestSigning.sign(baseEntry)

        XCTAssertTrue(
            AppcastSignatureVerifier.verify(entry: signed, publicKeyBase64: AppcastTestSigning.publicKeyBase64)
        )
    }

    func test_verify_tamperedLatestVersion_withOriginalSignature_fails() {
        let signed = AppcastTestSigning.sign(baseEntry)
        let tampered = AppcastEntry(
            latestVersion: "9.9.9",
            minimumOS: signed.minimumOS,
            downloadURL: signed.downloadURL,
            sha256: signed.sha256,
            signatureBase64: signed.signatureBase64
        )

        XCTAssertFalse(
            AppcastSignatureVerifier.verify(entry: tampered, publicKeyBase64: AppcastTestSigning.publicKeyBase64)
        )
    }

    func test_verify_tamperedDownloadURL_withOriginalSignature_fails() {
        let signed = AppcastTestSigning.sign(baseEntry)
        let tampered = AppcastEntry(
            latestVersion: signed.latestVersion,
            minimumOS: signed.minimumOS,
            downloadURL: "https://attacker.example/malicious.dmg",
            sha256: signed.sha256,
            signatureBase64: signed.signatureBase64
        )

        XCTAssertFalse(
            AppcastSignatureVerifier.verify(entry: tampered, publicKeyBase64: AppcastTestSigning.publicKeyBase64)
        )
    }

    func test_verify_tamperedSHA256_withOriginalSignature_fails() {
        let signed = AppcastTestSigning.sign(baseEntry)
        let tampered = AppcastEntry(
            latestVersion: signed.latestVersion,
            minimumOS: signed.minimumOS,
            downloadURL: signed.downloadURL,
            sha256: "0000000000000000",
            signatureBase64: signed.signatureBase64
        )

        XCTAssertFalse(
            AppcastSignatureVerifier.verify(entry: tampered, publicKeyBase64: AppcastTestSigning.publicKeyBase64)
        )
    }

    func test_verify_missingSignature_fails() {
        let unsigned = AppcastEntry(
            latestVersion: baseEntry.latestVersion,
            minimumOS: baseEntry.minimumOS,
            downloadURL: baseEntry.downloadURL,
            sha256: baseEntry.sha256,
            signatureBase64: ""
        )

        XCTAssertFalse(
            AppcastSignatureVerifier.verify(entry: unsigned, publicKeyBase64: AppcastTestSigning.publicKeyBase64)
        )
    }

    func test_verify_malformedBase64Signature_fails() {
        let malformed = AppcastEntry(
            latestVersion: baseEntry.latestVersion,
            minimumOS: baseEntry.minimumOS,
            downloadURL: baseEntry.downloadURL,
            sha256: baseEntry.sha256,
            signatureBase64: "not-valid-base64!!!"
        )

        XCTAssertFalse(
            AppcastSignatureVerifier.verify(entry: malformed, publicKeyBase64: AppcastTestSigning.publicKeyBase64)
        )
    }

    func test_verify_signedByDifferentKey_fails() {
        let signedByOtherKey = AppcastTestSigning.signWithOtherKey(baseEntry)

        XCTAssertFalse(
            AppcastSignatureVerifier.verify(
                entry: signedByOtherKey,
                publicKeyBase64: AppcastTestSigning.publicKeyBase64
            )
        )
    }

    func test_verify_nilPublicKey_fails() {
        let signed = AppcastTestSigning.sign(baseEntry)

        XCTAssertFalse(AppcastSignatureVerifier.verify(entry: signed, publicKeyBase64: nil))
    }

    func test_verify_malformedPublicKey_fails() {
        let signed = AppcastTestSigning.sign(baseEntry)

        XCTAssertFalse(AppcastSignatureVerifier.verify(entry: signed, publicKeyBase64: "not-a-valid-key"))
    }
}
