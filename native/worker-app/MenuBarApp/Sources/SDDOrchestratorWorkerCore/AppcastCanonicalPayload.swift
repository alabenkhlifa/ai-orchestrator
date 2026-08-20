import Foundation

/// Builds the exact byte sequence an appcast entry's `signature` field must
/// be a valid Ed25519 signature over (specs/36 Task 10, AC-11).
///
/// A compact JSON object over exactly the four non-signature fields, keys in
/// fixed alphabetical order (`download_url`, `latest_version`, `minimum_os`,
/// `sha256`), string values JSON-escaped, and no whitespace anywhere else.
/// For example, given `latest_version: "0.2.0"`, `minimum_os: "14.0"`,
/// `download_url: "https://example.com/x.dmg"`, `sha256: "abc123"`, the
/// signed bytes are exactly:
///
///     {"download_url":"https://example.com/x.dmg","latest_version":"0.2.0","minimum_os":"14.0","sha256":"abc123"}
///
/// Deliberately hand-built rather than routed through
/// `JSONSerialization`/`JSONEncoder`: neither API's exact byte-for-byte
/// output (whitespace, key order without an explicit sort) is a documented,
/// stable contract across Foundation versions or platforms, and any future
/// re-signing tool — Task 11's install flow verifies against this same
/// definition, and a release script or a completely different language
/// might need to *produce* a signature — must reproduce this exact sequence
/// or the signature this app accepts will not match. This format has no
/// such ambiguity: it is fully specified by this doc comment and the
/// `escape(_:)` function below.
public enum AppcastCanonicalPayload {
    public static func bytes(
        latestVersion: String,
        minimumOS: String,
        downloadURL: String,
        sha256: String
    ) -> Data {
        let json = "{"
            + "\"download_url\":\"\(escape(downloadURL))\","
            + "\"latest_version\":\"\(escape(latestVersion))\","
            + "\"minimum_os\":\"\(escape(minimumOS))\","
            + "\"sha256\":\"\(escape(sha256))\""
            + "}"
        return Data(json.utf8)
    }

    /// Minimal JSON string escaping: backslash, double quote, and the
    /// standard short control-character escapes, everything else below
    /// U+0020 as `\uXXXX`, every other scalar passed through verbatim. Good
    /// enough for the field values this signs (URLs, semantic-version-ish
    /// strings, hex digests) without pulling in a full JSON encoder whose
    /// exact output format is not what is being canonicalized here.
    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }

        return result
    }
}
