/// Whether a worker configuration/credential is stored, as reported by
/// `SddOrchestrator.Worker.Configuration.load/1` (see `PairingStatusChecker`).
public enum PairingStatus: Equatable, Sendable {
    case paired
    case notPaired
    /// The query itself failed (process launch error, timeout, unparseable
    /// output). Never treated as "paired" — see
    /// `WorkerStatus.from(pairing:connection:)`.
    case unknown
}
