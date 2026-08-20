import Foundation

/// Resolves the URL `AppcastUpdateChecker` fetches on its periodic schedule
/// (specs/36 Task 10, AC-11).
///
/// Mirrors `DashboardURLProvider` exactly: production hosting for the
/// appcast is an explicit, not-yet-decided specs/36 release-gate item (same
/// as the dashboard URL and the Developer ID signing certificate), so this
/// is a placeholder, configurable constant read from the `.app` bundle's own
/// `Info.plist` (`SDDOrchestratorAppcastURL`, written by
/// `native/worker-app/build.sh`) rather than hardcoded in compiled code.
public enum AppcastURLProvider {
    public static let infoPlistKey = "SDDOrchestratorAppcastURL"
    public static let defaultURLString = "http://localhost:4000/appcast.json"

    /// `infoDictionary` is normally `Bundle.main.infoDictionary`; passed in
    /// explicitly so this stays unit-testable without a real bundle.
    public static func appcastURL(infoDictionary: [String: Any]?) -> URL {
        guard
            let raw = infoDictionary?[infoPlistKey] as? String,
            let url = URL(string: raw),
            url.scheme != nil
        else {
            guard let fallback = URL(string: defaultURLString) else {
                preconditionFailure("AppcastURLProvider.defaultURLString is not a valid URL")
            }
            return fallback
        }

        return url
    }
}
