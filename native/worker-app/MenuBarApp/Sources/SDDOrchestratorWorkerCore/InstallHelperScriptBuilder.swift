import Foundation

/// Builds the shell script `HelperScriptInstallExecutor` writes to disk and
/// spawns as a detached process — the actual mount/replace/relaunch
/// mechanics behind specs/36 Task 11's install-and-relaunch flow.
///
/// Kept as pure string construction, entirely separate from the
/// `Process`-spawning side effect in `HelperScriptInstallExecutor`, so the
/// script's *content* can be asserted against in a fast unit test without
/// ever executing it. There is no real signed/notarized `.dmg` in this
/// environment to exercise the executed script's `hdiutil`/Gatekeeper path
/// against for real — see this task's brief on what stays unverified until
/// Tasks 7-9 (signing/notarization/packaging) land.
public enum InstallHelperScriptBuilder {
    /// Positional arguments the script expects, in order:
    ///   `$1` — the PID of the app that spawned this script (this app's
    ///          own `ProcessInfo.processInfo.processIdentifier`); the
    ///          script waits for this PID to disappear before touching
    ///          anything, so it never races the still-running app that is
    ///          about to replace its own bundle.
    ///   `$2` — the downloaded, checksum- and Gatekeeper-verified `.dmg`
    ///          path (`PendingUpdateArtifact.fileURL.path`).
    ///   `$3` — the running `.app` bundle's own path to replace
    ///          (`Bundle.main.bundlePath`, captured before the app quit).
    ///
    /// Passed as positional arguments rather than spliced into the heredoc
    /// so odd characters in either path never need in-script escaping, and
    /// so this builder never has to know the real paths at all.
    public static func build() -> String {
        """
        #!/bin/sh
        # SDD Orchestrator Worker -- generated update-install helper.
        # specs/36 Task 11. Written to a private temp file, executed once,
        # then deletes itself (see the EXIT trap below). Never hand-edited,
        # never checked in.
        set -u

        PARENT_PID="$1"
        DMG_PATH="$2"
        TARGET_APP="$3"
        SELF_PATH="$0"

        LOG_FILE="$(dirname "$DMG_PATH")/install.log"

        log() {
          printf '%s %s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$LOG_FILE" 2>/dev/null
        }

        # Always unmount whatever we mounted and remove our own temp files,
        # on every exit path (success, early "abort without touching
        # anything", or an unexpected failure partway through).
        cleanup() {
          if [ -n "${MOUNT_POINT:-}" ]; then
            hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1
          fi
          rm -f "$DMG_PATH"
          rm -f "$SELF_PATH"
        }
        trap cleanup EXIT

        # 1. Wait for the requesting app to actually exit (bounded -- do not
        #    wait forever, and never touch the bundle while its process
        #    might still be running).
        WAITED=0
        while kill -0 "$PARENT_PID" 2>/dev/null; do
          if [ "$WAITED" -ge 60 ]; then
            log "timed out waiting for pid $PARENT_PID to exit; aborting install, nothing on disk touched"
            exit 1
          fi
          sleep 0.5
          WAITED=$((WAITED + 1))
        done

        # 2. Mount the downloaded .dmg read-only, never browsed/auto-opened.
        MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly -noautoopen |
          awk -F '\\t' '/\\/Volumes\\// { print $NF }' | tail -1)"
        if [ -z "$MOUNT_POINT" ]; then
          log "hdiutil attach failed or reported no mount point; aborting install, nothing on disk touched"
          exit 1
        fi

        NEW_APP="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' -print -quit)"
        if [ -z "$NEW_APP" ]; then
          log "no .app found inside $DMG_PATH; aborting install, nothing on disk touched"
          exit 1
        fi

        TARGET_DIR="$(dirname "$TARGET_APP")"
        STAGING_APP="$TARGET_DIR/.sdd-worker-update-staging.app"
        BACKUP_APP="$TARGET_DIR/.sdd-worker-update-backup.app"
        rm -rf "$STAGING_APP" "$BACKUP_APP"

        # 3. Stage the new bundle onto the same volume as the target first.
        #    A failure here never touches TARGET_APP at all.
        if ! cp -R "$NEW_APP" "$STAGING_APP"; then
          log "failed to stage the new app bundle; aborting install, existing app left untouched"
          rm -rf "$STAGING_APP"
          exit 1
        fi

        # 4. Swap: move the old bundle aside, then move the new one into
        #    place. Both are same-volume renames (near-instant, not a byte
        #    copy), which keeps the window where TARGET_APP does not exist
        #    as short as possible. If the second rename fails, the backup is
        #    restored immediately so TARGET_APP is never left missing.
        if ! mv "$TARGET_APP" "$BACKUP_APP"; then
          log "failed to move aside the existing app bundle; aborting install, existing app left untouched"
          rm -rf "$STAGING_APP"
          exit 1
        fi

        if ! mv "$STAGING_APP" "$TARGET_APP"; then
          log "failed to move the new app bundle into place; restoring the previous version"
          mv "$BACKUP_APP" "$TARGET_APP"
          exit 1
        fi

        rm -rf "$BACKUP_APP"

        # 5. Unmounting the .dmg happens in the EXIT trap above.

        # 6. Relaunch the new bundle.
        open "$TARGET_APP"
        log "install completed: $TARGET_APP replaced and relaunched"
        exit 0
        """
    }
}
