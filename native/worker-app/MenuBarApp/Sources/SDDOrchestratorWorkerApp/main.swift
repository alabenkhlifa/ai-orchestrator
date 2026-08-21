import AppKit

// specs/36-local-worker-native-distribution Task 2.
//
// LSUIElement is already set in the bundled Info.plist
// (native/worker-app/build.sh), so no Dock icon; .accessory below matches
// that for the case this binary is run directly (e.g. `swift run`, or the
// raw built binary outside a proper `.app` bundle) rather than launched via
// LaunchServices, where Info.plist's LSUIElement would not apply.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
