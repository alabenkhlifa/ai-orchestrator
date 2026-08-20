import Foundation

/// One parsed appcast entry — the JSON document
/// `AppcastUpdateChecker.checkNow()` fetches from `AppcastURLProvider`'s
/// URL:
///
///     {
///       "latest_version": "0.2.0",
///       "minimum_os": "14.0",
///       "download_url": "https://example.com/SDD-Orchestrator-Worker-0.2.0.dmg",
///       "sha256": "<hex-encoded sha256 of the .dmg the download_url points to>",
///       "signature": "<base64-encoded Ed25519 signature>"
///     }
///
/// Plain JSON (no XML/Sparkle), consistent with the JSON-everywhere
/// convention `PairingCompletionRequestBody`/`PairingCompletionResponseParser`
/// already established for the pairing endpoint. Never trust any field here
/// — including `latest_version` and `sha256` — until
/// `AppcastSignatureVerifier.verify` has confirmed `signatureBase64` against
/// `canonicalSignedPayload` (AC-11).
public struct AppcastEntry: Equatable, Sendable {
    public let latestVersion: String
    public let minimumOS: String
    public let downloadURL: String
    public let sha256: String
    public let signatureBase64: String

    public init(
        latestVersion: String,
        minimumOS: String,
        downloadURL: String,
        sha256: String,
        signatureBase64: String
    ) {
        self.latestVersion = latestVersion
        self.minimumOS = minimumOS
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.signatureBase64 = signatureBase64
    }

    /// The exact bytes `signatureBase64` must be a valid Ed25519 signature
    /// over — see `AppcastCanonicalPayload`'s doc comment for the precise
    /// format.
    public var canonicalSignedPayload: Data {
        AppcastCanonicalPayload.bytes(
            latestVersion: latestVersion,
            minimumOS: minimumOS,
            downloadURL: downloadURL,
            sha256: sha256
        )
    }
}
