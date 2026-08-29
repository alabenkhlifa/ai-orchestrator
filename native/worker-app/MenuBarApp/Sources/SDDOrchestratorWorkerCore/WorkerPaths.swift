import Foundation

/// Resolves paths into the embedded release, relative to the `.app`
/// bundle's `Contents/Resources` directory (`Bundle.main.resourcePath`),
/// and paths into the release's own worker storage root.
/// See `native/worker-app/build.sh`, which embeds the release verbatim at
/// `Contents/Resources/release`.
public enum WorkerPaths {
    /// `<resourcePath>/release/bin/worker` — the release's own start
    /// script, which also answers `start`, `eval "EXPR"`, and
    /// `rpc "EXPR"` (see `bin/worker`'s own `--help` usage).
    public static func workerBinaryPath(resourcePath: String) -> String {
        (resourcePath as NSString).appendingPathComponent("release/bin/worker")
    }

    /// [specs/43 Task 4, AC-01] The worker's storage root, resolved the
    /// same way `SddOrchestrator.Worker.Configuration.home/1` resolves it:
    /// the given override, else `~/.sdd_orchestrator/worker`.
    ///
    /// The app writes the configuration itself now, so the two codebases
    /// have to agree on where it lives. That agreement is kept here, in one
    /// owned value, rather than as a literal repeated at each call site —
    /// `MacPairingRetention` and `PostPairingSetupCoordinatorImpl` both
    /// write the same file, and a second copy of the path is a second
    /// chance for it to drift away from the release's.
    ///
    /// The release's `home/1` also honours a `:worker_home` application
    /// env, which only its own test suite ever sets. The app never runs the
    /// release that way, so there is nothing here to mirror; the override
    /// parameter serves the same purpose for this app's tests.
    public static func workerHome(override: String? = nil) -> String {
        if let override { return override }

        return (userHomeDirectory() as NSString).appendingPathComponent(".sdd_orchestrator/worker")
    }

    /// `<workerHome>/worker.json` — the one durable store for this Mac's
    /// worker configuration, and the file the release reads at boot.
    public static func workerConfigurationPath(homeOverride: String? = nil) -> String {
        (workerHome(override: homeOverride) as NSString).appendingPathComponent("worker.json")
    }

    /// `$HOME` first, because that is what the release resolves:
    /// `System.user_home!/0` reads the environment, and the release is this
    /// app's own child process, so it inherits exactly this value. Falling
    /// back to `NSHomeDirectory()` only covers a launch with no `HOME` set
    /// at all, where both sides would then agree on the account's real home
    /// anyway.
    private static func userHomeDirectory() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
}
