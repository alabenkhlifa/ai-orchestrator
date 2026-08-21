import Foundation

/// The one seam `AppcastUpdateChecker` performs an HTTP GET through — used
/// both for the appcast JSON document and, afterward, for the update
/// artifact the appcast's `download_url` points to. Same shape as
/// `PairingHTTPPosting` (protocol + fake), for the same reason: tests never
/// make a real network call, and stay deterministic without
/// `XCTestExpectation`. A single method covers both call sites because both
/// really are the same operation — an unauthenticated GET that returns
/// bytes — just against different URLs and different body content (JSON vs.
/// a binary artifact).
public protocol AppcastHTTPFetching {
    func get(url: URL, completion: @escaping (Data?, URLResponse?, Error?) -> Void)
}

/// The production `AppcastHTTPFetching` implementation: a real `URLSession`
/// GET, no request body, no custom headers, no query parameters.
///
/// [AC-15] Deliberately sends nothing beyond the bare GET: no device,
/// workspace, project, or credential identifier, and — since the design's
/// "Public, Unauthenticated Appcast" decision does not require
/// version-targeted responses (the appcast always answers with the single
/// current entry) — not even this app's own version or OS descriptors. This
/// is the simplest AC-15-safe choice: there is no caller-identifying data to
/// accidentally leak because none is ever constructed. If a future appcast
/// needs coarse version-targeting, the self-report construction already
/// established in `AppDelegate.setUpPairingFlowController()`
/// (`osFamily`/`osMajor` via `ProcessInfo`, `appVersion` via
/// `WorkerAppVersionReader`) is the exact and only vocabulary to reuse —
/// never a new identifier.
public final class URLSessionAppcastHTTPFetcher: AppcastHTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(url: URL, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        session.dataTask(with: request) { data, response, error in
            completion(data, response, error)
        }.resume()
    }
}
