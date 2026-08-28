/// Last-known gateway connection state, as reported by
/// `SddOrchestrator.Worker.ConnectionStatus.status/0` (see
/// `ConnectionStatusQuerier`).
///
/// Connected means the control plane attached this worker, not merely that a
/// websocket opened (specs/39-mac-scoped-worker-connection Task 7). The two
/// in-between states exist so the app can tell those apart instead of
/// claiming a connection the control plane never made.
public enum GatewayConnectionState: Equatable, Sendable {
    /// The control plane accepted the join and attached this worker.
    case connected
    /// The transport is up and the join is in flight. Nothing is attached
    /// yet, so this is never shown as connected.
    case connecting
    /// The control plane refused the attachment.
    ///
    /// Carries no reason on purpose: the worker prints one atom on stdout
    /// (`Atom.to_string(status)`), so the reason never crosses this boundary
    /// and inventing a payload the parser cannot fill would be a lie. The
    /// refusal detail stays in the worker's own log, where it can be read
    /// without putting control-plane text in a menu line.
    case refused
    case disconnected
    /// Not yet observed in this VM instance, or the query itself failed.
    /// Distinct from `.connecting`, which is an observation.
    case unknown
}
