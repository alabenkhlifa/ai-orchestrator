import Foundation

/// What an unpaired app should do on its next tick.
public enum PairingLoopAction: Equatable, Sendable {
    /// Already paired. Nothing to fetch, nothing to try, and no reason to keep
    /// asking — a paired app must not poll.
    case idle
    /// No code, or one too close to expiry to be worth offering.
    case refreshCode
    /// A live code nobody may have redeemed yet. Trying to finish is how the
    /// app finds out.
    case attemptCompletion(String)
}

/// Decides, per tick, what an unpaired app does next.
///
/// The app has no way to be told that an owner redeemed its code, and it needs
/// none: an attempt nobody has bound cannot be completed, so attempting
/// completion *is* the question. A refusal means "not yet" and a success means
/// an owner redeemed it, in which case the same call already returned the
/// credential the app needs (`specs/38-worker-initiated-pairing`, AC-08).
///
/// This is a plain function over the current state so the whole loop is
/// testable without a timer, a network, or a menu bar. `AppDelegate` owns only
/// the schedule and the side effects.
public enum PairingLoop {
    public static func next(
        status: WorkerStatus,
        codeState: PairingCodeState,
        now: Date = Date(),
        refreshMargin: TimeInterval = PairingCodeHolder.defaultRefreshMargin
    ) -> PairingLoopAction {
        guard status == .notPaired else { return .idle }

        switch codeState {
        case .none, .unreachable:
            return .refreshCode

        case .held(let code):
            if code.needsReplacing(now: now, margin: refreshMargin) {
                return .refreshCode
            }

            return .attemptCompletion(code.value)
        }
    }
}
