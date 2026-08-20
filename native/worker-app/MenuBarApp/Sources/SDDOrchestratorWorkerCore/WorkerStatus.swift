/// The menu-bar app's own top-level status, shown as the disabled header
/// line of the status-item menu.
///
/// `.notPaired` and `.pairedSettingUp` are fully correct as of Task 4
/// (AC-03/04/05 from Task 2; AC-07/AC-08 from Task 4). `.pairedConnecting`,
/// `.connected`, and `.disconnected` become real once Task 5 stores a
/// `Configuration`; `.updateAvailable` is a placeholder for Task 9
/// (appcast/updates).
public enum WorkerStatus: Equatable, Sendable {
    case notPaired
    /// [Task 4, AC-07] The URL-scheme pairing handoff succeeded — a
    /// credential and worker identity were obtained from
    /// `POST /worker_pairings` — but post-pairing setup (Task 5: repository
    /// path, coding-agent selection, `Configuration.store`, starting
    /// `Worker.Supervisor`) has not run, because Task 5 does not exist yet.
    /// Distinct from both `.notPaired` (no credential at all) and
    /// `.pairedConnecting`/`.connected` (a stored configuration whose
    /// gateway connection this app is polling) — see
    /// `PostPairingSetupCoordinator`.
    case pairedSettingUp
    /// Paired, but no connect or disconnect has been observed yet in this
    /// launch (`GatewayConnectionState.unknown`) — reached once Task 5
    /// stores a real `Configuration` and a later pairing check reports
    /// `.paired` from disk.
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
        case .pairedSettingUp: return "Paired, setting up…"
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
