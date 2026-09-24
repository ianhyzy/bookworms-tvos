import XCTest

@MainActor
final class OfflinePolicyUITests: XCTestCase {
    func testOfflineGuardSurvivesAppRelaunch() {
        #if BOOKWORMS_OFFLINE_TESTS
            let app = XCUIApplication()
            app.launchArguments = ["--reset-test-settings", "--sample-library"]
            app.launch()
            XCTAssertTrue(app.staticTexts["offline-test-guard"].waitForExistence(timeout: 20))
            app.terminate()
            app.launchArguments = ["--sample-library"]
            app.launch()
            XCTAssertTrue(app.staticTexts["offline-test-guard"].waitForExistence(timeout: 20))
        #endif
    }
}
