import Foundation

/// Resolves paths into the embedded release, relative to the `.app`
/// bundle's `Contents/Resources` directory (`Bundle.main.resourcePath`).
/// See `native/worker-app/build.sh`, which embeds the release verbatim at
/// `Contents/Resources/release`.
public enum WorkerPaths {
    /// `<resourcePath>/release/bin/worker` — the release's own start
    /// script, which also answers `start`, `eval "EXPR"`, and
    /// `rpc "EXPR"` (see `bin/worker`'s own `--help` usage).
    public static func workerBinaryPath(resourcePath: String) -> String {
        (resourcePath as NSString).appendingPathComponent("release/bin/worker")
    }
}
