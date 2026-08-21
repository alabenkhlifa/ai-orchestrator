import Foundation

/// The decoded payload of a `sddworker://pair?code=<pairing-code>&project_id=<uuid>`
/// URL-scheme open (specs/36 Task 4).
public struct PairingURLPayload: Equatable, Sendable {
    public let code: String
    public let projectID: String

    public init(code: String, projectID: String) {
        self.code = code
        self.projectID = projectID
    }
}

/// Parses the custom URL scheme the dashboard's "Open in App" link (Task 6)
/// will send. Anything that does not match exactly — wrong scheme, wrong
/// host/action, or a missing/empty `code` or `project_id` — is malformed
/// (AC-08): this returns `nil` rather than throwing or crashing, and the
/// caller is responsible for reporting that as a failure without ever
/// attempting a pairing-completion request.
public enum PairingURLPayloadParser {
    public static let scheme = "sddworker"
    public static let host = "pair"

    public static func parse(_ url: URL) -> PairingURLPayload? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard url.host?.lowercased() == host else { return nil }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let queryItems = components.queryItems ?? []

        guard let code = value(for: "code", in: queryItems), !code.isEmpty else { return nil }
        guard let projectID = value(for: "project_id", in: queryItems), !projectID.isEmpty else { return nil }

        return PairingURLPayload(code: code, projectID: projectID)
    }

    private static func value(for name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first(where: { $0.name == name })?.value
    }
}
