import CryptoKit
import Foundation

/// Verifies a downloaded update artifact's bytes against the signed
/// appcast entry's `sha256` field (specs/36 Task 10, AC-12: "downloads and
/// verifies the update" — ties the downloaded bytes cryptographically to
/// what was signed, independent of transport).
public enum AppcastArtifactChecksum {
    /// `expectedHexSHA256` is compared case-insensitively, trimmed of
    /// surrounding whitespace — appcast authors may reasonably write
    /// upper- or lower-case hex.
    public static func matches(data: Data, expectedHexSHA256: String) -> Bool {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let expected = expectedHexSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        return hex.caseInsensitiveCompare(expected) == .orderedSame
    }
}
