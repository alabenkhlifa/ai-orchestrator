/// The menu-bar app's own top-level status, shown as the disabled header
/// line of the status-item menu.
///
/// `.notPaired` and `.pairedSettingUp` are fully correct as of specs/36
/// Task 4 (AC-03/04/05 from its Task 2; AC-07/AC-08 from its Task 4).
/// `.pairedConnecting`, `.connected`, and `.disconnected` become real once
/// a `Configuration` is stored; `.updateAvailable` becomes reachable as of
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
