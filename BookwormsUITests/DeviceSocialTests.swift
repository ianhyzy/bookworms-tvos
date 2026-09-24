import XCTest

/// Opt-in navigation against the saved account; never enters credentials or generates designs.
@MainActor
final class DeviceSocialTests: XCTestCase {
    private func focused(_ element: XCUIElement) -> Bool {
        element.hasFocus
            || element.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).count > 0
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSharedReviewLayoutAndReachableControls() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_SOCIAL"] == "1" else {
            throw XCTSkip("Requires an authorized cached Hardcover comparison.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
                .firstMatch.waitForExistence(timeout: 60))
        RemoteNavigation.selectView("Book Club", in: app)
        let cover = app.buttons
            .matching(
                NSPredicate(format: "identifier BEGINSWITH 'shared-' AND hasFocus == true")
            )
            .firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 30))
        capture(app, "Book Club horizontal covers and reviews")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            focused(app.buttons["reader-picker-menu"]) || focused(app.buttons["view-options"]))
        RemoteNavigation.focusSidebarItem("Settings", in: app)
    }

    func testReadOnlyComparisonAndAmbient() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_SOCIAL"] == "1" else {
            throw XCTSkip("Requires an authorized live Hardcover account on Apple TV.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
                .firstMatch.waitForExistence(timeout: 60))
        RemoteNavigation.selectView("Compare Shelves", in: app)
        RemoteNavigation.chooseReader("Adam", in: app)
        RemoteNavigation.openSettings(app, section: "General")
        let sync = app.buttons["sync-social"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: sync)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed)
        for _ in 0..<8 {
            if focused(sync) { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(focused(sync))
        XCUIRemote.shared.press(.select)
        let complete = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: sync)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 120), .completed)
        RemoteNavigation.selectView("Following", in: app)
        capture(app, "Live Following")
        RemoteNavigation.selectView("Compare Shelves", in: app)
        XCTAssertTrue(app.staticTexts["Adam"].waitForExistence(timeout: 60))
        XCTAssertTrue(
            app.otherElements["comparison-lower"].buttons.firstMatch.waitForExistence(timeout: 90))
        capture(app, "Live Compare Shelves")
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.down)
        RemoteNavigation.selectView("Book Club", in: app)
        capture(app, "Live Book Club")
        RemoteNavigation.startAmbient(app)
        capture(app, "Live ambient")
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(app.buttons["stop-ambient"].exists)
        XCTAssertFalse(app.staticTexts["detail-title"].exists)
    }
}
