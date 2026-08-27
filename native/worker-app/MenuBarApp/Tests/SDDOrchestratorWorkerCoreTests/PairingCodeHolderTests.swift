import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/38-worker-initiated-pairing Task 5 proof.
///
/// A person copies whatever the menu bar shows, so what it shows must be
/// something the dashboard still accepts. These prove the app asks for a code
/// when it has none, replaces one before it expires, never keeps the replaced
/// one, and says it cannot reach the control plane rather than offering a stale
/// code that would be refused.
final class PairingCodeHolderTests: XCTestCase {
    private let controlPlane = URL(string: "http://localhost:4000")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func issued(_ code: String, expiresIn seconds: TimeInterval) -> Data {
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
        return Data(#"{"code":"\#(code)","expires_at":"\#(expiry)"}"#.utf8)
    }

    private func holder(
        data: Data?,
        status: Int = 201,
        error: Error? = nil
    ) -> (PairingCodeHolder, FakePairingHTTPPoster) {
        let poster = FakePairingHTTPPoster(
            data: data,
            response: error == nil ? httpResponse(statusCode: status) : nil,
            error: error
        )

        return (PairingCodeHolder(poster: poster, controlPlaneURL: controlPlane), poster)
    }

    // MARK: - Acquiring (AC-01)

    func testAsksForACodeWhenItHasNone() {
        let (subject, poster) = holder(data: issued("attempt.secret", expiresIn: 600))

        subject.refreshIfNeeded(now: now)

        XCTAssertEqual(poster.callCount, 1)
        XCTAssertEqual(subject.currentCode?.value, "attempt.secret")
    }

    func testAsksTheIssuanceEndpointAndSendsNothingWithIt() {
        let (subject, poster) = holder(data: issued("attempt.secret", expiresIn: 600))

        subject.refreshIfNeeded(now: now)

        XCTAssertEqual(poster.lastURL?.path, "/pairing_codes")
        // The app names no workspace, project, identity, or secret. It has none.
        XCTAssertEqual(poster.lastJSONObject, [:])
    }

    func testDoesNotAskAgainWhileTheHeldCodeIsStillGood() {
        let (subject, poster) = holder(data: issued("attempt.secret", expiresIn: 600))

        subject.refreshIfNeeded(now: now)
        subject.refreshIfNeeded(now: now.addingTimeInterval(60))
        subject.refreshIfNeeded(now: now.addingTimeInterval(120))

        XCTAssertEqual(poster.callCount, 1)
    }

    // MARK: - Replacing before expiry (AC-07)

    func testReplacesTheCodeBeforeItExpires() {
        let (subject, poster) = holder(data: issued("first.secret", expiresIn: 600))

        subject.refreshIfNeeded(now: now)
        XCTAssertEqual(subject.currentCode?.value, "first.secret")

        // Inside the refresh margin: a person copying now could otherwise paste
        // something the dashboard has already stopped accepting.
        subject.refreshIfNeeded(now: now.addingTimeInterval(600 - 30))

        XCTAssertEqual(poster.callCount, 2)
    }

    func testKeepsOnlyTheReplacement() {
        let poster = ReplayingPoster(bodies: [
            issued("first.secret", expiresIn: 600),
            issued("second.secret", expiresIn: 1_200)
        ])

        let subject = PairingCodeHolder(poster: poster, controlPlaneURL: controlPlane)

        subject.refreshIfNeeded(now: now)
        subject.refreshIfNeeded(now: now.addingTimeInterval(600 - 30))

        XCTAssertEqual(subject.currentCode?.value, "second.secret")
    }

    func testAnExpiredCodeIsNeverOffered() {
        let (subject, _) = holder(data: issued("stale.secret", expiresIn: -1))

        subject.refreshIfNeeded(now: now)

        // It was fetched already expired, so the next check replaces it rather
        // than showing it.
        XCTAssertTrue(subject.currentCode?.needsReplacing(now: now, margin: 60) ?? false)
    }

    // MARK: - An unreachable control plane

    func testATransportFailureReportsUnreachableRatherThanACode() {
        let failure = NSError(domain: "test", code: -1_009)
        let (subject, _) = holder(data: nil, error: failure)

        subject.refreshIfNeeded(now: now)

        XCTAssertEqual(subject.state, .unreachable)
        XCTAssertNil(subject.currentCode)
    }

    func testARefusalReportsUnreachableRatherThanACode() {
        let (subject, _) = holder(data: nil, status: 429)

        subject.refreshIfNeeded(now: now)

        XCTAssertEqual(subject.state, .unreachable)
        XCTAssertNil(subject.currentCode)
    }

    func testAFailureDropsTheCodeInsteadOfLeavingAStaleOneOnDisplay() {
        let poster = ReplayingPoster(bodies: [issued("first.secret", expiresIn: 600), nil])

        let subject = PairingCodeHolder(poster: poster, controlPlaneURL: controlPlane)

        subject.refreshIfNeeded(now: now)
        XCTAssertEqual(subject.currentCode?.value, "first.secret")

        subject.refreshIfNeeded(now: now.addingTimeInterval(600 - 30))

        XCTAssertNil(subject.currentCode)
        XCTAssertEqual(subject.state, .unreachable)
    }

    func testAnUnreadableBodyIsTreatedAsUnreachable() {
        let (subject, _) = holder(data: Data(#"{"code":""}"#.utf8))

        subject.refreshIfNeeded(now: now)

        XCTAssertEqual(subject.state, .unreachable)
    }

    // MARK: - Discarding

    func testDiscardingClearsWhatIsHeld() {
        let (subject, _) = holder(data: issued("attempt.secret", expiresIn: 600))

        subject.refreshIfNeeded(now: now)
        subject.discard()

        XCTAssertNil(subject.currentCode)
        XCTAssertEqual(subject.state, .none)
    }
}

/// Answers a different body per call, so a replacement can be distinguished
/// from the code it replaced.
private final class ReplayingPoster: PairingHTTPPosting {
    private var bodies: [Data?]

    init(bodies: [Data?]) {
        self.bodies = bodies
    }

    func post(
        url: URL,
        jsonObject: [String: String],
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        let body = bodies.isEmpty ? nil : bodies.removeFirst()

        if let body {
            completion(body, httpResponse(url: url, statusCode: 201), nil)
        } else {
            completion(nil, nil, NSError(domain: "test", code: -1_009))
        }
    }
}
