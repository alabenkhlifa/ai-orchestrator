import XCTest
@testable import SDDOrchestratorWorkerCore

final class PairingFlowControllerTests: XCTestCase {
    private let dashboardURL = URL(string: "http://localhost:4000")!

    private let selfReport = WorkerSelfReport(
        osFamily: "macos",
        osMajor: "15",
        protocolVersion: "1",
        appVersion: "1.2.3"
    )

    private let successBody = """
    {
      "credential": "worker-id-123.secret-abc",
      "worker": {
        "id": "worker-id-123",
        "device_workspace_id": "ws-456",
        "os_family": "macos",
        "os_major": "15",
        "protocol_version": "1",
        "app_version": "1.2.3",
        "state": "active"
      }
    }
    """.data(using: .utf8)!

    private func makeController(
        poster: FakePairingHTTPPoster,
        coordinator: FakePostPairingSetupCoordinator,
        states: StateRecorder
    ) -> PairingFlowController {
        PairingFlowController(
            dashboardURL: dashboardURL,
            selfReportProvider: { self.selfReport },
            httpPoster: poster,
            setupCoordinator: coordinator,
            scheduler: ImmediateScheduler(),
            onStateChange: { states.record($0) }
        )
    }

    /// Collects `PairingFlowController.State` transitions in call order —
    /// a plain class (not an array captured by a `@escaping` closure
    /// mutating a local `var`) so it can be shared cleanly across closures.
    private final class StateRecorder {
        private(set) var states: [PairingFlowController.State] = []
        func record(_ state: PairingFlowController.State) { states.append(state) }
    }

    // MARK: - AC-07: valid payload, 201 response

    func test_handle_validPayload_201Response_reachesSucceeded_andInvokesExtensionPointWithParsedData() {
        let poster = FakePairingHTTPPoster(data: successBody, response: httpResponse(statusCode: 201))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")

        XCTAssertEqual(states.states, [.inFlight, .succeeded])
        XCTAssertEqual(coordinator.callCount, 1)
        XCTAssertEqual(coordinator.lastCredential, "worker-id-123.secret-abc")
        XCTAssertEqual(coordinator.lastWorker?.id, "worker-id-123")
        XCTAssertEqual(coordinator.lastWorker?.deviceWorkspaceID, "ws-456")
        XCTAssertEqual(coordinator.lastProjectID, "proj-789")
    }

    func test_handle_validPayload_postsToWorkerPairingsUnderTheDashboardURL_withCodeAndSelfReport() {
        let poster = FakePairingHTTPPoster(data: successBody, response: httpResponse(statusCode: 201))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")

        XCTAssertEqual(poster.callCount, 1)
        XCTAssertEqual(poster.lastURL, dashboardURL.appendingPathComponent("worker_pairings"))
        XCTAssertEqual(
            poster.lastJSONObject,
            [
                "code": "abc.secret",
                "os_family": "macos",
                "os_major": "15",
                "protocol_version": "1",
                "app_version": "1.2.3"
            ]
        )
    }

    // MARK: - AC-08: expired/used/unknown code -> 403

    func test_handle_validPayload_403Response_reachesFailed_andNeverInvokesExtensionPoint() {
        let refusalBody = #"{"error": "refused"}"#.data(using: .utf8)!
        let poster = FakePairingHTTPPoster(data: refusalBody, response: httpResponse(statusCode: 403))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "sddworker://pair?code=already.used&project_id=proj-789")

        XCTAssertEqual(states.states.count, 2)
        XCTAssertEqual(states.states.first, .inFlight)
        guard case .failed = states.states.last else {
            return XCTFail("expected the final state to be .failed, got \(String(describing: states.states.last))")
        }
        XCTAssertEqual(coordinator.callCount, 0)
    }

    // MARK: - AC-08: transport/network failure

    func test_handle_validPayload_transportFailure_reachesFailed_andNeverInvokesExtensionPoint() {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "timed out" }
        }

        let poster = FakePairingHTTPPoster(data: nil, response: nil, error: FakeError())
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")

        guard case .failed(let detail) = states.states.last else {
            return XCTFail("expected the final state to be .failed, got \(String(describing: states.states.last))")
        }
        XCTAssertTrue(detail.contains("timed out"))
        XCTAssertEqual(coordinator.callCount, 0)
    }

    // MARK: - AC-08: malformed payload (never even reaches the network)

    func test_handle_malformedPayload_reachesFailed_withoutPostingOrInvokingExtensionPoint() {
        let poster = FakePairingHTTPPoster(data: successBody, response: httpResponse(statusCode: 201))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "sddworker://pair?code=abc.secret") // missing project_id

        XCTAssertEqual(states.states.count, 1)
        guard case .failed = states.states.first else {
            return XCTFail("expected .failed for a malformed payload, got \(String(describing: states.states.first))")
        }
        XCTAssertEqual(poster.callCount, 0)
        XCTAssertEqual(coordinator.callCount, 0)
    }

    func test_handle_nilURLString_reachesFailed_withoutCrashing() {
        let poster = FakePairingHTTPPoster(data: successBody, response: httpResponse(statusCode: 201))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: nil)

        guard case .failed = states.states.first else {
            return XCTFail("expected .failed for a nil URL string, got \(String(describing: states.states.first))")
        }
        XCTAssertEqual(poster.callCount, 0)
    }

    func test_handle_unparsableURLString_reachesFailed_withoutCrashing() {
        let poster = FakePairingHTTPPoster(data: successBody, response: httpResponse(statusCode: 201))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "")

        guard case .failed = states.states.first else {
            return XCTFail("expected .failed for an empty URL string, got \(String(describing: states.states.first))")
        }
        XCTAssertEqual(poster.callCount, 0)
    }

    // MARK: - Duplicate/replay safety (point 6)

    func test_handle_calledAgainWhileSucceeded_doesNotPostASecondTime() {
        let poster = FakePairingHTTPPoster(data: successBody, response: httpResponse(statusCode: 201))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")
        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")

        XCTAssertEqual(poster.callCount, 1)
        XCTAssertEqual(coordinator.callCount, 1)
    }

    func test_handle_calledAgainAfterFailure_isAllowedToRetry_andPostsAgain() {
        let refusalBody = #"{"error": "refused"}"#.data(using: .utf8)!
        let poster = FakePairingHTTPPoster(data: refusalBody, response: httpResponse(statusCode: 403))
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = makeController(poster: poster, coordinator: coordinator, states: states)

        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")
        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")

        XCTAssertEqual(poster.callCount, 2)
    }

    /// A `PairingHTTPPosting` fake that captures its completion instead of
    /// invoking it, so the test can hold the "request" open and prove a
    /// second `handle(urlString:)` received while genuinely in flight does
    /// not fire a second concurrent POST — see this task's point 6.
    private final class HoldingPairingHTTPPoster: PairingHTTPPosting {
        private(set) var callCount = 0
        private var pendingCompletion: ((Data?, URLResponse?, Error?) -> Void)?

        func post(url: URL, jsonObject: [String: String], completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
            callCount += 1
            pendingCompletion = completion
        }

        func resolve(data: Data?, response: URLResponse?, error: Error?) {
            pendingCompletion?(data, response, error)
        }
    }

    func test_handle_calledAgainWhileGenuinelyInFlight_doesNotFireASecondConcurrentPost() {
        let poster = HoldingPairingHTTPPoster()
        let coordinator = FakePostPairingSetupCoordinator()
        let states = StateRecorder()
        let controller = PairingFlowController(
            dashboardURL: dashboardURL,
            selfReportProvider: { self.selfReport },
            httpPoster: poster,
            setupCoordinator: coordinator,
            scheduler: ImmediateScheduler(),
            onStateChange: { states.record($0) }
        )

        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")
        XCTAssertEqual(poster.callCount, 1, "the first call must have posted and still be awaiting a response")

        controller.handle(urlString: "sddworker://pair?code=abc.secret&project_id=proj-789")
        XCTAssertEqual(poster.callCount, 1, "a second call arriving while the first is in flight must not post again")

        poster.resolve(data: successBody, response: httpResponse(statusCode: 201), error: nil)

        XCTAssertEqual(states.states, [.inFlight, .succeeded])
        XCTAssertEqual(coordinator.callCount, 1)
    }
}
