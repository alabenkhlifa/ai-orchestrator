import Foundation

/// Keeps one live pairing code while this app is unpaired.
///
/// A person copies whatever the menu bar shows, so what it shows has to be
/// something the dashboard will still accept. This asks for a code when it has
/// none and replaces it before it expires, which is why a person can walk away,
/// come back, and copy without hitting a refusal they did not cause and could
/// not diagnose (`specs/38-worker-initiated-pairing`, AC-01 and AC-07).
///
/// It holds no timer of its own. `AppDelegate` already runs a periodic check for
/// pairing and connection status, so `refreshIfNeeded(now:completion:)` is
/// driven from there and this stays a plain, testable decision.
public final class PairingCodeHolder {
    /// How far ahead of expiry a code is replaced. The control plane issues
    /// ten-minute codes, so a minute is comfortably longer than a fetch and a
    /// paste while still using most of each code's life.
    public static let defaultRefreshMargin: TimeInterval = 60

    private let poster: PairingHTTPPosting
    private let controlPlaneURL: URL
    private let refreshMargin: TimeInterval

    private(set) public var state: PairingCodeState = .none

    public init(
        poster: PairingHTTPPosting,
        controlPlaneURL: URL,
        refreshMargin: TimeInterval = PairingCodeHolder.defaultRefreshMargin
    ) {
        self.poster = poster
        self.controlPlaneURL = controlPlaneURL
        self.refreshMargin = refreshMargin
    }

    /// The code to show and copy, or `nil` when there is nothing valid to offer.
    public var currentCode: PairingCode? {
        if case .held(let code) = state { return code }
        return nil
    }

    /// Asks for a code when one is needed, and does nothing when the held one is
    /// still good. Calling this on a schedule is what keeps the shown code live.
    ///
    /// A replaced code is dropped the moment its replacement arrives, so this
    /// never holds two and never shows the older one. A failed request clears
    /// the held code rather than leaving a stale one on display.
    public func refreshIfNeeded(
        now: Date = Date(),
        completion: @escaping (PairingCodeState) -> Void = { _ in }
    ) {
        guard needsFetch(now: now) else {
            completion(state)
            return
        }

        poster.post(url: issuanceURL, jsonObject: [:]) { [weak self] data, response, error in
            guard let self else { return }

            switch PairingCodeResponseParser.parse(data: data, response: response, error: error) {
            case .issued(let code):
                self.state = .held(code)
            case .unavailable:
                self.state = .unreachable
            }

            completion(self.state)
        }
    }

    /// Drops whatever is held. Called once pairing succeeds, so a code that is
    /// no longer needed does not sit in memory or stay copyable.
    public func discard() {
        state = .none
    }

    private var issuanceURL: URL {
        controlPlaneURL.appendingPathComponent("pairing_codes")
    }

    private func needsFetch(now: Date) -> Bool {
        switch state {
        case .none, .unreachable:
            return true
        case .held(let code):
            return code.needsReplacing(now: now, margin: refreshMargin)
        }
    }
}
