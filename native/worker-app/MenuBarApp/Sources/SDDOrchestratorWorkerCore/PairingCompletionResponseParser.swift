import Foundation

/// The worker identity `POST /worker_pairings` returns on success, mirroring
/// `SddOrchestratorWeb.WorkerPairingController.completed/2`'s JSON shape.
public struct WorkerIdentity: Equatable, Sendable {
    public let id: String
    public let deviceWorkspaceID: String
    public let osFamily: String?
    public let osMajor: String?
    public let protocolVersion: String?
    public let appVersion: String?
    public let state: String?

    public init(
        id: String,
        deviceWorkspaceID: String,
        osFamily: String?,
        osMajor: String?,
        protocolVersion: String?,
        appVersion: String?,
        state: String?
    ) {
        self.id = id
        self.deviceWorkspaceID = deviceWorkspaceID
        self.osFamily = osFamily
        self.osMajor = osMajor
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.state = state
    }
}

public struct PairingCompletionSuccess: Equatable, Sendable {
    public let credential: String
    public let worker: WorkerIdentity

    public init(credential: String, worker: WorkerIdentity) {
        self.credential = credential
        self.worker = worker
    }
}

public enum PairingCompletionOutcome: Equatable, Sendable {
    case success(PairingCompletionSuccess)
    /// A human-readable reason: a `403` refusal, a transport-level failure
    /// (timeout, unreachable), or a malformed/unparseable response body.
    /// `SddOrchestratorWeb.WorkerPairingController` answers every specific
    /// refusal reason (expired/used/unknown/malformed code) identically by
    /// design, so this never distinguishes among them — see AC-18 there.
    case failure(String)
}

/// Turns one `POST /worker_pairings` response into a
/// `PairingCompletionOutcome`, without performing the network call itself —
/// kept pure so it is unit-testable against canned status/data/error
/// fixtures rather than a real request.
public enum PairingCompletionResponseParser {
    public static func parse(statusCode: Int?, data: Data?, transportError: Error?) -> PairingCompletionOutcome {
        if let transportError {
            return .failure("network error: \(transportError.localizedDescription)")
        }

        guard let statusCode else {
            return .failure("no response from the control plane")
        }

        guard statusCode == 201 else {
            return .failure("refused (status \(statusCode))")
        }

        guard let data else {
            return .failure("empty response body")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let credential = json["credential"] as? String,
            let workerJSON = json["worker"] as? [String: Any],
            let id = workerJSON["id"] as? String,
            let deviceWorkspaceID = workerJSON["device_workspace_id"] as? String
        else {
            return .failure("malformed response body")
        }

        let worker = WorkerIdentity(
            id: id,
            deviceWorkspaceID: deviceWorkspaceID,
            osFamily: workerJSON["os_family"] as? String,
            osMajor: workerJSON["os_major"] as? String,
            protocolVersion: workerJSON["protocol_version"] as? String,
            appVersion: workerJSON["app_version"] as? String,
            state: workerJSON["state"] as? String
        )

        return .success(PairingCompletionSuccess(credential: credential, worker: worker))
    }
}
