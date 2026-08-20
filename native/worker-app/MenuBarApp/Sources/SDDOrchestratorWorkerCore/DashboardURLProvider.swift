import Foundation

/// Resolves the URL "Open Dashboard" opens.
///
/// There is no stored dashboard URL before pairing (Task 4), and
/// production hosting for the dashboard is an explicit, not-yet-decided
/// specs/36 release-gate item — so this is a placeholder, configurable
/// constant, not a real discovered address. It is read from the `.app`
/// bundle's own `Info.plist` (`SDDOrchestratorDashboardURL`, written by
/// `native/worker-app/build.sh`) rather than hardcoded in compiled code, so
/// swapping in the real hosted URL later is a build-time change, not a
/// source change.
public enum DashboardURLProvider {
    public static let infoPlistKey = "SDDOrchestratorDashboardURL"
    public static let defaultURLString = "http://localhost:4000"

    /// `infoDictionary` is normally `Bundle.main.infoDictionary`; passed in
    /// explicitly so this stays unit-testable without a real bundle.
    public static func dashboardURL(infoDictionary: [String: Any]?) -> URL {
        guard
            let raw = infoDictionary?[infoPlistKey] as? String,
            let url = URL(string: raw),
            url.scheme != nil
        else {
            guard let fallback = URL(string: defaultURLString) else {
                preconditionFailure("DashboardURLProvider.defaultURLString is not a valid URL")
            }
            return fallback
        }

        return url
    }
}
