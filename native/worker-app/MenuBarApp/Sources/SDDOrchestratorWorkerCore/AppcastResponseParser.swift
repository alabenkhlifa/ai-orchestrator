import Foundation

public enum AppcastFetchOutcome: Equatable, Sendable {
    case success(AppcastEntry)
    /// A human-readable reason: a non-200 status, a transport-level failure,
    /// or a malformed/unparseable body. Never shown in the menu bar — only
    /// logged (see `AppcastUpdateChecker`) — because AC-11 requires a fetch
    /// that finds nothing trustworthy to be silent, the same as a fetch that
    /// finds a genuinely not-newer version.
    case failure(String)
}

/// Turns one appcast-endpoint HTTP response into an `AppcastFetchOutcome`,
/// without performing the network call itself — mirrors
/// `PairingCompletionResponseParser`'s "pure, unit-testable parser fed
/// canned status/data/error fixtures" shape exactly.
///
/// This only checks the response is well-formed JSON with the five required
/// string fields (including a non-empty `signature`); it does not verify the
/// signature itself — that is `AppcastSignatureVerifier`'s job, kept
/// separate so each concern has its own focused tests.
public enum AppcastResponseParser {
    public static func parse(statusCode: Int?, data: Data?, transportError: Error?) -> AppcastFetchOutcome {
        if let transportError {
            return .failure("network error: \(transportError.localizedDescription)")
        }

        guard let statusCode else {
            return .failure("no response from the appcast host")
        }

        guard statusCode == 200 else {
            return .failure("unexpected status \(statusCode)")
        }

        guard let data else {
            return .failure("empty response body")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let latestVersion = json["latest_version"] as? String,
            let minimumOS = json["minimum_os"] as? String,
            let downloadURL = json["download_url"] as? String,
            let sha256 = json["sha256"] as? String,
            let signature = json["signature"] as? String,
            !signature.isEmpty
        else {
            return .failure("malformed appcast body")
        }

        return .success(
            AppcastEntry(
                latestVersion: latestVersion,
                minimumOS: minimumOS,
                downloadURL: downloadURL,
                sha256: sha256,
                signatureBase64: signature
            )
        )
    }
}
