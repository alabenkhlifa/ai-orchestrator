/// The menu-bar app's own top-level status, shown as the disabled header
/// line of the status-item menu.
///
/// `.notPaired` and `.pairedSettingUp` are fully correct as of Task 4
/// (AC-03/04/05 from Task 2; AC-07/AC-08 from Task 4). `.pairedConnecting`,
/// `.connected`, and `.disconnected` become real once Task 5 stores a
/// `Configuration`; `.updateAvailable` becomes reachable as of Task 10
/// (appcast/updates — see `AppcastUpdateChecker`).
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
    /// [Task 10, AC-11/AC-12] Set once `AppcastUpdateChecker` has fetched a
    /// signed appcast entry, verified its signature, confirmed it reports a
    /// newer version than this running app, downloaded the artifact, and
    /// verified its checksum — see `AppDelegate`'s `AppcastUpdateChecker`
    /// wiring. Never set on an unverified or not-newer entry.
    case updateAvailable
    /// [specs/38] An owner redeemed this app's pairing code, so the control
    /// plane has authorized a worker and the dashboard can see it. The app
    /// deliberately does not report `.pairedSettingUp` here: a worker-initiated
    /// pairing has no project, the worker configuration requires one, and there
    /// is nothing this app can store or finish. Saying the dashboard has taken
    /// over is the honest state; claiming a setup would describe one that never
    /// completes.
    case handedOffToDashboard

    /// The status line shown at the top of the menu.
    public var menuStatusLine: String {
        switch self {
        case .notPaired: return "Not paired"
        case .pairedSettingUp: return "Paired, setting up…"
        case .pairedConnecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .updateAvailable: return "Update available"
        case .handedOffToDashboard: return "Paired — continue in the dashboard"
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
