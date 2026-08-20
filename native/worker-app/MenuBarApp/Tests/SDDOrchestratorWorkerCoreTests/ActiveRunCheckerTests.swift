import XCTest
@testable import SDDOrchestratorWorkerCore

final class ActiveRunCheckerTests: XCTestCase {
    // MARK: - isActive(currentLifecycle:)

    func test_isActive_nilCurrentEntry_isNotActive() {
        XCTAssertFalse(ActiveRunChecker.isActive(currentLifecycle: nil))
    }

    func test_isActive_acceptedOrBlocked_isActive() {
        XCTAssertTrue(ActiveRunChecker.isActive(currentLifecycle: "accepted"))
        XCTAssertTrue(ActiveRunChecker.isActive(currentLifecycle: "blocked"))
    }

    func test_isActive_terminalLifecycles_areNotActive() {
        // Mirrors run_state.ex's own accepted/blocked-vs-terminal split.
        for lifecycle in ["canceled", "failed", "stopped", "verification_completed"] {
            XCTAssertFalse(
                ActiveRunChecker.isActive(currentLifecycle: lifecycle),
                "\(lifecycle) must not be treated as an active run"
            )
        }
    }

    func test_isActive_unrecognizedLifecycle_isNotActive() {
        // Defensive: an unrecognized string is not one of the two known
        // active states, so it is not active. run_state.ex itself would
        // never let an out-of-vocabulary value be stored.
        XCTAssertFalse(ActiveRunChecker.isActive(currentLifecycle: "some_future_state"))
    }

    // MARK: - shouldWarnBeforeQuit(queryResult:) — the AC-04/AC-05 decision

    func test_shouldWarnBeforeQuit_noCurrentEntry_doesNotWarn() {
        // AC-04: no run active -> stop immediately, no warning.
        XCTAssertFalse(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .success(currentLifecycle: nil)))
    }

    func test_shouldWarnBeforeQuit_acceptedOrBlocked_warns() {
        // AC-05: a run active -> warn before stopping.
        XCTAssertTrue(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .success(currentLifecycle: "accepted")))
        XCTAssertTrue(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .success(currentLifecycle: "blocked")))
    }

    func test_shouldWarnBeforeQuit_terminalLifecycle_doesNotWarn() {
        XCTAssertFalse(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .success(currentLifecycle: "stopped")))
        XCTAssertFalse(
            ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .success(currentLifecycle: "verification_completed"))
        )
    }

    func test_shouldWarnBeforeQuit_queryFailed_failsSafeAndWarns() {
        // Cannot prove no run is active, so must not silently stop the
        // process.
        XCTAssertTrue(ActiveRunChecker.shouldWarnBeforeQuit(queryResult: .queryFailed))
    }
}
