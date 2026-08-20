import XCTest
@testable import SDDOrchestratorWorkerCore

final class CodingAgentDetectorTests: XCTestCase {
    private func failingResult() -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: "not found", timedOut: false)
    }

    // MARK: - Found one (via a common install path)

    func test_detect_claudeAtCommonPath_codexNowhere_findsOnlyClaude() {
        let checker = FakeExecutableChecker(executablePaths: ["/usr/local/bin/claude"])
        let runner = FakeCommandRunner(result: failingResult())

        let detected = CodingAgentDetector.detect(executableChecker: checker, commandRunner: runner)

        XCTAssertEqual(detected, [DetectedAgent(adapter: "claude_code", executablePath: "/usr/local/bin/claude")])
    }

    func test_detect_codexAtHomebrewPath_claudeNowhere_findsOnlyCodex() {
        let checker = FakeExecutableChecker(executablePaths: ["/opt/homebrew/bin/codex"])
        let runner = FakeCommandRunner(result: failingResult())

        let detected = CodingAgentDetector.detect(executableChecker: checker, commandRunner: runner)

        XCTAssertEqual(detected, [DetectedAgent(adapter: "codex", executablePath: "/opt/homebrew/bin/codex")])
    }

    // MARK: - Found via `which` fallback (no common path hit)

    func test_detect_neitherAtACommonPath_resolvesBothViaWhich_findsBoth() {
        let checker = FakeExecutableChecker(executablePaths: [])
        let runner = FakeWhichCommandRunner(paths: [
            "claude": "/usr/bin/claude",
            "codex": "/usr/bin/codex"
        ])

        let detected = CodingAgentDetector.detect(executableChecker: checker, commandRunner: runner)

        XCTAssertEqual(detected, [
            DetectedAgent(adapter: "claude_code", executablePath: "/usr/bin/claude"),
            DetectedAgent(adapter: "codex", executablePath: "/usr/bin/codex")
        ])
    }

    // MARK: - Found none

    func test_detect_neitherAtACommonPathNorViaWhich_returnsEmpty() {
        let checker = FakeExecutableChecker(executablePaths: [])
        let runner = FakeCommandRunner(result: failingResult())

        let detected = CodingAgentDetector.detect(executableChecker: checker, commandRunner: runner)

        XCTAssertTrue(detected.isEmpty)
    }

    // MARK: - Common-path hit takes precedence over shelling out to `which`

    func test_detect_commonPathFound_doesNotShellOutForThatAgent() {
        let checker = FakeExecutableChecker(executablePaths: ["/opt/homebrew/bin/claude", "/opt/homebrew/bin/codex"])
        let runner = FakeCommandRunner(result: CommandResult(exitCode: 0, standardOutput: "/should/not/be/used", standardError: "", timedOut: false))

        let detected = CodingAgentDetector.detect(executableChecker: checker, commandRunner: runner)

        XCTAssertEqual(detected.count, 2)
        XCTAssertEqual(runner.callCount, 0, "a common-path hit must skip the which shell-out entirely")
    }
}
