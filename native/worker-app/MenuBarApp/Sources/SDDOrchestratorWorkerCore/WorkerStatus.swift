/// The menu-bar app's own top-level status, shown as the disabled header
/// line of the status-item menu.
///
/// Only `.notPaired` is required to be fully correct by this task's owned
/// ACs (AC-03/04/05 — see the specs/36 Task 2 brief); the other cases are
/// real members with placeholder menu text so Task 4 (pairing) and Task 9
/// (appcast/updates) can drive them later without widening this enum.
public enum WorkerStatus: Equatable, Sendable {
    case notPaired
    /// Paired, but no connect or disconnect has been observed yet in this
    /// launch (`GatewayConnectionState.unknown`) — placeholder until Task 4
    /// wires up a real pairing-to-connect handoff.
    case pairedConnecting
    case connected
    case disconnected
    /// Never produced by this task's code — Task 9 owns setting it once an
    /// appcast check exists.
    case updateAvailable

    /// The status line shown at the top of the menu.
    public var menuStatusLine: String {
        switch self {
        case .notPaired: return "Not paired"
        case .pairedConnecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .updateAvailable: return "Update available"
        }
    }

    /// Derives the menu-bar status from a pairing check and, when paired,
    /// the last-known gateway connection state.
    ///
    /// `.unknown` pairing folds into `.notPaired` rather than a separate
    /// "unknown" status: this app offers no action that depends on
    /// distinguishing "confirmed not paired" from "couldn't confirm
    /// paired", and AC-03's contract (only Open Dashboard + Quit, no
    /// pairing-only action exposed) is the safe default either way.
    public static func from(pairing: PairingStatus, connection: GatewayConnectionState) -> WorkerStatus {
        switch pairing {
        case .notPaired, .unknown:
            return .notPaired
        case .paired:
            switch connection {
            case .connected: return .connected
            case .disconnected: return .disconnected
            case .unknown: return .pairedConnecting
            }
        }
    }
}
