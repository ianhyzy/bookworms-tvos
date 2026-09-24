import XCTest

@MainActor
final class TopShelfDeviceTests: XCTestCase {
    func testPublishedBooksAppearOnHomeScreenAndOpenDetails() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_TOP_SHELF"] == "1" else {
            throw XCTSkip("Requires the paired Apple TV and an authorized connected library.")
        }
        let app = XCUIApplication()
        app.launch()
        let firstBook = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "book-")).firstMatch
        XCTAssertTrue(firstBook.waitForExistence(timeout: 90))
        let title = firstBook.label.components(separatedBy: ", by ").first ?? ""
        XCUIRemote.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        let preview = home.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(
            preview.waitForExistence(timeout: 30),
            "The first book should appear in Top Shelf when this app is in the Home Screen’s top row."
        )
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Apple TV Top Shelf"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["detail-title"].label, title)
        XCUIRemote.shared.press(.menu)
    }
}
