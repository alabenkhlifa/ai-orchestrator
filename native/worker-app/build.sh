#!/bin/sh
# specs/36-local-worker-native-distribution Tasks 1 and 2.
#
# Assembles the signed-ready `.app` bundle around the `:worker` mix
# release, and the real Swift menu-bar shell (native/worker-app/MenuBarApp)
# that becomes Contents/MacOS/$LAUNCHER_NAME. Scope stops at a runnable
# `.app` directory:
#   - no code signing, entitlements, or notarization (Tasks 6, 8)
#   - no .dmg packaging (Task 7)
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$PROJECT_ROOT"

RELEASE_NAME="worker"
APP_NAME="SDD Orchestrator Worker"
BUNDLE_IDENTIFIER="com.sddorchestrator.worker"
# specs/02-local-project-onboarding's approved macOS floor.
MIN_MACOS_VERSION="14.0"
LAUNCHER_NAME="sdd-orchestrator-worker-launcher"
# [Task 2] Placeholder until specs/36's release-gate decides real dashboard
# hosting — see DashboardURLProvider's own doc comment in the Swift source.
# Override for a build with a different default via
# SDD_ORCHESTRATOR_DASHBOARD_URL.
DASHBOARD_URL="${SDD_ORCHESTRATOR_DASHBOARD_URL:-http://localhost:4000}"
# [Task 10] Same placeholder pattern for the periodic signed-appcast check —
# see AppcastURLProvider's own doc comment. Override via
# SDD_ORCHESTRATOR_APPCAST_URL.
APPCAST_URL="${SDD_ORCHESTRATOR_APPCAST_URL:-http://localhost:4000/appcast.json}"
# [Task 10] The Ed25519 public key AppcastSignatureVerifier checks every
# appcast entry's signature against, base64-encoded raw 32-byte key
# material. This default is a throwaway development/test keypair generated
# for this task (see AppcastTestSigning in the Swift test target for the
# matching private key and the generation method) — NOT a production
# secret and NOT safe to sign a real release with. Real production key
# custody and rotation are this specification's own release-gate item,
# exactly like the Developer ID signing certificate. Override for a build
# signed with the real production key via SDD_ORCHESTRATOR_APPCAST_PUBLIC_KEY.
APPCAST_PUBLIC_KEY="${SDD_ORCHESTRATOR_APPCAST_PUBLIC_KEY:-iQtBThP+7yEKC0Wy1xRPmK3vhMec2FIgDvt9dvsD3Ck=}"

RELEASE_REL_PATH="_build/prod/rel/$RELEASE_NAME"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLE_PATH="$BUILD_DIR/$APP_NAME.app"
SWIFT_APP_DIR="$SCRIPT_DIR/MenuBarApp"
SWIFT_BUILD_CONFIG="release"

echo "==> Building the :$RELEASE_NAME release (MIX_ENV=prod mix release $RELEASE_NAME)"
MIX_ENV=prod mix release "$RELEASE_NAME" --overwrite

if [ ! -x "$RELEASE_REL_PATH/bin/$RELEASE_NAME" ]; then
  echo "error: expected release start script at $RELEASE_REL_PATH/bin/$RELEASE_NAME" >&2
  exit 1
fi

echo "==> Building the menu-bar shell (swift build -c $SWIFT_BUILD_CONFIG)"
swift build -c "$SWIFT_BUILD_CONFIG" --package-path "$SWIFT_APP_DIR"

SWIFT_BINARY="$SWIFT_APP_DIR/.build/$SWIFT_BUILD_CONFIG/SDDOrchestratorWorkerApp"
if [ ! -x "$SWIFT_BINARY" ]; then
  echo "error: expected built menu-bar binary at $SWIFT_BINARY" >&2
  exit 1
fi

VERSION=$(mix run -e 'IO.puts(Mix.Project.config()[:version])' 2>/dev/null | tail -n 1)
if [ -z "$VERSION" ]; then
  echo "error: could not read the project version from mix.exs" >&2
  exit 1
fi

echo "==> Assembling $BUNDLE_PATH (version $VERSION)"
rm -rf "$BUNDLE_PATH"
mkdir -p "$BUNDLE_PATH/Contents/MacOS" "$BUNDLE_PATH/Contents/Resources"

# The built release is embedded under Contents/Resources/release, verbatim
# (bin/, erts-*/, lib/, releases/ untouched) — Task 2's menu-bar shell and
# Tasks 6/8's signing/notarization all need the release tree exactly as
# `mix release` produced it.
cp -R "$RELEASE_REL_PATH" "$BUNDLE_PATH/Contents/Resources/release"

# The real Swift menu-bar shell (built above). It launches and supervises
# Contents/Resources/release/bin/worker itself — see
# native/worker-app/MenuBarApp/Sources/SDDOrchestratorWorkerApp.
cp "$SWIFT_BINARY" "$BUNDLE_PATH/Contents/MacOS/$LAUNCHER_NAME"
chmod +x "$BUNDLE_PATH/Contents/MacOS/$LAUNCHER_NAME"

cat > "$BUNDLE_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_IDENTIFIER</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$LAUNCHER_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS_VERSION</string>
	<key>LSUIElement</key>
	<true/>
	<key>SDDOrchestratorDashboardURL</key>
	<string>$DASHBOARD_URL</string>
	<key>SDDOrchestratorAppcastURL</key>
	<string>$APPCAST_URL</string>
	<key>SDDOrchestratorAppcastPublicKey</key>
	<string>$APPCAST_PUBLIC_KEY</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.sddorchestrator.worker.pairing</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>sddworker</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> Built $BUNDLE_PATH"
