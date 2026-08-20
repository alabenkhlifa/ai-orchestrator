// swift-tools-version:5.10
// specs/36-local-worker-native-distribution Task 2.
//
// A Swift Package rather than an Xcode project: the whole menu-bar shell is
// two small targets (a plain-Foundation, unit-testable `Core` library and a
// thin AppKit executable that wires it to an `NSStatusItem`), so there is no
// storyboard/asset-catalog/build-settings surface an `.xcodeproj` would add
// value for. `swift build`/`swift test` also run headlessly in CI or this
// agent's shell without an Xcode project file or scheme to keep in sync, and
// `native/worker-app/build.sh` already drives everything else shell-first.
// The built executable is copied into `Contents/MacOS/<launcher>` inside the
// `.app` bundle `build.sh` assembles — see that script for the bundling step
// this package's binary feeds into.
import PackageDescription

let package = Package(
    name: "SDDOrchestratorWorkerApp",
    platforms: [
        // Matches native/worker-app/build.sh's MIN_MACOS_VERSION.
        .macOS(.v14)
    ],
    targets: [
        // Pure Foundation, no AppKit: every decision this task must prove
        // with a real unit test (status derivation, the active-run-check
        // decision, rpc/eval output parsing, path/URL resolution) lives
        // here so `swift test` can exercise it without a display server or
        // a running embedded release.
        .target(
            name: "SDDOrchestratorWorkerCore"
        ),
        // The actual menu-bar app: NSApplication/NSStatusItem/NSMenu wiring
        // only. Kept intentionally thin — it delegates every testable
        // decision to SDDOrchestratorWorkerCore.
        .executableTarget(
            name: "SDDOrchestratorWorkerApp",
            dependencies: ["SDDOrchestratorWorkerCore"]
        ),
        .testTarget(
            name: "SDDOrchestratorWorkerCoreTests",
            dependencies: ["SDDOrchestratorWorkerCore"]
        )
    ]
)
