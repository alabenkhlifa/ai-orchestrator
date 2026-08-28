/// The menu-bar app's own top-level status, shown as the disabled header
/// line of the status-item menu.
///
/// `.notPaired` and `.pairedSettingUp` are fully correct as of specs/36
/// Task 4 (AC-03/04/05 from its Task 2; AC-07/AC-08 from its Task 4).
/// `.pairedConnecting`, `.connected`, `.connectionRefused`, and
/// `.disconnected` become real once a `Configuration` is stored;
/// `.updateAvailable` becomes reachable as of
/// specs/36 Task 10 (appcast/updates — see `AppcastUpdateChecker`).
///
/// There is deliberately no separate "handed off to the dashboard" status.
/// specs/38 added one because a worker paired from the menu bar had no
/// project, `Worker.Configuration` required one, and this app had nothing
/// to store or finish. specs/39 Task 1 made a projectless configuration
/// valid and Task 2 stores it here, so a redeemed code now reaches
/// `.pairedSettingUp` like any other pairing does. Keeping a status that
/// tells the person to continue somewhere else would describe work this app
/// is doing itself.
public enum WorkerStatus: Equatable, Sendable {
    case notPaired
    /// A credential and worker identity were obtained from
    /// `POST /worker_pairings` — through the deep link (specs/36 Task 4,
    /// AC-07) or through a code the owner redeemed in the dashboard
    /// (specs/39 Task 2, AC-01) — but the setup that turns them into a
    /// stored `Configuration` has not finished. Distinct from both
    /// `.notPaired` (no credential at all) and
    /// `.pairedConnecting`/`.connected` (a stored configuration whose
    /// gateway connection this app is polling) — see
    /// `PostPairingSetupCoordinator` and `MacPairingRetention`.
    case pairedSettingUp
    /// Paired, and not attached to the control plane yet: either nothing has
    /// been observed in this launch (`GatewayConnectionState.unknown`) or the
    /// transport is up with the join still in flight
    /// (`GatewayConnectionState.connecting`). Both are honestly
    /// "Connecting…", and neither may read as connected — a websocket is not
    /// an attachment (specs/39 Task 7, AC-07).
    case pairedConnecting
    case connected
    /// [specs/39 Task 7, AC-08] The control plane refused the attachment.
    /// Named as a refusal rather than shown as a connection or folded into
    /// `.disconnected`: a refusal is answered the same way every time it is
    /// retried, so it is a different thing for a person to act on than a
    /// connection that dropped.
    case connectionRefused
    case disconnected
    /// [Task 10, AC-11/AC-12] Set once `AppcastUpdateChecker` has fetched a
    /// signed appcast entry, verified its signature, confirmed it reports a
    /// newer version than this running app, downloaded the artifact, and
    /// verified its checksum — see `AppDelegate`'s `AppcastUpdateChecker`
    /// wiring. Never set on an unverified or not-newer entry.
    case updateAvailable

    /// The status line shown at the top of the menu.
    public var menuStatusLine: String {
        switch self {
        case .notPaired: return "Not paired"
        case .pairedSettingUp: return "Paired, setting up…"
        case .pairedConnecting: return "Connecting…"
        case .connected: return "Connected"
        case .connectionRefused: return "Paired, but the control plane refused the connection"
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
            case .refused: return .connectionRefused
            case .disconnected: return .disconnected
            // A connected transport the control plane has not attached is
            // still connecting, never connected.
            case .connecting, .unknown: return .pairedConnecting
            }
        }
    }
}
