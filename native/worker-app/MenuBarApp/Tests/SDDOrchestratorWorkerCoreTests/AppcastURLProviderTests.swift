import XCTest
@testable import SDDOrchestratorWorkerCore

final class AppcastURLProviderTests: XCTestCase {
    func test_appcastURL_readsInfoPlistKey() {
        let dictionary = ["SDDOrchestratorAppcastURL": "https://example.test/appcast.json"]

        XCTAssertEqual(
            AppcastURLProvider.appcastURL(infoDictionary: dictionary),
            URL(string: "https://example.test/appcast.json")
        )
    }

    func test_appcastURL_missingKey_fallsBackToDefault() {
        XCTAssertEqual(
            AppcastURLProvider.appcastURL(infoDictionary: [:]),
            URL(string: AppcastURLProvider.defaultURLString)
        )
    }

    func test_appcastURL_nilInfoDictionary_fallsBackToDefault() {
        XCTAssertEqual(
            AppcastURLProvider.appcastURL(infoDictionary: nil),
            URL(string: AppcastURLProvider.defaultURLString)
        )
    }

    func test_appcastURL_malformedValue_fallsBackToDefault() {
        let dictionary = ["SDDOrchestratorAppcastURL": "not a url with spaces and no scheme"]

        XCTAssertEqual(
            AppcastURLProvider.appcastURL(infoDictionary: dictionary),
            URL(string: AppcastURLProvider.defaultURLString)
        )
    }

    func test_defaultURLString_isLocalhostAppcastJSON() {
        XCTAssertEqual(AppcastURLProvider.defaultURLString, "http://localhost:4000/appcast.json")
    }
}

final class AppcastPublicKeyProviderTests: XCTestCase {
    func test_publicKeyBase64_readsInfoPlistKey() {
        let dictionary = ["SDDOrchestratorAppcastPublicKey": "abc123=="]

        XCTAssertEqual(AppcastPublicKeyProvider.publicKeyBase64(infoDictionary: dictionary), "abc123==")
    }

    func test_publicKeyBase64_missingKey_isNil() {
        XCTAssertNil(AppcastPublicKeyProvider.publicKeyBase64(infoDictionary: [:]))
    }

    func test_publicKeyBase64_nilInfoDictionary_isNil() {
        XCTAssertNil(AppcastPublicKeyProvider.publicKeyBase64(infoDictionary: nil))
    }
}
