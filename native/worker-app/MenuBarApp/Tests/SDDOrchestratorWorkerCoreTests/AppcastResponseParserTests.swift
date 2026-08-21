import XCTest
@testable import SDDOrchestratorWorkerCore

final class AppcastResponseParserTests: XCTestCase {
    private let validBody = """
    {
      "latest_version": "0.2.0",
      "minimum_os": "14.0",
      "download_url": "https://example.com/SDD-Orchestrator-Worker-0.2.0.dmg",
      "sha256": "abc123",
      "signature": "c2lnbmF0dXJl"
    }
    """.data(using: .utf8)!

    func test_parse_200WithValidBody_returnsSuccessWithParsedEntry() {
        let outcome = AppcastResponseParser.parse(statusCode: 200, data: validBody, transportError: nil)

        XCTAssertEqual(
            outcome,
            .success(
                AppcastEntry(
                    latestVersion: "0.2.0",
                    minimumOS: "14.0",
                    downloadURL: "https://example.com/SDD-Orchestrator-Worker-0.2.0.dmg",
                    sha256: "abc123",
                    signatureBase64: "c2lnbmF0dXJl"
                )
            )
        )
    }

    func test_parse_404_isFailure_withoutParsingBody() {
        let outcome = AppcastResponseParser.parse(statusCode: 404, data: validBody, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure for a 404, got \(outcome)")
        }
    }

    func test_parse_transportError_isFailure_regardlessOfStatusOrData() {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "the network is unreachable" }
        }

        let outcome = AppcastResponseParser.parse(statusCode: nil, data: nil, transportError: FakeError())

        guard case .failure(let reason) = outcome else {
            return XCTFail("expected .failure for a transport error, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("the network is unreachable"))
    }

    func test_parse_200WithMalformedBody_isFailure() {
        let malformed = "not json at all".data(using: .utf8)!

        let outcome = AppcastResponseParser.parse(statusCode: 200, data: malformed, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure for an unparseable 200 body, got \(outcome)")
        }
    }

    func test_parse_200WithMissingSignatureField_isFailure() {
        let missingSignature = """
        {"latest_version": "0.2.0", "minimum_os": "14.0", "download_url": "https://example.com/x.dmg", "sha256": "abc"}
        """.data(using: .utf8)!

        let outcome = AppcastResponseParser.parse(statusCode: 200, data: missingSignature, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure when 'signature' is missing, got \(outcome)")
        }
    }

    func test_parse_200WithEmptySignatureField_isFailure() {
        let emptySignature = """
        {"latest_version": "0.2.0", "minimum_os": "14.0", "download_url": "https://example.com/x.dmg", "sha256": "abc", "signature": ""}
        """.data(using: .utf8)!

        let outcome = AppcastResponseParser.parse(statusCode: 200, data: emptySignature, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure for an empty 'signature' field, got \(outcome)")
        }
    }

    func test_parse_200WithNilData_isFailure() {
        let outcome = AppcastResponseParser.parse(statusCode: 200, data: nil, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure for a 200 with no body, got \(outcome)")
        }
    }

    func test_parse_noStatusCodeAndNoError_isFailure() {
        let outcome = AppcastResponseParser.parse(statusCode: nil, data: nil, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure when there is no status code at all, got \(outcome)")
        }
    }
}
