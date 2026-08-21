import XCTest
@testable import SDDOrchestratorWorkerCore

final class PairingURLPayloadParserTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("test fixture itself is not a valid URL: \(string)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    func test_parse_validPayload_returnsCodeAndProjectID() {
        let payload = PairingURLPayloadParser.parse(url("sddworker://pair?code=abc123.secret&project_id=9c2f"))

        XCTAssertEqual(payload, PairingURLPayload(code: "abc123.secret", projectID: "9c2f"))
    }

    func test_parse_missingCode_isMalformed() {
        XCTAssertNil(PairingURLPayloadParser.parse(url("sddworker://pair?project_id=9c2f")))
    }

    func test_parse_missingProjectID_isMalformed() {
        XCTAssertNil(PairingURLPayloadParser.parse(url("sddworker://pair?code=abc123.secret")))
    }

    func test_parse_emptyCode_isMalformed() {
        XCTAssertNil(PairingURLPayloadParser.parse(url("sddworker://pair?code=&project_id=9c2f")))
    }

    func test_parse_emptyProjectID_isMalformed() {
        XCTAssertNil(PairingURLPayloadParser.parse(url("sddworker://pair?code=abc123.secret&project_id=")))
    }

    func test_parse_wrongScheme_isMalformed() {
        XCTAssertNil(PairingURLPayloadParser.parse(url("https://pair?code=abc123.secret&project_id=9c2f")))
    }

    func test_parse_wrongHost_isMalformed() {
        XCTAssertNil(PairingURLPayloadParser.parse(url("sddworker://notpair?code=abc123.secret&project_id=9c2f")))
    }

    func test_parse_noQueryAtAll_isMalformed() {
        XCTAssertNil(PairingURLPayloadParser.parse(url("sddworker://pair")))
    }

    func test_parse_isCaseInsensitiveOnSchemeAndHost() {
        let payload = PairingURLPayloadParser.parse(url("SDDWorker://PAIR?code=abc123.secret&project_id=9c2f"))

        XCTAssertEqual(payload, PairingURLPayload(code: "abc123.secret", projectID: "9c2f"))
    }

    func test_parse_extraUnknownQueryItems_areIgnored() {
        let payload = PairingURLPayloadParser.parse(
            url("sddworker://pair?code=abc123.secret&project_id=9c2f&utm_source=dashboard")
        )

        XCTAssertEqual(payload, PairingURLPayload(code: "abc123.secret", projectID: "9c2f"))
    }
}
