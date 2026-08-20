/// Last-known gateway connection state, as reported by
/// `SddOrchestrator.Worker.ConnectionStatus.status/0` (see
/// `ConnectionStatusQuerier`).
public enum GatewayConnectionState: Equatable, Sendable {
    case connected
    case disconnected
    /// Not yet observed in this VM instance, or the query itself failed.
    case unknown
}
