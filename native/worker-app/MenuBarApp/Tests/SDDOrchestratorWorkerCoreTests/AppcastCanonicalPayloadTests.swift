import XCTest
@testable import SDDOrchestratorWorkerCore

final class AppcastCanonicalPayloadTests: XCTestCase {
    func test_bytes_producesSortedKeyCompactJSON_withNoExtraWhitespace() {
        let payload = AppcastCanonicalPayload.bytes(
            latestVersion: "0.2.0",
            minimumOS: "14.0",
            downloadURL: "https://example.com/SDD-Orchestrator-Worker-0.2.0.dmg",
            sha256: "abc123"
        )

        let expected = #"{"download_url":"https://example.com/SDD-Orchestrator-Worker-0.2.0.dmg","latest_version":"0.2.0","minimum_os":"14.0","sha256":"abc123"}"#

        XCTAssertEqual(String(data: payload, encoding: .utf8), expected)
    }

    func test_bytes_isDeterministic_sameInputsProduceIdenticalBytes() {
        let first = AppcastCanonicalPayload.bytes(
            latestVersion: "1.0.0", minimumOS: "14.0", downloadURL: "https://example.com/a.dmg", sha256: "deadbeef"
        )
        let second = AppcastCanonicalPayload.bytes(
            latestVersion: "1.0.0", minimumOS: "14.0", downloadURL: "https://example.com/a.dmg", sha256: "deadbeef"
        )

        XCTAssertEqual(first, second)
    }

    func test_bytes_escapesQuotesAndBackslashesInValues() {
        let payload = AppcastCanonicalPayload.bytes(
            latestVersion: "1.0.0",
            minimumOS: "14.0",
            downloadURL: #"https://example.com/weird"quote\path.dmg"#,
            sha256: "abc"
        )

        let json = String(data: payload, encoding: .utf8)!
        XCTAssertTrue(json.contains(#"weird\"quote\\path.dmg"#))
    }

    func test_entry_canonicalSignedPayload_excludesSignatureField() {
        let entry = AppcastEntry(
            latestVersion: "0.2.0",
            minimumOS: "14.0",
            downloadURL: "https://example.com/x.dmg",
            sha256: "abc123",
            signatureBase64: "should-never-appear-in-signed-bytes"
        )

        let json = String(data: entry.canonicalSignedPayload, encoding: .utf8)!
        XCTAssertFalse(json.contains("signature"))
        XCTAssertFalse(json.contains("should-never-appear-in-signed-bytes"))
    }
}
