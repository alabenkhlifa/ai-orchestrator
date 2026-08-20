import CryptoKit
import Foundation

/// Verifies an `AppcastEntry`'s Ed25519 signature (specs/36 Task 10, AC-11:
/// "verifies any entry's signature before trusting it").
///
/// Uses `CryptoKit`'s `Curve25519.Signing` — already available via
/// Foundation/CryptoKit on this app's macOS 14 floor, no new package
/// dependency. The verifying public key is a build-time constant for now
/// (see `AppcastPublicKeyProvider`); real production key custody and
/// rotation are this specification's own release-gate item.
public enum AppcastSignatureVerifier {
    /// Every failure mode — a `nil`/malformed/wrong-length public key, a
    /// missing/malformed/wrong-length signature, or a signature that simply
    /// does not match — collapses to `false`. Per AC-11, an invalid or
    /// missing signature is treated exactly like "no update": never
    /// surfaced, never trusted. Callers must not branch on *why*
    /// verification failed.
    public static func verify(entry: AppcastEntry, publicKeyBase64: String?) -> Bool {
        guard
            let publicKeyBase64,
            let publicKeyData = Data(base64Encoded: publicKeyBase64),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        else {
            return false
        }

        guard let signatureData = Data(base64Encoded: entry.signatureBase64), !signatureData.isEmpty else {
            return false
        }

        return publicKey.isValidSignature(signatureData, for: entry.canonicalSignedPayload)
    }
}
