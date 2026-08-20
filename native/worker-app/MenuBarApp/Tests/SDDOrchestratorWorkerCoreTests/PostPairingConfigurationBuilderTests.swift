import XCTest
@testable import SDDOrchestratorWorkerCore

final class PostPairingConfigurationBuilderTests: XCTestCase {
    func test_buildJSONObject_mapsEveryFieldByTheExactKeyNameConfigurationExpects() {
        let jsonObject = PostPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: "http://localhost:4000",
            deviceWorkspaceID: "ws-1",
            credential: "worker-1.secret",
            agentAdapter: "claude_code",
            agentExecutable: "/usr/local/bin/claude",
            workspaceRoot: "/Users/dev/my repo",
            projectID: "proj-9",
            workerID: "worker-1"
        )

        XCTAssertEqual(jsonObject, [
            "control_plane_address": "http://localhost:4000",
            "device_workspace_id": "ws-1",
            "worker_credential": "worker-1.secret",
            "agent_adapter": "claude_code",
            "agent_executable": "/usr/local/bin/claude",
            "workspace_root": "/Users/dev/my repo",
            "project_id": "proj-9",
            "worker_id": "worker-1"
        ])
    }

    func test_buildJSONObject_hasExactlyTheEightEnforcedKeys_noMoreNoFewer() {
        let jsonObject = PostPairingConfigurationBuilder.buildJSONObject(
            controlPlaneAddress: "a",
            deviceWorkspaceID: "b",
            credential: "c",
            agentAdapter: "d",
            agentExecutable: "e",
            workspaceRoot: "f",
            projectID: "g",
            workerID: "h"
        )

        XCTAssertEqual(Set(jsonObject.keys), [
            "control_plane_address",
            "device_workspace_id",
            "worker_credential",
            "agent_adapter",
            "agent_executable",
            "workspace_root",
            "project_id",
            "worker_id"
        ])
    }
}
