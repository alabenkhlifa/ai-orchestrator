import Foundation

/// [specs/42 Task 1, AC-01/AC-02] The kind of state a `WorkerStatus` is, so
/// the menu can put exactly one coloured dot beside its status line.
///
/// The cases name the kind of state, never the colour. Two reasons:
///
/// 1. This target is plain Foundation with no AppKit (see `Package.swift`),
///    so it cannot hold an `NSColor` anyway. Keeping the decision semantic is
///    what lets it live here, where a unit test can reach it.
/// 2. The colour is presentation and may change; the grouping is a product
///    rule and must not. That a refused connection and a dropped one are the
///    same kind of problem is worth a test. That the healthy dot is exactly
///    this green is not.
///
/// `.update` is deliberately its own kind rather than folded into a health
/// case. An update waiting to be installed says nothing about whether the
/// worker is attached and working; the app is usually connected and healthy
/// while it waits. Colouring it as a problem would tell the person something
/// is wrong, and colouring it as healthy would hide it.
public enum StatusIndicator: Equatable, Sendable, CaseIterable {
    /// Attached to the control plane and working.
    case healthy
    /// Something is wrong and the person may need to act.
    case problem
    /// Moving toward `.healthy` on its own; nothing to do but wait.
    case inProgress
    /// Nothing is wrong and nothing is running: this app has no pairing yet.
    case idle
    /// A verified update is waiting. Not a health signal — see above.
    case update
}

extension WorkerStatus {
    /// [specs/42 Task 1, AC-01/AC-02] The one indicator this status shows.
    ///
    /// Non-optional and switched exhaustively with no `default`, so every
    /// status answers exactly one indicator and an eighth `WorkerStatus`
    /// cannot compile until someone decides which kind of state it is. A
    /// status line with no dot is therefore not a state this app can reach.
    ///
    /// The mapping lives beside `StatusIndicator` rather than in
    /// `WorkerStatus.swift` because it belongs to the indicator's small
    /// vocabulary, not to the status derivation in `from(pairing:connection:)`
    /// that file owns. Nothing is lost by the distance: the exhaustive switch
    /// makes the compiler point here the moment a case is added there.
    public var indicator: StatusIndicator {
        switch self {
        case .connected:
            return .healthy

        // A refusal and a dropped connection are answered by the person the
        // same way — the worker is not attached and they may have to do
        // something — so they are one kind here, even though `WorkerStatus`
        // keeps them separate to say which one happened in words.
        case .disconnected, .connectionRefused:
            return .problem

        // Both are the app working through a sequence that ends on its own.
        // "Setting up" and "Connecting…" ask nothing of the person, so they
        // must not read as a problem.
        case .pairedConnecting, .pairedSettingUp:
            return .inProgress

        // Not paired is the normal first state of a fresh install, not a
        // fault. It gets the quiet dot so a genuine problem stands out
        // against it.
        case .notPaired:
            return .idle

        case .updateAvailable:
            return .update
        }
    }
}
