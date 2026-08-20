import XCTest
@testable import SDDOrchestratorWorkerCore

final class DashboardURLProviderTests: XCTestCase {
    func test_dashboardURL_readsInfoPlistKey() {
        let dictionary = ["SDDOrchestratorDashboardURL": "https://example.test/dashboard"]

        XCTAssertEqual(
            DashboardURLProvider.dashboardURL(infoDictionary: dictionary),
            URL(string: "https://example.test/dashboard")
        )
    }

    func test_dashboardURL_missingKey_fallsBackToDefault() {
        XCTAssertEqual(
            DashboardURLProvider.dashboardURL(infoDictionary: [:]),
            URL(string: DashboardURLProvider.defaultURLString)
        )
    }

    func test_dashboardURL_nilInfoDictionary_fallsBackToDefault() {
        XCTAssertEqual(
            DashboardURLProvider.dashboardURL(infoDictionary: nil),
            URL(string: DashboardURLProvider.defaultURLString)
        )
    }

    func test_dashboardURL_malformedValue_fallsBackToDefault() {
        let dictionary = ["SDDOrchestratorDashboardURL": "not a url with spaces and no scheme"]

        XCTAssertEqual(
            DashboardURLProvider.dashboardURL(infoDictionary: dictionary),
            URL(string: DashboardURLProvider.defaultURLString)
        )
    }

    func test_defaultURLString_isLocalhost4000() {
        XCTAssertEqual(DashboardURLProvider.defaultURLString, "http://localhost:4000")
    }
}
