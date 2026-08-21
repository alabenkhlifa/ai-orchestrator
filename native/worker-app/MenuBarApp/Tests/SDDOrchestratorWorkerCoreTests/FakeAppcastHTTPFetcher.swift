import Foundation
@testable import SDDOrchestratorWorkerCore

/// An `AppcastHTTPFetching` fake: stubs a canned `(data, response, error)`
/// triple per URL and records every URL it was asked to `get`, invoking the
/// completion synchronously — mirrors `FakePairingHTTPPoster`'s shape for
/// the same reason (deterministic tests, no real network call, no
/// `XCTestExpectation`). Keyed by URL (rather than a single canned
/// response) because `AppcastUpdateChecker` makes up to two different GETs
/// per check — the appcast document, then the artifact — and tests need to
/// stub each independently and assert which ones actually happened.
final class FakeAppcastHTTPFetcher: AppcastHTTPFetching {
    private var responsesByURL: [URL: (Data?, URLResponse?, Error?)] = [:]
    private(set) var requestedURLs: [URL] = []

    func stub(url: URL, data: Data?, statusCode: Int, error: Error? = nil) {
        responsesByURL[url] = (data, httpResponse(url: url, statusCode: statusCode), error)
    }

    func stubTransportError(url: URL, error: Error) {
        responsesByURL[url] = (nil, nil, error)
    }

    func get(url: URL, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        requestedURLs.append(url)
        let (data, response, error) = responsesByURL[url] ?? (nil, nil, nil)
        completion(data, response, error)
    }
}
