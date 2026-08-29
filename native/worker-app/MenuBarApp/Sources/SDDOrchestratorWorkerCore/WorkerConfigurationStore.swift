import Foundation

/// [specs/43 Task 4, AC-01] Writes this Mac's worker configuration to the
/// release's own storage root, the way the release writes it.
///
/// This is the app-side half of `SddOrchestrator.Worker.Configuration.store/2`,
/// and it deliberately copies that function's rules: create the storage
/// root, restrict it to owner-only (`0700`), write the JSON, restrict it to
/// owner-only (`0600`), and re-apply both permissions on every write. The
/// release stays the only reader and keeps validating what it loads, so a
/// bad write is refused exactly where it always was.
///
/// Both pairing paths write the same file under the same rules, so they
/// share this one implementation rather than each keeping a copy of the
/// permissions. What differs between them is only the JSON object they
/// hand in: six fields for a Mac-scoped pairing, eight for specs/36's
/// deep link.
///
/// The credential is in that JSON. It reaches this file and nothing else:
/// no command argument, no log line, and no temporary file that outlives
/// the write. `.atomic` writes through a temporary neighbour inside the
/// already-`0700` storage root and renames it into place, so the window
/// before `0600` is applied is not reachable by another account.
enum WorkerConfigurationStore {
    /// Stores `jsonObject` as the worker configuration under `workerHome`.
    /// Throws if any step fails, having stored nothing usable — the caller
    /// reports an unfinished setup rather than restarting the release
    /// against a configuration that is not there.
    static func write(
        jsonObject: [String: String],
        workerHome: String,
        fileManager: FileManager
    ) throws {
        let directory = URL(fileURLWithPath: workerHome, isDirectory: true)
        let file = URL(fileURLWithPath: WorkerPaths.workerConfigurationPath(homeOverride: workerHome))

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` applies its attributes only to a directory it
        // actually creates, and this one usually already exists from an
        // earlier pairing. Re-applying is how the storage root stays
        // owner-only for the life of the install.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        try data.write(to: file, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
