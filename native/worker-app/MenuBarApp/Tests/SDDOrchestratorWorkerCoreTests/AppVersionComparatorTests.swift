import XCTest
@testable import SDDOrchestratorWorkerCore

final class AppVersionComparatorTests: XCTestCase {
    func test_isNewer_higherPatchVersion_isTrue() {
        XCTAssertTrue(AppVersionComparator.isNewer("1.2.10", than: "1.2.9"))
    }

    func test_isNewer_higherMinorVersion_isTrue() {
        XCTAssertTrue(AppVersionComparator.isNewer("1.3.0", than: "1.2.9"))
    }

    func test_isNewer_higherMajorVersion_isTrue() {
        XCTAssertTrue(AppVersionComparator.isNewer("2.0.0", than: "1.9.9"))
    }

    func test_isNewer_lowerVersion_isFalse() {
        XCTAssertFalse(AppVersionComparator.isNewer("1.2.0", than: "1.2.1"))
    }

    func test_isNewer_equalVersion_isFalse() {
        XCTAssertFalse(AppVersionComparator.isNewer("1.2.3", than: "1.2.3"))
    }

    func test_isNewer_missingTrailingComponentsCompareAsZero() {
        XCTAssertFalse(AppVersionComparator.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(AppVersionComparator.isNewer("1.2.0", than: "1.2"))
        XCTAssertTrue(AppVersionComparator.isNewer("1.2.1", than: "1.2"))
    }

    func test_isNewer_nonNumericComponent_readsAsZero_ratherThanCrashing() {
        XCTAssertFalse(AppVersionComparator.isNewer("1.2.0-beta", than: "1.2.0"))
    }
}
