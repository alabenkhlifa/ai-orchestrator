import Foundation

/// The one seam `PairingFlowController` posts a pairing-completion request
/// through, so tests can exercise the response-handling logic (201 vs. 403
/// vs. a transport failure) against a fake instead of a real network call —
/// the same "protocol + fake" shape `CommandRunning`/`FakeCommandRunner`
/// already establishes for shelling out to the embedded release.
public protocol PairingHTTPPosting {
    func post(url: URL, jsonObject: [String: String], completion: @escaping (Data?, URLResponse?, Error?) -> Void)
}

/// The production `PairingHTTPPosting` implementation: a real `URLSession`
/// POST. No new dependency — `URLSession` is Foundation.
public final class URLSessionPairingHTTPPoster: PairingHTTPPosting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(url: URL, jsonObject: [String: String], completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: jsonObject)

        session.dataTask(with: request) { data, response, error in
            completion(data, response, error)
        }.resume()
    }
}
