import Foundation

/// Resolves the base64-encoded Ed25519 public key `AppcastSignatureVerifier`
/// checks every appcast entry's signature against.
///
/// Mirrors `DashboardURLProvider`/`AppcastURLProvider`'s "read from
/// `Info.plist`, keep production hosting/custody out of compiled code"
/// pattern — `SDDOrchestratorAppcastPublicKey` is written by
/// `native/worker-app/build.sh`. Unlike the dashboard/appcast URLs there is
/// no safe generic fallback for a *missing* key: a missing or unparsable
/// value must make every signature verification fail closed (see
/// `AppcastSignatureVerifier.verify`), never fall back to some other
/// trusted key. Real production key custody and rotation are this
/// specification's own release-gate item, exactly like the Developer ID
/// signing certificate — `build.sh`'s embedded default is a throwaway
/// development/test keypair, not a production secret.
public enum AppcastPublicKeyProvider {
    public static let infoPlistKey = "SDDOrchestratorAppcastPublicKey"

    /// `infoDictionary` is normally `Bundle.main.infoDictionary`; passed in
    /// explicitly so this stays unit-testable without a real bundle. `nil`
    /// when the key is absent or not a string — callers must treat that as
    /// "verification can never succeed", not as "skip verification".
    public static func publicKeyBase64(infoDictionary: [String: Any]?) -> String? {
        infoDictionary?[infoPlistKey] as? String
    }
}
