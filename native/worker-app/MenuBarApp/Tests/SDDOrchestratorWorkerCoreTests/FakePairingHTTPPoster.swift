import Foundation
@testable import SDDOrchestratorWorkerCore

/// A `PairingHTTPPosting` fake: records the call it received and invokes the
/// completion synchronously with a canned `(data, response, error)` triple —
/// mirrors `FakeCommandRunner`'s shape for the same reason: tests never make
/// a real network call, and stay deterministic without `XCTestExpectation`.
final class FakePairingHTTPPoster: PairingHTTPPosting {
    private(set) var lastURL: URL?
    private(set) var lastJSONObject: [String: String]?
    private(set) var callCount = 0

    private let data: Data?
    private let response: URLResponse?
    private let error: Error?

    init(data: Data? = nil, response: URLResponse? = nil, error: Error? = nil) {
        self.data = data
        self.response = response
        self.error = error
    }

    func post(url: URL, jsonObject: [String: String], completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        callCount += 1
        lastURL = url
        lastJSONObject = jsonObject
        completion(data, response, error)
    }
}

func httpResponse(url: URL = URL(string: "http://localhost:4000/worker_pairings")!, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
}
