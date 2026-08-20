/// This worker's own self-reported identity attributes, sent with a
/// pairing-completion request (specs/36 Task 4) so
/// `SddOrchestratorWeb.WorkerPairingController` can record them on the
/// issued `LocalWorker` row. Every field mirrors one of that controller's
/// optional `@worker_attr_keys`.
public struct WorkerSelfReport: Equatable, Sendable {
    public let osFamily: String
    public let osMajor: String
    /// `nil` when `ProtocolVersionQuerier` could not determine it — omitted
    /// from the request body rather than blocking pairing (the
    /// control-plane endpoint treats it as optional).
    public let protocolVersion: String?
    public let appVersion: String

    public init(osFamily: String, osMajor: String, protocolVersion: String?, appVersion: String) {
        self.osFamily = osFamily
        self.osMajor = osMajor
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }
}

/// Reads this app's own `CFBundleShortVersionString`, mirroring
/// `DashboardURLProvider`'s pattern of taking `infoDictionary` as an
/// explicit parameter so it stays unit-testable without a real bundle.
public enum WorkerAppVersionReader {
    public static let infoPlistKey = "CFBundleShortVersionString"

    public static func appVersion(infoDictionary: [String: Any]?) -> String {
        (infoDictionary?[infoPlistKey] as? String) ?? "unknown"
    }
}
