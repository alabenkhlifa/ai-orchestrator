import XCTest
@testable import SDDOrchestratorWorkerCore

/// Asserts the generated helper script's *content* only -- this never
/// executes the script (there is no real signed `.dmg` in this environment
/// to exercise `hdiutil attach` against for real; see
/// `HelperScriptInstallExecutor`'s own doc comment and this task's brief).
final class InstallHelperScriptBuilderTests: XCTestCase {
    func test_build_startsWithAShellShebang() {
        let script = InstallHelperScriptBuilder.build()

        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
    }

    func test_build_waitsForTheParentPidBeforeTouchingAnything() {
        let script = InstallHelperScriptBuilder.build()

        XCTAssertTrue(script.contains("kill -0 \"$PARENT_PID\""), "must poll for the requesting app's own PID to exit")
    }

    func test_build_mountsAndDetachesTheDownloadedDmg() {
        let script = InstallHelperScriptBuilder.build()

        XCTAssertTrue(script.contains("hdiutil attach \"$DMG_PATH\""))
        XCTAssertTrue(script.contains("hdiutil detach"), "must unmount what it mounted")
    }

    func test_build_neverTouchesTheTargetAppBeforeStagingTheNewOneSuccessfully() {
        let script = InstallHelperScriptBuilder.build()

        // The staging `cp -R` must appear before the destructive `mv
        // "$TARGET_APP"` swap in the generated script, so a copy failure
        // aborts before the existing installed app is ever moved aside.
        guard let stageRange = script.range(of: "cp -R \"$NEW_APP\" \"$STAGING_APP\""),
              let swapRange = script.range(of: "mv \"$TARGET_APP\" \"$BACKUP_APP\"")
        else {
            return XCTFail("expected both the staging copy and the swap-aside move in the generated script")
        }
        XCTAssertLessThan(stageRange.lowerBound, swapRange.lowerBound)
    }

    func test_build_restoresTheBackupIfMovingTheNewBundleIntoPlaceFails() {
        let script = InstallHelperScriptBuilder.build()

        XCTAssertTrue(
            script.contains("mv \"$BACKUP_APP\" \"$TARGET_APP\""),
            "must restore the previous app if the final swap-in fails"
        )
    }

    func test_build_relaunchesTheTargetAppAfterInstalling() {
        let script = InstallHelperScriptBuilder.build()

        XCTAssertTrue(script.contains("open \"$TARGET_APP\""))
    }

    func test_build_cleansUpTheDmgAndItself() {
        let script = InstallHelperScriptBuilder.build()

        XCTAssertTrue(script.contains("rm -f \"$DMG_PATH\""))
        XCTAssertTrue(script.contains("rm -f \"$SELF_PATH\""))
    }

    func test_build_neverReferencesTheWorkerHomeDirectory() {
        // [AC-13] The credential store lives outside the .app bundle
        // entirely (~/.sdd_orchestrator/worker/worker.json via
        // SddOrchestrator.Worker.Configuration) and must survive an upgrade
        // by construction: this script only ever operates on $DMG_PATH and
        // $TARGET_APP (the .app bundle), never on any fixed path under the
        // operator's home directory.
        let script = InstallHelperScriptBuilder.build()

        XCTAssertFalse(script.contains(".sdd_orchestrator"))
        XCTAssertFalse(script.contains("worker.json"))
    }
}
