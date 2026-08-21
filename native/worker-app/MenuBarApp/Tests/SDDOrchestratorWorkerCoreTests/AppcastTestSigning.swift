import CryptoKit
import Foundation
@testable import SDDOrchestratorWorkerCore

/// A fixed, throwaway Ed25519 keypair used only by this test target to sign
/// fixture appcast entries, proving `AppcastSignatureVerifier` accepts a
/// validly-signed entry and rejects everything else.
///
/// Generated once via a small ad hoc `swift` script (not checked in — this
/// is the exact content that produced the constants below):
///
///     import CryptoKit
///     import Foundation
///
///     let privateKey = Curve25519.Signing.PrivateKey()
///     print("private_base64=\(privateKey.rawRepresentation.base64EncodedString())")
///     print("public_base64=\(privateKey.publicKey.rawRepresentation.base64EncodedString())")
///
/// run as `swift gen_appcast_keypair.swift`. This is test-only material: the
/// private key here is never embedded in the shipped `.app` bundle or
/// `Info.plist` — this file lives only in the test target, which is never
/// linked into `SDDOrchestratorWorkerApp` or copied into the `.app` bundle
/// (see `Package.swift`: `SDDOrchestratorWorkerCoreTests` depends on
/// `SDDOrchestratorWorkerCore`, nothing depends on it back). The matching
/// *public* key (`AppcastTestSigning.publicKeyBase64`) is what
/// `native/worker-app/build.sh` embeds as its default, non-production
/// `SDDOrchestratorAppcastPublicKey` — see that script's own comment.
enum AppcastTestSigning {
    static let privateKeyBase64 = "7Jh40Nq7EgnFYCxfUm44nXWBVMAQcRmmnzPovNu4B6M="
    static let publicKeyBase64 = "iQtBThP+7yEKC0Wy1xRPmK3vhMec2FIgDvt9dvsD3Ck="

    /// A second, unrelated real keypair (generated the same way) — used to
    /// prove verification fails when an entry is validly signed, just not
    /// by the key the app trusts.
    static let otherPrivateKeyBase64 = "AqVEONm4m6AqU9eQkuzIZlJNb2+QxG90gLwHYxjUb6U="

    private static var otherPrivateKey: Curve25519.Signing.PrivateKey {
        guard
            let data = Data(base64Encoded: otherPrivateKeyBase64),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        else {
            preconditionFailure("AppcastTestSigning.otherPrivateKeyBase64 is not a valid Ed25519 private key")
        }
        return key
    }

    /// Signs `entry` with the *other* fixture keypair — a real, validly
    /// formed signature, just not one `AppcastPublicKeyProvider`'s trusted
    /// key will accept.
    static func signWithOtherKey(_ entry: AppcastEntry) -> AppcastEntry {
        let signature = try! otherPrivateKey.signature(for: entry.canonicalSignedPayload)
        return AppcastEntry(
            latestVersion: entry.latestVersion,
            minimumOS: entry.minimumOS,
            downloadURL: entry.downloadURL,
            sha256: entry.sha256,
            signatureBase64: signature.base64EncodedString()
        )
    }

    private static var privateKey: Curve25519.Signing.PrivateKey {
        guard
            let data = Data(base64Encoded: privateKeyBase64),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        else {
            preconditionFailure("AppcastTestSigning.privateKeyBase64 is not a valid Ed25519 private key")
        }
        return key
    }

    /// Signs `entry`'s canonical payload with the fixture private key and
    /// returns a new entry carrying that real signature — the standard way
    /// every "validly signed" fixture in this test target is built.
    static func sign(_ entry: AppcastEntry) -> AppcastEntry {
        let signature = try! privateKey.signature(for: entry.canonicalSignedPayload)
        return AppcastEntry(
            latestVersion: entry.latestVersion,
            minimumOS: entry.minimumOS,
            downloadURL: entry.downloadURL,
            sha256: entry.sha256,
            signatureBase64: signature.base64EncodedString()
        )
    }
}
