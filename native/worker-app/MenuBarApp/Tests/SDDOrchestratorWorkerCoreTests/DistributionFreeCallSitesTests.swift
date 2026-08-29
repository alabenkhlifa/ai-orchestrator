import Foundation
import XCTest

/// [specs/43 Task 5, AC-05] The guard that keeps this slice from being
/// undone one call site at a time.
///
/// The release's start script still offers `rpc`, deliberately: it is useful
/// for debugging on an unmanaged machine, so the capability stays and only
/// the calling stops. Nothing about that arrangement stops someone adding a
/// sixth `rpc` call later and reintroducing a dependency on Erlang
/// distribution, which a managed Mac's firewall refuses. Review is not a
/// control. This is.
///
/// Scope: the app's own Swift sources, both targets, discovered by walking
/// `Sources/` rather than from a list a new file would not be on. The test
/// sources are deliberately outside the scan — they name `rpc` in prose and
/// in `FakeWorkerRPCCommandRunner`, and the positive control below has to be
/// allowed to hold a matching literal.
final class DistributionFreeCallSitesTests: XCTestCase {
    /// An invocation of the release's `rpc` command: an argument array whose
    /// first element is the literal `"rpc"`. Matching the argument shape
    /// rather than the bare word is what keeps this honest — `rpc` appears
    /// in comments and in type names, and a guard that trips on those would
    /// be turned off within a week.
    private static let rpcInvocation = try! NSRegularExpression(
        pattern: #"\[\s*"rpc"\s*[,\]]"#
    )

    func test_noAppSourceInvokesTheReleaseSRPCCommand() throws {
        let sources = try swiftSources()

        // A scan that finds nothing to check passes for the wrong reason.
        // Both targets must be there, and each must have real files in it.
        XCTAssertGreaterThan(
            sources.count,
            20,
            "expected the whole app's Swift sources; the scan found only \(sources.count) files"
        )

        var offenders: [String] = []

        for url in sources {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)

            if Self.rpcInvocation.firstMatch(in: contents, range: range) != nil {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertEqual(
            offenders,
            [],
            """
            These sources invoke the embedded release's `rpc` command, which needs Erlang \
            distribution and fails on a Mac whose firewall blocks incoming epmd: \
            \(offenders.joined(separator: ", ")). Read state with `bin/worker eval` or a file, \
            write state as a file, and control the release with a signal. See \
            specs/43-distribution-free-worker-control.
            """
        )
    }

    /// Proves the matcher above can actually fail, without depending on the
    /// repository containing an offender. A guard nobody has watched trip is
    /// a guard nobody should trust.
    func test_theMatcherCatchesAnRPCInvocationAndIgnoresMereProse() {
        XCTAssertTrue(matches(#"runner.run(executable: path, arguments: ["rpc", "System.stop()"])"#))
        XCTAssertTrue(matches(#"let arguments = ["rpc"]"#))
        XCTAssertTrue(matches("let arguments = [\n    \"rpc\",\n    expression\n]"))

        XCTAssertFalse(matches("/// shells out to bin/worker rpc for the status"))
        XCTAssertFalse(matches("final class FakeWorkerRPCCommandRunner: CommandRunning {"))
        XCTAssertFalse(matches(#"arguments: ["eval", expression]"#))
        XCTAssertFalse(matches(#"XCTAssertFalse(everythingRun.contains("rpc"))"#))
    }

    // MARK: - Helpers

    private func matches(_ source: String) -> Bool {
        let range = NSRange(source.startIndex..., in: source)
        return Self.rpcInvocation.firstMatch(in: source, range: range) != nil
    }

    /// Every `.swift` file under the package's `Sources/`.
    ///
    /// Located from `#filePath`, not the working directory, which is the
    /// package root under `swift test` and something else again under
    /// Xcode. A missing directory throws rather than yielding an empty list,
    /// so a moved test file fails loudly instead of passing vacuously.
    private func swiftSources() throws -> [URL] {
        let testFile = URL(fileURLWithPath: #filePath)
        // .../Tests/SDDOrchestratorWorkerCoreTests/<this file> -> package root.
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot.appendingPathComponent("Sources")

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: sourcesRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            XCTFail("cannot scan for rpc call sites: no Sources directory at \(sourcesRoot.path)")
            throw CocoaError(.fileNoSuchFile)
        }

        // Both targets, named rather than globbed, so a target quietly
        // dropped from the walk is a failure and not a silent gap.
        for target in ["SDDOrchestratorWorkerCore", "SDDOrchestratorWorkerApp"] {
            let targetRoot = sourcesRoot.appendingPathComponent(target)
            guard FileManager.default.fileExists(atPath: targetRoot.path) else {
                XCTFail("cannot scan for rpc call sites: no target directory at \(targetRoot.path)")
                throw CocoaError(.fileNoSuchFile)
            }
        }

        guard let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) else {
            XCTFail("cannot scan for rpc call sites: \(sourcesRoot.path) is not enumerable")
            throw CocoaError(.fileReadUnknown)
        }

        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}
