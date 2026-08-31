import Foundation

/// [specs/40 Task 4] The repository-selection request the embedded release is
/// holding right now, as this app reads it from `pending_selection.json`.
///
/// The request id is the whole of what the app acts on: it decides which
/// panel is already open and it is what the answer is credited to. The expiry
/// is carried because the file carries it, and nothing here decides anything
/// from it. The release removes the file when the request ends by any route,
/// including a timeout, so the app learns that a request is over by the file
/// going away rather than by watching a clock of its own.
///
/// The candidate identities the request was opened with stay in the release's
/// memory. A panel needs none of them, so the app never holds them.
struct PendingSelection: Equatable {
    let requestID: String
    let expiresAt: Date?
}

/// [specs/40 Task 4] Reads the open repository-selection request from the file
/// the embedded release publishes: `pending_selection.json`, beside
/// `worker.json` and `connection_status.json` under the release's own storage
/// root. `SddOrchestrator.Worker.RepositorySelection`
/// (`lib/sdd_orchestrator/worker/repository_selection.ex`) owns that file, its
/// location, and its shape, and removes it when the request ends.
///
/// A file, for the same reason `ConnectionStatusQuerier` reads one. The
/// release holds the request in memory and this app draws the panel, and those
/// are two processes on one machine with no channel between them. `rpc` would
/// reach the running node but it needs Erlang distribution, which a managed
/// Mac's firewall refuses, so the panel would never open there. `eval` starts a
/// fresh VM with none of this VM's memory, so it would report that nothing is
/// pending while a person is waiting to be asked. Nothing here runs a command.
///
/// Showing a person a panel for a question nobody is waiting on an answer to
/// is the failure that matters here, so every way of not knowing answers
/// `nil`: no file, no permission to read it, bytes that are not JSON, no
/// `request_id`, an empty one. None of them can invent a request. A missing or
/// unreadable `expires_at` is not one of those ways: the id is what the app
/// acts on, so the request still stands and only `expiresAt` is `nil`.
enum PendingSelectionQuerier {
    /// The state the release last published, or `nil` when no request is open
    /// or the file cannot be understood. The override names the storage root,
    /// the same way every other path in this app takes one; the app itself
    /// passes nothing.
    static func query(workerHomeOverride: String? = nil) -> PendingSelection? {
        let path = WorkerPaths.pendingSelectionPath(homeOverride: workerHomeOverride)

        // Missing, or readable only by another account. Either way there is no
        // request this app may act on. The release writes the file by renaming
        // a complete temporary neighbour over it, so a read that does return
        // bytes never returns half of a write.
        guard let data = FileManager.default.contents(atPath: path) else { return nil }

        return parse(data)
    }

    static func parse(_ data: Data) -> PendingSelection? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let requestID = object["request_id"] as? String,
              !requestID.isEmpty
        else { return nil }

        return PendingSelection(requestID: requestID, expiresAt: expiry(object["expires_at"]))
    }

    /// The expiry as the control plane sent it, passed through the release
    /// verbatim. It is an ISO 8601 instant, with or without fractional
    /// seconds depending on who produced it, and anything else is simply not
    /// an expiry this app can read.
    private static func expiry(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }

        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]

        return withFractionalSeconds.date(from: text) ?? whole.date(from: text)
    }
}
