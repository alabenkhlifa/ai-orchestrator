import Foundation

/// Drives the whole URL-scheme pairing handoff (specs/36 Task 4, AC-07 /
/// AC-08) from a raw Apple Event direct-object string through to either the
/// `PostPairingSetupCoordinator` extension point or a reported failure.
///
/// Kept in `SDDOrchestratorWorkerCore` (not `AppDelegate`) so the whole
/// decision — URL parsing, request building, response handling, and the
/// duplicate/replay guard — is unit-testable against fakes, matching this
/// package's existing "thin AppKit glue over a testable Core" split.
public final class PairingFlowController {
    public enum State: Equatable, Sendable {
        case inFlight
        case succeeded
        /// A `403` refusal, a transport failure, or a malformed pairing
        /// URL — `detail` is a human-readable reason suitable for display,
        /// never the raw pairing code or credential.
        case failed(detail: String)
    }

    private let dashboardURL: URL
    private let selfReportProvider: () -> WorkerSelfReport
    private let httpPoster: PairingHTTPPosting
    private let setupCoordinator: PostPairingSetupCoordinator
    private let scheduler: PairingWorkScheduling
    private let onStateChange: (State) -> Void

    private let lock = NSLock()
    private var sessionState: State?

    public init(
        dashboardURL: URL,
        selfReportProvider: @escaping () -> WorkerSelfReport,
        httpPoster: PairingHTTPPosting,
        setupCoordinator: PostPairingSetupCoordinator,
        scheduler: PairingWorkScheduling = DispatchQueueScheduler(),
        onStateChange: @escaping (State) -> Void
    ) {
        self.dashboardURL = dashboardURL
        self.selfReportProvider = selfReportProvider
        self.httpPoster = httpPoster
        self.setupCoordinator = setupCoordinator
        self.scheduler = scheduler
        self.onStateChange = onStateChange
    }

    /// `urlString` is the Apple Event direct object's raw string value
    /// (`NSAppleEventDescriptor.paramDescriptor(forKeyword: keyDirectObject)?.stringValue`)
    /// — `nil` or unparsable-as-a-`URL` is treated exactly like a
    /// URL that parses but does not match the `sddworker://pair?...` shape
    /// (AC-08): reported as a failure, never a crash.
    ///
    /// A second call received while one attempt is still in flight, or after
    /// one has already succeeded this session, is ignored outright (no
    /// second concurrent POST, no menu flicker) — see this task's point 6.
    /// A call after a *failed* attempt is allowed to retry.
    public func handle(urlString: String?) {
        guard
            let urlString,
            let url = URL(string: urlString),
            let payload = PairingURLPayloadParser.parse(url)
        else {
            transition(to: .failed(detail: "malformed pairing link"))
            return
        }

        lock.lock()
        switch sessionState {
        case .inFlight, .succeeded:
            lock.unlock()
            return
        case .failed, .none:
            sessionState = .inFlight
            lock.unlock()
        }

        onStateChange(.inFlight)

        scheduler.schedule { [weak self] in
            self?.completePairing(payload: payload)
        }
    }

    private func completePairing(payload: PairingURLPayload) {
        let selfReport = selfReportProvider()
        let endpoint = dashboardURL.appendingPathComponent("worker_pairings")
        let body = PairingCompletionRequestBody.build(code: payload.code, selfReport: selfReport)

        httpPoster.post(url: endpoint, jsonObject: body) { [weak self] data, response, error in
            guard let self else { return }

            let statusCode = (response as? HTTPURLResponse)?.statusCode
            switch PairingCompletionResponseParser.parse(statusCode: statusCode, data: data, transportError: error) {
            case .success(let success):
                self.transition(to: .succeeded)
                self.setupCoordinator.beginPostPairingSetup(
                    credential: success.credential,
                    worker: success.worker,
                    projectID: payload.projectID
                )

            case .failure(let reason):
                self.transition(to: .failed(detail: reason))
            }
        }
    }

    private func transition(to state: State) {
        lock.lock()
        sessionState = state
        lock.unlock()
        onStateChange(state)
    }
}
