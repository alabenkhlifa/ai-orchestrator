import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/38-worker-initiated-pairing Task 6 proof.
///
/// The status line is what a person reads and what they click. These prove the
/// unpaired states say the right thing, that clicking copies the whole code and
/// says so, that nothing reaches the clipboard without a click, and that a
/// paired worker is never offered a code it has no use for.
final class PairingCodeMenuTests: XCTestCase {
    private let code = PairingCode(
        value: "3f2a7c11-9d84-4b0e-a1f6-7c2b5d908e43.qX7mR2vK9pL4nT8wY1sD6fG3hJ0kZ5cB",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_600)
    )

    // MARK: - What the unpaired menu says (AC-02)

    func testAHeldCodeInvitesTheClickThatCopiesIt() {
        let line = PairingCodeMenu.statusLine(status: .notPaired, codeState: .held(code))

        XCTAssertEqual(line.title, "Not paired — click to copy your pairing code")
        XCTAssertTrue(line.isCopyAction)
        XCTAssertEqual(line.copyableCode, code.value)
    }

    func testTheLineConfirmsAfterCopying() {
        let line = PairingCodeMenu.statusLine(
            status: .notPaired,
            codeState: .held(code),
            justCopied: true
        )

        XCTAssertEqual(line.title, "Pairing code copied — paste it in the dashboard")
        // Still copyable, so a person who missed the clipboard can click again.
        XCTAssertTrue(line.isCopyAction)
    }

    func testAnUnreachableControlPlaneIsNamedRatherThanSilent() {
        let line = PairingCodeMenu.statusLine(status: .notPaired, codeState: .unreachable)

        XCTAssertEqual(line.title, "Not paired — can't reach the control plane")
        XCTAssertFalse(line.isCopyAction)
    }

    func testNoCodeYetReadsAsTheOrdinaryUnpairedLine() {
        let line = PairingCodeMenu.statusLine(status: .notPaired, codeState: .none)

        XCTAssertEqual(line.title, "Not paired")
        XCTAssertFalse(line.isCopyAction)
    }

    // MARK: - A paired worker is never offered a code

    func testEveryPairedStatusIsAPlainStatusLine() {
        let paired: [WorkerStatus] = [
            .pairedSettingUp, .pairedConnecting, .connected, .disconnected, .updateAvailable,
            .handedOffToDashboard
        ]

        for status in paired {
            let line = PairingCodeMenu.statusLine(status: status, codeState: .held(code))

            XCTAssertEqual(line.title, status.menuStatusLine)
            XCTAssertFalse(line.isCopyAction, "\(status) must not offer a pairing code")
        }
    }

    func testTheHandOffStateSaysWhereToContinueAndNeverClaimsASetup() {
        let line = PairingCodeMenu.statusLine(
            status: .handedOffToDashboard,
            codeState: .none
        )

        XCTAssertEqual(line.title, "Paired — continue in the dashboard")
        XCTAssertFalse(line.isCopyAction)
        // The wording a real install got stuck on. It must not come back.
        XCTAssertNotEqual(line.title, "Paired, setting up…")
    }

    // MARK: - The clipboard is only ever written on purpose

    func testBuildingTheLineNeverTouchesTheClipboard() {
        let pasteboard = FakePasteboard()
        _ = PairingCodeCopier(pasteboard: pasteboard)

        _ = PairingCodeMenu.statusLine(status: .notPaired, codeState: .held(code))
        _ = PairingCodeMenu.statusLine(status: .notPaired, codeState: .held(code), justCopied: true)

        XCTAssertTrue(pasteboard.writes.isEmpty)
    }

    func testCopyingWritesTheWholeCodeOnce() {
        let pasteboard = FakePasteboard()
        let copier = PairingCodeCopier(pasteboard: pasteboard)

        XCTAssertTrue(copier.copy(from: .held(code)))

        XCTAssertEqual(pasteboard.writes, [code.value])
        // The whole thing, not a truncated preview.
        XCTAssertEqual(pasteboard.writes.first?.count, code.value.count)
    }

    func testCopyingWithNothingHeldWritesNothingAndSaysSo() {
        let pasteboard = FakePasteboard()
        let copier = PairingCodeCopier(pasteboard: pasteboard)

        XCTAssertFalse(copier.copy(from: .none))
        XCTAssertFalse(copier.copy(from: .unreachable))

        XCTAssertTrue(pasteboard.writes.isEmpty)
    }
}

/// Records what would have reached the clipboard.
private final class FakePasteboard: Pasteboarding {
    private(set) var writes: [String] = []

    func write(_ string: String) {
        writes.append(string)
    }
}
