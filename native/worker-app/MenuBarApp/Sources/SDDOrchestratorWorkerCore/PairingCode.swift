import Foundation

/// One pairing code this app obtained for itself, and the moment it stops
/// being accepted.
///
/// The code belongs to no device workspace until an owner redeems it in the
/// dashboard, so holding one grants nothing. It is still a credential: it is
/// never logged, never written to disk, and lives only for as long as this app
/// is unpaired (`specs/38-worker-initiated-pairing`).
public struct PairingCode: Equatable, Sendable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    /// Whether this code is close enough to expiry that a person who copies it
    /// now might paste something the dashboard has already stopped accepting.
    public func needsReplacing(now: Date, margin: TimeInterval) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}

/// What the app currently holds while it is unpaired.
public enum PairingCodeState: Equatable, Sendable {
    /// Nothing asked for yet.
    case none
    /// A code the dashboard should still accept.
    case held(PairingCode)
    /// The control plane could not be reached or answered unusably. Deliberately
    /// distinct from `.none`: the menu can say the app cannot reach the control
    /// plane instead of silently offering nothing, and it never leaves a stale
    /// code on display that would be refused when pasted.
    case unreachable
}

/// The outcome of asking the control plane for a code.
public enum PairingCodeOutcome: Equatable, Sendable {
    case issued(PairingCode)
    /// A refusal, a throttle, a transport failure, or an unreadable body. The
    /// app treats all of them the same way, because none of them leaves it
    /// holding something it can show.
    case unavailable(String)
}

/// Reads `POST /pairing_codes`' success body, mirroring
/// `SddOrchestratorWeb.PairingCodeController.create/2`'s JSON shape.
public enum PairingCodeResponseParser {
    public static func parse(
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) -> PairingCodeOutcome {
        if let error {
            return .unavailable("could not reach the control plane: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return .unavailable("the control plane gave no usable answer")
        }

        guard http.statusCode == 201 else {
            return .unavailable("the control plane refused to issue a code")
        }

        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object["code"] as? String,
            !value.isEmpty,
            let expiresAt = object["expires_at"] as? String,
            let expiry = iso8601(from: expiresAt)
        else {
            return .unavailable("the control plane's answer could not be read")
        }

        return .issued(PairingCode(value: value, expiresAt: expiry))
    }

    // Phoenix renders a `DateTime` without fractional seconds; accept both so a
    // formatting change on the control plane cannot silently stop pairing.
    private static func iso8601(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = withFraction.date(from: raw) {
            return date
        }

        return ISO8601DateFormatter().date(from: raw)
    }
}
