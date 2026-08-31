import Foundation

/// [specs/40 Task 4] Writes the person's answer to the release's open
/// repository-selection request: `selection_answer.json`, beside
/// `pending_selection.json` under the release's own storage root.
/// `SddOrchestrator.Worker.RepositorySelection` owns the shape, reads the
/// file, and deletes it before it computes anything from it.
///
/// This is the one place in the product a repository path is written, and it
/// is written here so that it never has to travel. Everything the control
/// plane learns about the folder is derived from it on this Mac. The file
/// therefore has to be owner-only, and it has to be owner-only from the
/// instant it exists: a file made world-readable and chmodded a moment later
/// is readable by another account for that moment. So the bytes are placed
/// with `createFile(atPath:contents:attributes:)` carrying `0600`, never with
/// a plain write followed by a permission change.
///
/// It is still written atomically. The `0600` file is created under a unique
/// name in the same directory and then renamed over the target, so the
/// permission guarantee and the atomicity are both kept and the release reads
/// either no answer or the whole of one. That matters more than it looks:
/// the release deletes the answer file as soon as it reads it, so a half-read
/// answer would be a lost answer, not a retried one.
///
/// A failed write returns `false` and raises nothing. The person will not see
/// their choice take effect and the control plane already times that out,
/// which is a far better outcome than the menu-bar app crashing. Nothing here
/// logs, at any level: the only interesting value in this file is the path.
enum SelectionAnswerWriter {
    /// Answers `requestID` with the folder the person chose.
    static func write(requestID: String, path: String, homeOverride: String? = nil) -> Bool {
        write(["request_id": requestID, "path": path], homeOverride: homeOverride)
    }

    /// Answers `requestID` with a dismissal. The release turns this into the
    /// `cancelled` outcome, and no path is written anywhere.
    static func writeCancellation(requestID: String, homeOverride: String? = nil) -> Bool {
        write(["request_id": requestID, "cancelled": true], homeOverride: homeOverride)
    }

    private static func write(_ object: [String: Any], homeOverride: String?) -> Bool {
        let manager = FileManager.default
        let directory = WorkerPaths.workerHome(override: homeOverride)
        let file = WorkerPaths.selectionAnswerPath(homeOverride: homeOverride)

        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }

        // The same storage root the release and `WorkerConfigurationStore`
        // already keep at `0700`, re-applied because `createDirectory` applies
        // its attributes only to a directory it actually creates and this one
        // normally exists from pairing.
        guard (try? manager.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil else { return false }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)

        let temporary = file + ".\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"

        guard manager.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return false
        }

        // `rename(2)`, not `FileManager.moveItem`, which refuses to replace an
        // existing file. Replacing is the point: an answer left by a request
        // the release has already forgotten must not survive next to a fresh
        // one.
        guard rename(temporary, file) == 0 else {
            try? manager.removeItem(atPath: temporary)
            return false
        }

        return true
    }
}
