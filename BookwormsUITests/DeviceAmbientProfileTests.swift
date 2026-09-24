import XCTest

@MainActor
final class DeviceAmbientProfileTests: XCTestCase {
    func testShelfNavigationProfile() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_NAVIGATION_PROFILE"] == "1" else {
            throw XCTSkip("Opt-in Release navigation profile on the paired Apple TV.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let books = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
        XCTAssertTrue(books.firstMatch.waitForExistence(timeout: 60))
        print("Navigation profiling ready")
        // Give Instruments time to attach before issuing the same input sequence each run.
        Thread.sleep(forTimeInterval: 20)
        for _ in 0..<2 {
            for _ in 0..<8 { XCUIRemote.shared.press(.right) }
            for _ in 0..<8 { XCUIRemote.shared.press(.left) }
        }
        let selected = try XCTUnwrap(books.allElementsBoundByIndex.first(where: \.hasFocus))
        let selectedID = selected.identifier
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.menu)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"), object: books[selectedID])
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        Thread.sleep(forTimeInterval: 10)
    }

    func testSustainedAmbientPlayback() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_AMBIENT_SOAK"] == "1" else {
            throw XCTSkip("Opt-in Release profiling session on the paired Apple TV.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let books = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
        XCTAssertTrue(books.firstMatch.waitForExistence(timeout: 60))
        RemoteNavigation.startAmbient(app)
        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Ambient without focus chrome"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("Ambient profiling ready")
        // Leave the app untouched while Instruments samples multiple one-minute content changes.
        Thread.sleep(forTimeInterval: 180)
        XCTAssertTrue(app.buttons["stop-ambient"].exists)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["start-ambient"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["stop-ambient"].exists)
        XCTAssertFalse(app.staticTexts["detail-title"].exists)
    }
}
