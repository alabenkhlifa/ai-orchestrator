import XCTest
@testable import SDDOrchestratorWorkerCore

final class PairingCompletionRequestBodyTests: XCTestCase {
    func test_build_includesCodeAndAllSelfReportFields() {
        let selfReport = WorkerSelfReport(
            osFamily: "macos",
            osMajor: "15",
            protocolVersion: "1",
            appVersion: "1.2.3"
        )

        let body = PairingCompletionRequestBody.build(code: "abc123.secret", selfReport: selfReport)

        XCTAssertEqual(
            body,
            [
                "code": "abc123.secret",
                "os_family": "macos",
                "os_major": "15",
                "protocol_version": "1",
                "app_version": "1.2.3"
            ]
        )
    }

    func test_build_omitsProtocolVersionKey_whenNil() {
        let selfReport = WorkerSelfReport(osFamily: "macos", osMajor: "15", protocolVersion: nil, appVersion: "1.2.3")

        let body = PairingCompletionRequestBody.build(code: "abc123.secret", selfReport: selfReport)

        XCTAssertNil(body["protocol_version"])
        XCTAssertEqual(body["code"], "abc123.secret")
    }
}
