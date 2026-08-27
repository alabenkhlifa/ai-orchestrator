import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/38-worker-initiated-pairing Task 8 proof.
///
/// This is the loop the slice was missing: without it the app fetched one code
/// at startup, never replaced it, and never tried to finish, so a code the
/// person pasted was never acted on. These prove each tick does the one thing
/// the current state calls for, and that a paired app stops.
final class PairingLoopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func code(expiresIn seconds: TimeInterval) -> PairingCode {
        PairingCode(value: "attempt.secret", expiresAt: now.addingTimeInterval(seconds))
    }

    // MARK: - Keeping a live code (AC-07)

    func testWithNoCodeItFetchesOne() {
        let action = PairingLoop.next(status: .notPaired, codeState: .none, now: now)

        XCTAssertEqual(action, .refreshCode)
    }

    func testAnUnreachableControlPlaneIsRetriedRatherThanGivenUpOn() {
        let action = PairingLoop.next(status: .notPaired, codeState: .unreachable, now: now)

        XCTAssertEqual(action, .refreshCode)
    }

    func testACodeNearingExpiryIsReplacedBeforeItIsUsed() {
        let action = PairingLoop.next(
            status: .notPaired,
            codeState: .held(code(expiresIn: 30)),
            now: now
        )

        // Replacing beats attempting: a person may be about to paste this one.
        XCTAssertEqual(action, .refreshCode)
    }

    // MARK: - Discovering that an owner redeemed it (AC-08)

    func testWithALiveCodeItTriesToFinish() {
        let action = PairingLoop.next(
            status: .notPaired,
            codeState: .held(code(expiresIn: 600)),
            now: now
        )

        XCTAssertEqual(action, .attemptCompletion("attempt.secret"))
    }

    func testItKeepsTryingAcrossTicksWhileNobodyHasRedeemedIt() {
        let held = PairingCodeState.held(code(expiresIn: 600))

        for elapsed in [0.0, 60.0, 120.0, 300.0] {
            let action = PairingLoop.next(
                status: .notPaired,
                codeState: held,
                now: now.addingTimeInterval(elapsed)
            )

            XCTAssertEqual(action, .attemptCompletion("attempt.secret"))
        }
    }

    // MARK: - A paired app stops

    func testEveryPairedStatusIdles() {
        let paired: [WorkerStatus] = [
            .pairedSettingUp, .pairedConnecting, .connected, .disconnected, .updateAvailable
        ]

        for status in paired {
            let action = PairingLoop.next(
                status: status,
                codeState: .held(code(expiresIn: 600)),
                now: now
            )

            XCTAssertEqual(action, .idle, "\(status) must not keep polling")
        }
    }

    func testAPairedAppIdlesEvenWithNoCodeHeld() {
        let action = PairingLoop.next(status: .connected, codeState: .none, now: now)

        XCTAssertEqual(action, .idle)
    }
}
