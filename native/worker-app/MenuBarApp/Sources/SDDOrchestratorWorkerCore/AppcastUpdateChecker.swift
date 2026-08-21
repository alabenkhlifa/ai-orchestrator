import Foundation

/// Drives the periodic signed-appcast check (specs/36 Task 10, AC-11/AC-12):
/// fetch the appcast, verify its signature, compare versions, and — only
/// when newer and signature-valid — download the artifact, verify its
/// checksum, and surface the result. Kept in `SDDOrchestratorWorkerCore`,
/// not `AppDelegate`, mirroring `PairingFlowController`'s "thin AppKit glue
/// over a testable Core" split: every branch here runs in tests against a
/// fake `AppcastHTTPFetching`, never a real network call.
///
/// `AppDelegate` owns *scheduling* `checkNow()` on a repeating `Timer`
/// (mirroring its existing `startConnectionPolling()`/`connectionPollTimer`
/// pattern) — this type only performs one check per call, so the interval
/// itself lives as a plain, testable value (`defaultInterval`) rather than a
/// literal buried in untestable `Timer` setup code, and a test can trivially
/// construct `AppDelegate`'s timer with a different interval if needed
/// without this type ever needing to know about `Timer` at all.
///
/// Explicitly out of scope (Task 11's job): no "confirm and install" action,
/// no actual installation, no relaunch, no active-run deferral. This type's
/// only product-visible effect is calling `onUpdateAvailable` once a
/// verified artifact is on disk — Task 11 wires what happens after that.
public final class AppcastUpdateChecker {
    /// Production default periodic-check interval — 24 hours. A plain,
    /// testable constant (not a literal inlined into `Timer` setup) so
    /// `AppDelegate` can reference it without repeating the magic number,
    /// and so a test can assert against it directly.
    public static let defaultInterval: TimeInterval = 24 * 60 * 60

    private let appcastURL: URL
    private let currentAppVersion: String
    private let publicKeyBase64: String?
    private let httpFetcher: AppcastHTTPFetching
    private let artifactStore: (Data, String) throws -> PendingUpdateArtifact
    private let onUpdateAvailable: (PendingUpdateArtifact) -> Void
    private let logError: (String) -> Void

    public init(
        appcastURL: URL,
        currentAppVersion: String,
        publicKeyBase64: String?,
        httpFetcher: AppcastHTTPFetching,
        artifactStore: @escaping (Data, String) throws -> PendingUpdateArtifact = { data, version in
            try PendingUpdateArtifactStore.store(data: data, version: version)
        },
        onUpdateAvailable: @escaping (PendingUpdateArtifact) -> Void,
        logError: @escaping (String) -> Void = { _ in }
    ) {
        self.appcastURL = appcastURL
        self.currentAppVersion = currentAppVersion
        self.publicKeyBase64 = publicKeyBase64
        self.httpFetcher = httpFetcher
        self.artifactStore = artifactStore
        self.onUpdateAvailable = onUpdateAvailable
        self.logError = logError
    }

    /// [AC-11] Fetches the signed appcast and verifies its signature before
    /// trusting anything in it. Any failure here — transport error,
    /// non-200, malformed body, or (via `handle(entry:)`) an invalid or
    /// missing signature — is treated exactly like "no update": logged,
    /// never surfaced in the menu, never trusted.
    public func checkNow() {
        httpFetcher.get(url: appcastURL) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode

            switch AppcastResponseParser.parse(statusCode: statusCode, data: data, transportError: error) {
            case .failure(let reason):
                self.logError("appcast fetch failed: \(reason)")
            case .success(let entry):
                self.handle(entry: entry)
            }
        }
    }

    private func handle(entry: AppcastEntry) {
        guard AppcastSignatureVerifier.verify(entry: entry, publicKeyBase64: publicKeyBase64) else {
            logError("appcast signature invalid or missing; ignoring entry")
            return
        }

        // [AC-11] Not newer than the running app: take no action. This must
        // short-circuit here, before any artifact download is attempted —
        // the common case ("no update published") has to be silent and free,
        // not silent-after-wasted-work.
        guard AppVersionComparator.isNewer(entry.latestVersion, than: currentAppVersion) else {
            return
        }

        downloadAndVerify(entry: entry)
    }

    private func downloadAndVerify(entry: AppcastEntry) {
        guard let downloadURL = URL(string: entry.downloadURL) else {
            logError("appcast download_url is not a valid URL")
            return
        }

        httpFetcher.get(url: downloadURL) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode

            guard error == nil, statusCode == 200, let data else {
                self.logError("update artifact download failed")
                return
            }

            // [AC-12] Ties the downloaded bytes cryptographically to what
            // was signed, independent of transport. A checksum mismatch is
            // a failed/untrusted update: discard the download, never offer
            // it.
            guard AppcastArtifactChecksum.matches(data: data, expectedHexSHA256: entry.sha256) else {
                self.logError("update artifact checksum mismatch; discarding download")
                return
            }

            do {
                // [AC-12] Only once the download is present on disk *and*
                // its checksum is confirmed does this reach
                // `onUpdateAvailable` — `AppDelegate` maps that to
                // `WorkerStatus.updateAvailable` and a menu-bar prompt, never
                // an automatic install.
                let artifact = try self.artifactStore(data, entry.latestVersion)
                self.onUpdateAvailable(artifact)
            } catch {
                self.logError("failed to store verified update artifact: \(error)")
            }
        }
    }
}
