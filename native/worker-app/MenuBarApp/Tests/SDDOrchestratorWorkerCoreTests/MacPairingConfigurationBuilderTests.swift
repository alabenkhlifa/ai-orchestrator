import XCTest
@testable import SDDOrchestratorWorkerCore

/// specs/39 Task 2 (AC-01) proof: what a menu-bar redemption writes names
/// no project.
final class MacPairingConfigurationBuilderTests: XCTestCase {
    func test_buildJSONObject_mapsEveryFieldByTheExactKeyNameConfigurationExpects() {
        let jsonObject = MacPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: "http://localhost:4000",
            deviceWorkspaceID: "ws-1",
            credential: "worker-1.secret",
            agentAdapter: "claude_code",
            agentExecutable: "/usr/local/bin/claude",
            workerID: "worker-1"
        )

        XCTAssertEqual(jsonObject, [
            "control_plane_address": "http://localhost:4000",
            "device_workspace_id": "ws-1",
            "worker_credential": "worker-1.secret",
            "agent_adapter": "claude_code",
            "agent_executable": "/usr/local/bin/claude",
            "worker_id": "worker-1"
        ])
    }

    func test_buildJSONObject_hasExactlyTheSixRequiredKeys_noMoreNoFewer() {
        let jsonObject = MacPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: "a",
            deviceWorkspaceID: "b",
            credential: "c",
            agentAdapter: "d",
            agentExecutable: "e",
            workerID: "f"
        )

        // Exactly `Configuration`'s `@required_keys`, as specs/39 Task 1
        // narrowed them.
        XCTAssertEqual(Set(jsonObject.keys), [
            "control_plane_address",
            "device_workspace_id",
            "worker_credential",
            "agent_adapter",
            "agent_executable",
            "worker_id"
        ])
    }

    func test_buildJSONObject_omitsProjectAndWorkspaceRootEntirely_ratherThanSendingThemEmpty() {
        let jsonObject = MacPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: "http://localhost:4000",
            deviceWorkspaceID: "ws-1",
            credential: "worker-1.secret",
            agentAdapter: "claude_code",
            agentExecutable: "/usr/local/bin/claude",
            workerID: "worker-1"
        )

        // Absent keys, not empty values. `Configuration` decodes an absent
        // key to `nil`; `""` would instead be a project id of `""`, a
        // value this worker was never issued.
        XCTAssertNil(jsonObject["project_id"])
        XCTAssertNil(jsonObject["workspace_root"])
        XCTAssertFalse(jsonObject.keys.contains("project_id"))
        XCTAssertFalse(jsonObject.keys.contains("workspace_root"))
    }

    func test_buildJSONObject_serializesWithoutAnyProjectOrWorkspaceRootKey() {
        let jsonObject = MacPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: "http://localhost:4000",
            deviceWorkspaceID: "ws-1",
            credential: "worker-1.secret",
            agentAdapter: "claude_code",
            agentExecutable: "/usr/local/bin/claude",
            workerID: "worker-1"
        )

        let data = try? JSONSerialization.data(withJSONObject: jsonObject)
        let decoded = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        guard let decoded else { return XCTFail("expected the built object to serialize as JSON") }

        // The shape `bin/worker rpc` actually reads: `Map.fetch!` would
        // raise on a missing required field, and neither optional key is
        // there for `Jason` to decode as a `null`.
        XCTAssertEqual(Set(decoded.keys), [
            "control_plane_address",
            "device_workspace_id",
            "worker_credential",
            "agent_adapter",
            "agent_executable",
            "worker_id"
        ])
    }
}
