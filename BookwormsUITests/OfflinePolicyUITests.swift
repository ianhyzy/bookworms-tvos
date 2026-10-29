import XCTest

@MainActor
final class OfflinePolicyUITests: XCTestCase {
    func testOfflineGuardSurvivesAppRelaunch() throws {
        #if BOOKWORMS_OFFLINE_TESTS
            let app = XCUIApplication()
            app.launchArguments = ["--reset-test-settings", "--sample-library"]
            app.launch()
            XCTAssertTrue(app.staticTexts["offline-test-guard"].waitForExistence(timeout: 20))
            app.terminate()
            app.launchArguments = ["--sample-library"]
            app.launch()
            XCTAssertTrue(app.staticTexts["offline-test-guard"].waitForExistence(timeout: 20))
        #else
            // A skip fails the runner's verification, so a build without the flag cannot pass.
            throw XCTSkip("Requires the offline test build (BOOKWORMS_OFFLINE_TESTS).")
        #endif
    }
}
