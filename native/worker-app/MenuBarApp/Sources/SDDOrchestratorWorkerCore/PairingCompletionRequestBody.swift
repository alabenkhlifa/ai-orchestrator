/// Builds the JSON body `POST /worker_pairings` expects
/// (`SddOrchestratorWeb.WorkerPairingController.create/2`): the pairing
/// `code` plus this worker's own self-reported attributes. Every value is a
/// `String` because the controller only accepts string-typed optional
/// attributes (`is_binary` — anything else is treated as malformed and
/// refused).
public enum PairingCompletionRequestBody {
    public static func build(code: String, selfReport: WorkerSelfReport) -> [String: String] {
        var body: [String: String] = [
            "code": code,
            "os_family": selfReport.osFamily,
            "os_major": selfReport.osMajor,
            "app_version": selfReport.appVersion
        ]

        if let protocolVersion = selfReport.protocolVersion {
            body["protocol_version"] = protocolVersion
        }

        return body
    }
}
