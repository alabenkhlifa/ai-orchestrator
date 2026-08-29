import XCTest
@testable import SDDOrchestratorWorkerCore

/// [specs/42 Task 1, AC-01/AC-02] The dot beside the status line: every state
/// answers exactly one, and states of the same kind answer the same one.
final class StatusIndicatorTests: XCTestCase {
    // MARK: - AC-01: exactly one indicator, for every state

    func test_everyWorkerStatusAnswersOneIndicator() {
        XCTAssertEqual(Self.allCases.count, 7, "all seven WorkerStatus cases must be listed here")

        for status in Self.allCases {
            XCTAssertEqual(
                status.indicator,
                Self.expectedIndicator(for: status),
                "\(status) must answer the indicator this test pins for it"
            )
        }
    }

    func test_everyIndicatorKindIsReachable() {
        // A kind no status produces is a colour nobody can ever see, which
        // would mean the vocabulary and the states have drifted apart.
        let answered = Set(Self.allCases.map(\.indicator))

        for indicator in StatusIndicator.allCases {
            XCTAssertTrue(answered.contains(indicator), "no WorkerStatus answers \(indicator)")
        }
    }

    // MARK: - AC-02: one colour language

    func test_connected_answersTheHealthyKind() {
        XCTAssertEqual(WorkerStatus.connected.indicator, .healthy)
    }

    func test_disconnectedAndRefused_answerTheSameProblemKind() {
        // Two different things happened and the menu says which in words, but
        // the dot is one signal: the worker is not attached.
        XCTAssertEqual(WorkerStatus.disconnected.indicator, .problem)
        XCTAssertEqual(WorkerStatus.connectionRefused.indicator, .problem)
        XCTAssertEqual(WorkerStatus.disconnected.indicator, WorkerStatus.connectionRefused.indicator)
    }

    func test_connectingAndSettingUp_answerTheSameInProgressKind() {
        XCTAssertEqual(WorkerStatus.pairedConnecting.indicator, .inProgress)
        XCTAssertEqual(WorkerStatus.pairedSettingUp.indicator, .inProgress)
        XCTAssertEqual(WorkerStatus.pairedConnecting.indicator, WorkerStatus.pairedSettingUp.indicator)
    }

    func test_inProgressIsNeverTheProblemOrHealthyKind() {
        // Work that finishes on its own must not read as a fault, and must
        // not claim the worker is attached before it is.
        XCTAssertNotEqual(WorkerStatus.pairedConnecting.indicator, .problem)
        XCTAssertNotEqual(WorkerStatus.pairedConnecting.indicator, .healthy)
        XCTAssertNotEqual(WorkerStatus.pairedSettingUp.indicator, .problem)
        XCTAssertNotEqual(WorkerStatus.pairedSettingUp.indicator, .healthy)
    }

    func test_notPaired_answersTheIdleKind() {
        // A fresh install is not broken.
        XCTAssertEqual(WorkerStatus.notPaired.indicator, .idle)
        XCTAssertNotEqual(WorkerStatus.notPaired.indicator, .problem)
    }

    func test_updateAvailable_answersItsOwnKind_notAHealthOne() {
        let indicator = WorkerStatus.updateAvailable.indicator

        XCTAssertEqual(indicator, .update)
        XCTAssertNotEqual(indicator, .healthy)
        XCTAssertNotEqual(indicator, .problem)
        XCTAssertNotEqual(indicator, .inProgress)
        XCTAssertNotEqual(indicator, .idle)
    }

    // MARK: - Fixtures

    private static let allCases: [WorkerStatus] = [
        .notPaired, .pairedSettingUp, .pairedConnecting, .connected, .connectionRefused,
        .disconnected, .updateAvailable
    ]

    /// The mapping restated independently of the production switch.
    ///
    /// Exhaustive on purpose: `WorkerStatus` is not `CaseIterable`, so this
    /// switch is the guard that an eighth state cannot slip through. Adding
    /// one stops this file compiling, and `swift test` fails, until someone
    /// decides which kind of state it is here as well as in production.
    private static func expectedIndicator(for status: WorkerStatus) -> StatusIndicator {
        switch status {
        case .connected: return .healthy
        case .disconnected: return .problem
        case .connectionRefused: return .problem
        case .pairedConnecting: return .inProgress
        case .pairedSettingUp: return .inProgress
        case .notPaired: return .idle
        case .updateAvailable: return .update
        }
    }
}
