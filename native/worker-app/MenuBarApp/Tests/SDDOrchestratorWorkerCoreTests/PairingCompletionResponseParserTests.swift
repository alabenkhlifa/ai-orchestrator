import XCTest
@testable import SDDOrchestratorWorkerCore

final class PairingCompletionResponseParserTests: XCTestCase {
    private let successBody = """
    {
      "credential": "worker-id-123.secret-abc",
      "worker": {
        "id": "worker-id-123",
        "device_workspace_id": "ws-456",
        "os_family": "macos",
        "os_major": "15",
        "protocol_version": "1",
        "app_version": "1.2.3",
        "state": "active"
      }
    }
    """.data(using: .utf8)!

    func test_parse_201WithValidBody_returnsSuccessWithParsedCredentialAndWorker() {
        let outcome = PairingCompletionResponseParser.parse(statusCode: 201, data: successBody, transportError: nil)

        XCTAssertEqual(
            outcome,
            .success(
                PairingCompletionSuccess(
                    credential: "worker-id-123.secret-abc",
                    worker: WorkerIdentity(
                        id: "worker-id-123",
                        deviceWorkspaceID: "ws-456",
                        osFamily: "macos",
                        osMajor: "15",
                        protocolVersion: "1",
                        appVersion: "1.2.3",
                        state: "active"
                    )
                )
            )
        )
    }

    func test_parse_403_isFailure_withoutParsingBody() {
        let refusalBody = #"{"error": "refused"}"#.data(using: .utf8)!

        let outcome = PairingCompletionResponseParser.parse(statusCode: 403, data: refusalBody, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure for a 403, got \(outcome)")
        }
    }

    func test_parse_transportError_isFailure_regardlessOfStatusOrData() {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "the network is unreachable" }
        }

        let outcome = PairingCompletionResponseParser.parse(statusCode: nil, data: nil, transportError: FakeError())

        guard case .failure(let reason) = outcome else {
            return XCTFail("expected .failure for a transport error, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("the network is unreachable"))
    }

    func test_parse_201WithMalformedBody_isFailure() {
        let malformed = "not json at all".data(using: .utf8)!

        let outcome = PairingCompletionResponseParser.parse(statusCode: 201, data: malformed, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure for an unparseable 201 body, got \(outcome)")
        }
    }

    func test_parse_201WithMissingCredentialField_isFailure() {
        let missingCredential = #"{"worker": {"id": "x", "device_workspace_id": "y"}}"#.data(using: .utf8)!

        let outcome = PairingCompletionResponseParser.parse(statusCode: 201, data: missingCredential, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure when 'credential' is missing, got \(outcome)")
        }
    }

    func test_parse_201WithNilData_isFailure() {
        let outcome = PairingCompletionResponseParser.parse(statusCode: 201, data: nil, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure for a 201 with no body, got \(outcome)")
        }
    }

    func test_parse_noStatusCodeAndNoError_isFailure() {
        let outcome = PairingCompletionResponseParser.parse(statusCode: nil, data: nil, transportError: nil)

        guard case .failure = outcome else {
            return XCTFail("expected .failure when there is no status code at all, got \(outcome)")
        }
    }
}
