import XCTest
@testable import SDDOrchestratorWorkerCore

final class GatekeeperAssessorTests: XCTestCase {
    private let artifactURL = URL(fileURLWithPath: "/tmp/fake-update.dmg")

    private func result(exitCode: Int32, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: "", standardError: "", timedOut: timedOut)
    }

    func test_assess_exitCodeZero_isTrue() {
        let runner = FakeCommandRunner(result: result(exitCode: 0))

        XCTAssertTrue(GatekeeperAssessor.assess(artifactURL: artifactURL, runner: runner))
    }

    func test_assess_nonZeroExitCode_isFalse() {
        let runner = FakeCommandRunner(result: result(exitCode: 3))

        XCTAssertFalse(GatekeeperAssessor.assess(artifactURL: artifactURL, runner: runner))
    }

    func test_assess_timedOut_isFalseEvenWithExitCodeZero() {
        let runner = FakeCommandRunner(result: result(exitCode: 0, timedOut: true))

        XCTAssertFalse(GatekeeperAssessor.assess(artifactURL: artifactURL, runner: runner))
    }

    func test_assess_invokesSpctlAssessOpenAgainstTheArtifactPath() {
        let runner = FakeCommandRunner(result: result(exitCode: 0))

        _ = GatekeeperAssessor.assess(artifactURL: artifactURL, runner: runner)

        XCTAssertEqual(runner.lastExecutable, "/usr/sbin/spctl")
        XCTAssertEqual(runner.lastArguments, ["--assess", "--type", "open", artifactURL.path])
    }
}
