import Foundation

/// A verified, downloaded update artifact — the version it was published as
/// and the local file `AppcastUpdateChecker` wrote it to.
///
/// Task 11's "confirm and install" flow is the intended reader of this
/// value: it owns actually launching/installing from `fileURL`, deferring
/// while a run is active, and relaunching — none of that is this task's
/// concern (see `AppcastUpdateChecker`'s own doc comment). Only ever
/// constructed after `AppcastArtifactChecksum.matches` has confirmed the
/// bytes at `fileURL` against the signed appcast entry's `sha256` — an
/// unverified download is never written to this location at all (see
/// `PendingUpdateArtifactStore.store`).
public struct PendingUpdateArtifact: Equatable, Sendable {
    public let version: String
    public let fileURL: URL

    public init(version: String, fileURL: URL) {
        self.version = version
        self.fileURL = fileURL
    }
}

/// Where `AppcastUpdateChecker` writes a verified update artifact, and how
/// Task 11 (or anything else) finds it again.
///
/// A fixed, single-slot location under `NSTemporaryDirectory()`, not a
/// versioned or timestamped one: only one pending update is ever meaningful
/// at a time — a newer appcast entry simply overwrites this file, and there
/// is nothing to reconcile across launches (Task 11's install flow, once it
/// exists, is expected to read this file promptly and can re-check the
/// appcast if it needs to confirm nothing changed). `NSTemporaryDirectory()`
/// specifically (not an app-support directory) because this is
/// re-derivable, non-configuration, non-identity state — nothing here is
/// the kind of thing that must survive a reboot or that
/// `SddOrchestrator.Worker.Configuration` (the actual paired-identity store,
/// untouched by this task) should ever hold.
public enum PendingUpdateArtifactStore {
    private static let directoryName = "com.sddorchestrator.worker.pending-update"
    private static let fileName = "update.download"

    /// `<temporaryDirectory>/com.sddorchestrator.worker.pending-update/update.download`.
    /// `temporaryDirectory` defaults to `NSTemporaryDirectory()`; overridable
    /// so tests never touch the real system temp directory's shared state.
    public static func fileURL(temporaryDirectory: String = NSTemporaryDirectory()) -> URL {
        URL(fileURLWithPath: temporaryDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Writes `data` to `fileURL(temporaryDirectory:)`, creating the parent
    /// directory if needed, and returns the descriptor Task 11 reads. Only
    /// ever called by `AppcastUpdateChecker` after
    /// `AppcastArtifactChecksum.matches` has already confirmed `data`
    /// against the signed entry's `sha256` — this function itself performs
    /// no verification and trusts its caller to have already done so.
    @discardableResult
    public static func store(
        data: Data,
        version: String,
        temporaryDirectory: String = NSTemporaryDirectory()
    ) throws -> PendingUpdateArtifact {
        let url = fileURL(temporaryDirectory: temporaryDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return PendingUpdateArtifact(version: version, fileURL: url)
    }
}
